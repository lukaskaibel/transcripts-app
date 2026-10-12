import Foundation
import GRDB
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension AppModel {
    /// The iCloud container of this build. Builds signed with a team that has iCloud set it in Info.plist
    /// (`TR_ICLOUD = YES` in Config/Local.xcconfig); others don't offer sync.
    nonisolated static var cloudContainer: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "TranscriptsCloudKitContainer") as? String, id.hasPrefix("iCloud.") else { return nil }
        return id
    }

    /// Sync can be turned on: the build has iCloud, and the demo only with a zone of its own.
    public var iCloudAvailable: Bool {
        Self.cloudContainer != nil && (!isDemo || syncZone != "Transcripts")
    }

    func startSyncIfWanted() {
        guard iCloudAvailable, let container = Self.cloudContainer else {
            syncState = Self.cloudContainer == nil ? .unavailable : .off
            return
        }
        guard settings.iCloudSync, cloudSync == nil else { return }
        let sync = CloudSync(database: database, containerIdentifier: container, zoneName: syncZone, includeAudio: settings.iCloudAudio) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        cloudSync = sync
        syncState = .syncing
        Task { await sync.start() }
        // Changes here go up a moment after they happen, so a burst of them (a transcript being written) goes as one.
        syncObservation = ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: "SELECT COUNT(*) AS count, MAX(changedAt) AS latest FROM syncPending").map { row -> String in
                let count: Int = row["count"]
                let latest: Double? = row["latest"]
                return "\(count)/\(latest ?? 0)"
            }
        }
        .removeDuplicates()
        .start(in: database.reader, scheduling: .immediate,
               onError: { error in Log.app.error("Sync observation failed: \(error.localizedDescription)") },
               onChange: { [weak self] _ in
                   MainActor.assumeIsolated { self?.scheduleSyncEnqueue() }
               })
        // CloudKit tells the app about changes from the other devices with a silent push; when the app comes to the
        // front (and every few minutes while it is there) it asks anyway.
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        let activation = NSApplication.didBecomeActiveNotification
        #else
        UIApplication.shared.registerForRemoteNotifications()
        let activation = UIApplication.didBecomeActiveNotification
        #endif
        syncTasks.append(Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: activation).map({ _ in () }) {
                await self?.cloudSync?.syncNow()
            }
        })
        syncTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.isAppActive else { continue }
                await self.cloudSync?.syncNow()
            }
        })
    }

    private var isAppActive: Bool {
        #if os(macOS)
        NSApplication.shared.isActive
        #else
        UIApplication.shared.applicationState == .active
        #endif
    }

    private func scheduleSyncEnqueue() {
        syncEnqueue?.cancel()
        syncEnqueue = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.cloudSync?.enqueuePending()
        }
    }

    func stopSync() {
        syncObservation?.cancel()
        syncObservation = nil
        syncEnqueue?.cancel()
        syncTasks.forEach { $0.cancel() }
        syncTasks = []
        if let cloudSync { Task { await cloudSync.stop() } }
        cloudSync = nil
    }

    public func setICloudSync(_ on: Bool) {
        settings.iCloudSync = on
        if on {
            startSyncIfWanted()
        } else {
            stopSync()
            syncState = .off
        }
    }

    public func setICloudAudio(_ on: Bool) {
        settings.iCloudAudio = on
        if let cloudSync { Task { await cloudSync.setIncludeAudio(on) } }
    }

    public func syncNow() {
        guard let cloudSync else { return }
        syncState = .syncing
        Task { await cloudSync.syncNow() }
    }

    /// Removes the app's data from iCloud, on every device's account; the meetings on this device stay.
    public func deleteICloudData() async {
        guard let container = Self.cloudContainer else { return }
        let sync = cloudSync ?? CloudSync(database: database, containerIdentifier: container, zoneName: syncZone, includeAudio: false) { _ in }
        stopSync()
        syncState = .syncing
        do {
            try await sync.deleteEverythingInICloud()
            settings.iCloudSync = false
            syncState = .off
            showToast(String(localized: "Aus iCloud gelöscht"), String(localized: "Die Meetings auf diesem Gerät bleiben."))
        } catch {
            syncState = .failed(error.localizedDescription)
            showToast(String(localized: "Löschen in iCloud fehlgeschlagen"), error.localizedDescription, isError: true)
        }
    }

    private func handle(_ event: CloudSync.Event) {
        switch event {
        case .state(let state):
            // A late report of a sync that was turned off in the meantime.
            guard cloudSync != nil || state == .deletedInICloud else { return }
            if state == .deletedInICloud {
                settings.iCloudSync = false
                stopSync()
            }
            syncState = state
        case .received(_, let voices):
            if voices { refreshVoices() }
        }
    }
}
