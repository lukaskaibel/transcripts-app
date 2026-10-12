import CloudKit
import Foundation

/// How iCloud sync is doing, for Settings.
public enum SyncState: Equatable, Sendable {
    /// Turned off, or this build has no iCloud (built without a team, see Config/Local.xcconfig.example).
    case off
    case unavailable
    /// No iCloud account on this device, or iCloud Drive is turned off for the app.
    case noAccount
    case syncing
    case upToDate(Date)
    case failed(String)
    /// The data in iCloud was deleted from another device or in the iCloud settings; sync turned itself off.
    case deletedInICloud
}

/// Keeps the database the same as in the user's private iCloud database, with `CKSyncEngine`.
///
/// A meeting travels as one record whose content is a file (it can be larger than a record may be), its recording as
/// another record with the audio files, so a device can do without them. People and voice samples are records of their
/// own, and the user is "me" on every device. What changed here comes from `syncPending` (see `SyncSchema`); what
/// comes from iCloud is written without counting as a change here. When both changed, the later change wins.
actor CloudSync: CKSyncEngineDelegate {
    enum Event: Sendable {
        case state(SyncState)
        /// Records came from iCloud: the voices may have to be learned again.
        case received(meetings: Set<String>, voices: Bool)
    }

    private static let stateKey = "engineState"
    private static let userKey = "user"
    private static let zoneTokenKey = "zoneToken"

    private let database: AppDatabase
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private var includeAudio: Bool
    private let report: @Sendable (Event) -> Void
    private var engine: CKSyncEngine?
    /// The time of the change each record was built from, to forget the change once iCloud has it (and not a newer one).
    private var stamps: [CKRecord.ID: Double] = [:]
    /// Meeting contents written for upload, removed once sent.
    private let outbox: URL
    private var lastError: String?

    init(database: AppDatabase, containerIdentifier: String, zoneName: String, includeAudio: Bool, report: @escaping @Sendable (Event) -> Void) {
        self.database = database
        self.container = CKContainer(identifier: containerIdentifier)
        self.zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.includeAudio = includeAudio
        self.report = report
        // With the data it belongs to (each data folder has its own), and a file per upload: a record built again
        // while the last one is still on its way must not take its file away.
        self.outbox = AppPaths.applicationSupport.appendingPathComponent("iCloud Outbox", isDirectory: true)
    }

    // MARK: Control

    func start() async {
        guard engine == nil else { return }
        try? FileManager.default.removeItem(at: outbox)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        switch try? await container.accountStatus() {
        case .available?:
            break
        case .noAccount?, .restricted?:
            report(.state(.noAccount))
        default:
            // Unknown for now (offline at launch): the engine finds out and reports an account change.
            break
        }
        let saved = (try? database.syncMeta(Self.stateKey)).flatMap { try? SyncCoding.decoder.decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved, delegate: self)
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        self.engine = engine
        if saved == nil {
            // The first sync: the zone, and everything on this device.
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            try? database.syncEnqueueEverything(includeAudio: includeAudio)
        }
        enqueuePending()
        report(.state(.syncing))
        await syncNow()
    }

    func stop() async {
        await engine?.cancelOperations()
        engine = nil
        try? FileManager.default.removeItem(at: outbox)
    }

    func setIncludeAudio(_ value: Bool) {
        guard value != includeAudio else { return }
        includeAudio = value
        if value { try? database.syncEnqueueEverything(includeAudio: true) }
        enqueuePending()
    }

    /// Fetches what changed in iCloud and sends what changed here.
    func syncNow() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            try await catchUp()
            try await engine.sendChanges()
            finished()
        } catch {
            await fail(error)
        }
    }

    /// Looks for changes the engine wasn't told about. The engine fetches only after a push, and a push can be
    /// missed: it never comes to the device (or the push token) that made a change, and a device that was offline for
    /// long gets only the last one. So the zone is asked directly, for the digests only, and whole records are fetched
    /// where a digest differs from what this device has. Changes the engine also gets later are then the same and
    /// cost nothing.
    private func catchUp() async throws {
        let cloud = container.privateCloudDatabase
        let saved = (try? database.syncMeta(Self.zoneTokenKey)) ?? nil
        var token = saved.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        var changed: [CKRecord.ID] = []
        var deletions: [CKDatabase.RecordZoneChange.Deletion] = []
        var more = true
        while more {
            let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                result = try await cloud.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: ["digest", "modifiedAt", "schema"], resultsLimit: 400)
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                continue
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // Before the first sync the zone may not be there yet; after it, someone deleted it.
                if saved != nil, let engine { zoneDeleted(.deleted, engine: engine) }
                return
            }
            for (id, modification) in result.modificationResultsByID {
                guard case .success(let change) = modification, let (type, name) = split(id) else { continue }
                if let digest = change.record["digest"] as? String, digest == (try? database.syncRecordInfo(type, name).digest) {
                    // The same as here; only the change tag may be newer.
                    try? database.syncSetRecordInfo(type, name, systemFields: Self.systemFields(of: change.record), digest: digest)
                } else {
                    changed.append(id)
                }
            }
            deletions += result.deletions
            token = result.changeToken
            more = result.moreComing
        }
        var records: [CKRecord] = []
        for start in stride(from: 0, to: changed.count, by: 100) {
            let batch = Array(changed[start..<min(start + 100, changed.count)])
            for (_, fetched) in try await cloud.records(for: batch) {
                if case .success(let record) = fetched { records.append(record) }
            }
        }
        if !records.isEmpty || !deletions.isEmpty, let engine {
            Log.sync.info("caught up on \(records.map(\.recordID.recordName), privacy: .public), deleted \(deletions.map(\.recordID.recordName), privacy: .public)")
            apply(records, deletions: deletions, engine: engine)
        }
        if let token, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) {
            try? database.syncSetMeta(Self.zoneTokenKey, data)
        }
    }

    /// Removes everything of the app from iCloud (the data on this device stays) and stops. Directly, not through the
    /// engine, which would put the zone back for the changes it still has.
    func deleteEverythingInICloud() async throws {
        await stop()
        let (_, deleted) = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID])
        if case .failure(let error)? = deleted[zoneID], (error as? CKError)?.code != .zoneNotFound {
            throw error
        }
        try database.syncResetBookkeeping()
    }

    /// Hands the changes in `syncPending` to the engine: meetings once they are finished, recordings if wanted.
    func enqueuePending() {
        guard let engine, let changes = try? database.syncPendingChanges() else { return }
        defer { Log.sync.info("pending here \(changes.count), in the engine \(engine.state.pendingRecordZoneChanges.count)") }
        let ready = (try? database.syncFinishedMeetings()) ?? []
        let pending = Set(engine.state.pendingRecordZoneChanges)
        var add: [CKSyncEngine.PendingRecordZoneChange] = []
        var remove: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in changes {
            guard let id = try? recordID(change.recordType, localName: change.recordName) else { continue }
            if change.deleted {
                if id.recordName == recordName(SyncRecordType.person, SyncNames.me) { continue }
                if pending.contains(.saveRecord(id)) { remove.append(.saveRecord(id)) }
                if !pending.contains(.deleteRecord(id)) { add.append(.deleteRecord(id)) }
            } else {
                switch change.recordType {
                case SyncRecordType.meeting where !ready.contains(change.recordName): continue
                case SyncRecordType.audio where !includeAudio || !ready.contains(change.recordName): continue
                default: break
                }
                if pending.contains(.deleteRecord(id)) { remove.append(.deleteRecord(id)) }
                if !pending.contains(.saveRecord(id)) { add.append(.saveRecord(id)) }
            }
        }
        if !remove.isEmpty { engine.state.remove(pendingRecordZoneChanges: remove) }
        if !add.isEmpty {
            engine.state.add(pendingRecordZoneChanges: add)
            report(.state(.syncing))
        }
    }

    // MARK: Names

    /// "Meeting:<id>": record names are unique across types in a zone, and a meeting and its recording share an id.
    private func recordName(_ type: String, _ name: String) -> String { "\(type):\(name)" }

    private func recordID(_ type: String, localName: String) throws -> CKRecord.ID {
        let name = type == SyncRecordType.person ? try database.syncPersonName(localName) : localName
        return CKRecord.ID(recordName: recordName(type, name), zoneID: zoneID)
    }

    private func split(_ id: CKRecord.ID) -> (type: String, name: String)? {
        guard let colon = id.recordName.firstIndex(of: ":") else { return nil }
        return (String(id.recordName[..<colon]), String(id.recordName[id.recordName.index(after: colon)...]))
    }

    /// The name of a record in `syncPending`: the user's own id for "me".
    private func localName(_ type: String, _ name: String) throws -> String? {
        guard type == SyncRecordType.person, name == SyncNames.me else { return name }
        return try database.syncLocalMeId()
    }

    // MARK: Sending

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        // Recordings are large: one at a time, after everything else.
        let small = changes.filter { change in
            if case .saveRecord(let id) = change { return !id.recordName.hasPrefix(SyncRecordType.audio + ":") }
            return true
        }
        let batch = small.isEmpty ? Array(changes.prefix(1)) : Array(small.prefix(200))
        guard !batch.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: batch) { id in
            await self.record(for: id, engine: syncEngine)
        }
    }

    /// The record to save for a pending change, or nil when there is nothing to send (anymore).
    private func record(for id: CKRecord.ID, engine: CKSyncEngine) -> CKRecord? {
        do {
            guard let (type, name) = split(id), let local = try localName(type, name) else {
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                return nil
            }
            let changedAt = try database.syncPendingChangedAt(type, local) ?? Date().timeIntervalSince1970
            let info = try database.syncRecordInfo(type, name)
            let record = info.systemFields.flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: type, recordID: id)
            let digest: String
            switch type {
            case SyncRecordType.meeting:
                guard case .ready(let payload) = try database.syncMeetingPayload(local) else { return skip(id, engine) }
                let data = try SyncCoding.encoder.encode(payload)
                digest = SyncCoding.digest(data)
                guard digest != info.digest || info.systemFields == nil else { return unchanged(id, type, local, changedAt, engine) }
                let file = outbox.appendingPathComponent("\(name)-\(UUID().uuidString).json")
                try data.write(to: file)
                record["content"] = CKAsset(fileURL: file)
                record["title"] = payload.meeting.title
                record["startedAt"] = payload.meeting.startedAt
            case SyncRecordType.person:
                guard let payload = try database.syncPersonPayload(local) else { return skip(id, engine) }
                let data = try SyncCoding.encoder.encode(payload)
                digest = SyncCoding.digest(data)
                guard digest != info.digest || info.systemFields == nil else { return unchanged(id, type, local, changedAt, engine) }
                record["content"] = data
                record["name"] = payload.name
            case SyncRecordType.voiceprint:
                guard let payload = try database.syncVoiceprintPayload(local) else { return skip(id, engine) }
                let data = try SyncCoding.encoder.encode(payload)
                digest = SyncCoding.digest(data)
                guard digest != info.digest || info.systemFields == nil else { return unchanged(id, type, local, changedAt, engine) }
                record["content"] = data
            case SyncRecordType.audio:
                let files = SyncAudio.files(of: local)
                guard includeAudio, !files.isEmpty else { return skip(id, engine) }
                digest = SyncAudio.digest(of: files)
                guard digest != info.digest || info.systemFields == nil else { return unchanged(id, type, local, changedAt, engine) }
                record["names"] = files.map(\.lastPathComponent)
                record["files"] = files.map { CKAsset(fileURL: $0) }
            default:
                return skip(id, engine)
            }
            record["digest"] = digest
            record["modifiedAt"] = changedAt
            record["schema"] = 1
            stamps[id] = changedAt
            return record
        } catch {
            Log.sync.error("building \(id.recordName, privacy: .public) failed: \(error.localizedDescription)")
            return skip(id, engine)
        }
    }

    /// Not to be sent now (a meeting still recording, a recording without audio sync); `enqueuePending` hands it over
    /// again once it is.
    private func skip(_ id: CKRecord.ID, _ engine: CKSyncEngine) -> CKRecord? {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        return nil
    }

    /// The same as iCloud has: nothing to send.
    private func unchanged(_ id: CKRecord.ID, _ type: String, _ local: String, _ changedAt: Double, _ engine: CKSyncEngine) -> CKRecord? {
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
        try? database.syncClearPending(type, local, upTo: changedAt)
        return nil
    }

    // MARK: Events

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, engine: syncEngine)
    }

    private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let update):
            try? database.syncSetMeta(Self.stateKey, try? JSONEncoder().encode(update.stateSerialization))
        case .accountChange(let change):
            accountChanged(change.changeType, engine: engine)
        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                zoneDeleted(deletion.reason, engine: engine)
            }
        case .fetchedRecordZoneChanges(let changes):
            received(changes, engine: engine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                Log.sync.error("saving the zone failed: \(failure.error.localizedDescription)")
                lastError = failure.error.localizedDescription
            }
        case .sentRecordZoneChanges(let sent):
            self.sent(sent, engine: engine)
        case .willFetchChanges, .willSendChanges:
            report(.state(.syncing))
        case .didFetchChanges, .didSendChanges:
            if engine.state.pendingRecordZoneChanges.isEmpty && engine.state.pendingDatabaseChanges.isEmpty { finished() }
        default:
            break
        }
    }

    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange.ChangeType, engine: CKSyncEngine) {
        switch change {
        case .signIn(let user):
            // The same account as before (iCloud came back) keeps what it knew; another one starts over.
            if (try? database.syncMeta(Self.userKey)) != Data(user.recordName.utf8) {
                startOver(user: user, engine: engine)
            }
            report(.state(.syncing))
        case .switchAccounts(_, let user):
            startOver(user: user, engine: engine)
        case .signOut:
            // The meetings stay on this device; only what iCloud knew is forgotten.
            try? database.syncResetBookkeeping()
            report(.state(.noAccount))
        @unknown default:
            break
        }
    }

    private func startOver(user: CKRecord.ID?, engine: CKSyncEngine) {
        let state = try? database.syncMeta(Self.stateKey)
        try? database.syncResetBookkeeping()
        // The engine's own state stays: it knows the account already.
        if let state { try? database.syncSetMeta(Self.stateKey, state) }
        if let user { try? database.syncSetMeta(Self.userKey, Data(user.recordName.utf8)) }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        try? database.syncEnqueueEverything(includeAudio: includeAudio)
        enqueuePending()
    }

    private func zoneDeleted(_ reason: CKDatabase.DatabaseChange.Deletion.Reason, engine: CKSyncEngine) {
        try? database.syncResetBookkeeping()
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
        switch reason {
        case .encryptedDataReset:
            // The keys were reset: what was in iCloud is unreadable and goes up again from here.
            startOver(user: nil, engine: engine)
        default:
            // Deleted on purpose (on another device, or in the iCloud settings): don't send it all up again.
            report(.state(.deletedInICloud))
        }
    }

    // MARK: Receiving

    private func received(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) {
        Log.sync.info("received \(changes.modifications.map(\.record.recordID.recordName), privacy: .public), deleted \(changes.deletions.map(\.recordID.recordName), privacy: .public)")
        apply(changes.modifications.map(\.record), deletions: changes.deletions, engine: engine)
    }

    /// Writes what came from iCloud: people first, then voices, meetings and recordings; then the deletions.
    private func apply(_ fetched: [CKRecord], deletions: [CKDatabase.RecordZoneChange.Deletion], engine: CKSyncEngine) {
        var meetings = Set<String>()
        var voices = false
        let records = fetched.filter { $0.recordID.zoneID == zoneID }
        for type in SyncRecordType.applyOrder {
            for record in records where record.recordType == type {
                do {
                    if try apply(record) {
                        if type == SyncRecordType.meeting, let name = split(record.recordID)?.name { meetings.insert(name) }
                        if type != SyncRecordType.audio { voices = true }
                    }
                } catch {
                    Log.sync.error("applying \(record.recordID.recordName, privacy: .public) failed: \(error.localizedDescription)")
                }
            }
        }
        for deletion in deletions where deletion.recordID.zoneID == zoneID {
            guard let (type, name) = split(deletion.recordID), !(type == SyncRecordType.person && name == SyncNames.me),
                  let local = try? localName(type, name) else { continue }
            do {
                try database.syncApplyDeletion(type, local)
                try database.syncClearPending(type, local)
                try database.syncForgetRecordInfo(type, name)
                engine.state.remove(pendingRecordZoneChanges: [.saveRecord(deletion.recordID)])
                voices = voices || type != SyncRecordType.audio
            } catch {
                Log.sync.error("deleting \(deletion.recordID.recordName, privacy: .public) failed: \(error.localizedDescription)")
            }
        }
        if !meetings.isEmpty || voices {
            report(.received(meetings: meetings, voices: voices))
        }
    }

    /// Writes a record from iCloud, unless what changed here is newer. True when something was written.
    @discardableResult
    private func apply(_ record: CKRecord) throws -> Bool {
        guard let (type, name) = split(record.recordID), (record["schema"] as? Int ?? 1) <= 1 else { return false }
        let modifiedAt = record["modifiedAt"] as? Double ?? 0
        let digest = record["digest"] as? String
        let local = try localName(type, name)
        let known = try database.syncRecordInfo(type, name)
        if let digest, digest == known.digest {
            // What this device sent, or has already: only the change tag is new.
            try database.syncSetRecordInfo(type, name, systemFields: Self.systemFields(of: record), digest: digest)
            return false
        }
        if let local, try !database.syncRemoteWins(type, local, remoteModifiedAt: modifiedAt) {
            // Ours is newer: it goes up with this record's change tag.
            try database.syncSetRecordInfo(type, name, systemFields: Self.systemFields(of: record), digest: nil)
            return false
        }
        switch type {
        case SyncRecordType.meeting:
            guard let url = (record["content"] as? CKAsset)?.fileURL else { return false }
            let payload = try SyncCoding.decoder.decode(MeetingPayload.self, from: Data(contentsOf: url))
            try database.syncApply(meeting: payload)
        case SyncRecordType.person:
            guard let data = record["content"] as? Data else { return false }
            let payload = try SyncCoding.decoder.decode(PersonPayload.self, from: data)
            let (_, twin) = try database.syncApply(person: payload, recordName: name)
            if let twin, name != SyncNames.me { try database.syncMergeTwins(name, twin) }
        case SyncRecordType.voiceprint:
            guard let data = record["content"] as? Data else { return false }
            let payload = try SyncCoding.decoder.decode(VoiceprintPayload.self, from: data)
            try database.syncApply(voiceprint: payload, recordName: name)
        case SyncRecordType.audio:
            let names = record["names"] as? [String] ?? []
            let assets = record["files"] as? [CKAsset] ?? []
            let files = zip(names, assets).compactMap { name, asset in asset.fileURL.map { (name: name, url: $0) } }
            try database.syncApplyAudio(meetingId: name, files: files)
        default:
            return false
        }
        try database.syncSetRecordInfo(type, name, systemFields: Self.systemFields(of: record), digest: digest)
        if let local { try database.syncClearPending(type, local, upTo: modifiedAt) }
        return true
    }

    // MARK: Results of sending

    private func sent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        Log.sync.info("sent \(sent.savedRecords.count) saved, \(sent.deletedRecordIDs.count) deleted, \(sent.failedRecordSaves.map { "\($0.record.recordID.recordName):\($0.error.code.rawValue)" }, privacy: .public) failed")
        for record in sent.savedRecords {
            guard let (type, name) = split(record.recordID) else { continue }
            try? database.syncSetRecordInfo(type, name, systemFields: Self.systemFields(of: record), digest: record["digest"] as? String)
            if let local = try? localName(type, name) {
                try? database.syncClearPending(type, local, upTo: stamps[record.recordID] ?? 0)
            }
            stamps[record.recordID] = nil
            removeOutboxFile(of: record)
        }
        for id in sent.deletedRecordIDs {
            guard let (type, name) = split(id) else { continue }
            if let local = try? localName(type, name) { try? database.syncClearPending(type, local) }
            try? database.syncForgetRecordInfo(type, name)
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            stamps[id] = nil
            removeOutboxFile(of: failure.record)
            guard let (type, name) = split(id) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else saved it first: the later change wins.
                guard let server = failure.error.serverRecord else { break }
                if (try? apply(server)) == true {
                    report(.received(meetings: type == SyncRecordType.meeting ? [name] : [], voices: type != SyncRecordType.audio))
                } else {
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                }
            case .zoneNotFound, .userDeletedZone:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                try? database.syncForgetRecordInfo(type, name)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .unknownItem:
                // Gone in iCloud though this device knew it: save it anew.
                try? database.syncForgetRecordInfo(type, name)
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .quotaExceeded:
                lastError = String(localized: "Dein iCloud-Speicher ist voll.")
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled, .requestRateLimited:
                // The engine tries these again by itself.
                break
            default:
                Log.sync.error("saving \(id.recordName, privacy: .public) failed: \(failure.error.localizedDescription)")
                lastError = failure.error.localizedDescription
            }
        }
        for (id, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem, let (type, name) = split(id) {
                if let local = try? localName(type, name) { try? database.syncClearPending(type, local) }
                try? database.syncForgetRecordInfo(type, name)
            }
        }
        // A record that changed again while it was on its way goes up once more.
        enqueuePending()
    }

    private func removeOutboxFile(of record: CKRecord) {
        guard let url = (record["content"] as? CKAsset)?.fileURL, url.path.hasPrefix(outbox.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Reporting

    private func finished() {
        if let lastError {
            report(.state(.failed(lastError)))
            self.lastError = nil
        } else {
            report(.state(.upToDate(Date())))
        }
    }

    private func fail(_ error: Error) async {
        if let error = error as? CKError, [.partialFailure, .batchRequestFailed, .serverRecordChanged].contains(error.code) {
            // Some records didn't go up (another device was first); `sent` sorted them out and the engine sends again.
            if engine?.state.pendingRecordZoneChanges.isEmpty == false { report(.state(.syncing)) } else { finished() }
        } else if let error = error as? CKError, error.code == .notAuthenticated {
            // Also when iCloud doesn't answer for the account for a moment (a new container does that for a minute).
            if (try? await container.accountStatus()) == .available {
                report(.state(.failed(String(localized: "Keine Verbindung zu iCloud."))))
            } else {
                report(.state(.noAccount))
            }
        } else if (error as? CKError)?.code == .networkUnavailable || (error as? CKError)?.code == .networkFailure {
            report(.state(.failed(String(localized: "Keine Verbindung zu iCloud."))))
        } else {
            report(.state(.failed(error.localizedDescription)))
        }
    }

    // MARK: System fields

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
