import AppKit
import AVFoundation
import Foundation
import GRDB
import Observation
import ServiceManagement

/// Lets background callbacks reach the model without keeping it alive.
struct WeakModel: @unchecked Sendable {
    weak var model: AppModel?

    init(_ model: AppModel) {
        self.model = model
    }
}

/// The app's state and everything the interface can do. One instance, shared by all windows.
@MainActor
@Observable
public final class AppModel {
    public enum Section: Hashable, Sendable {
        case meetings
        case people
    }

    public enum Overlay: Equatable, Sendable {
        case palette
    }

    public enum WindowRequest: Equatable, Sendable {
        case main
        case live
        case settings(SettingsTab)
    }

    public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
        case general, recording, transcription, ai, voices
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .general: "Allgemein"
            case .recording: "Aufnahme"
            case .transcription: "Transkription"
            case .ai: "KI"
            case .voices: "Stimmen"
            }
        }
        public var systemImage: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .recording: "mic"
            case .transcription: "waveform"
            case .ai: "sparkle"
            case .voices: "person.2"
            }
        }
    }

    public enum ProviderStatus: Equatable, Sendable {
        case notConfigured
        case checking
        case connected
        case failed(String)
    }

    public struct Toast: Identifiable, Equatable, Sendable {
        public var id = UUID()
        public var title: String
        public var message: String
        public var isError: Bool
    }

    // MARK: Infrastructure

    @ObservationIgnored public let database: AppDatabase
    @ObservationIgnored let secrets: SecretStore
    public let settings: AppSettings
    @ObservationIgnored let engine: SpeechEngine
    @ObservationIgnored let calendar = CalendarService()
    @ObservationIgnored let notifications = NotificationService.shared
    public let detector = CallDetector()
    public let player = AudioPlayback()
    /// Sample data, no microphone, no calendar: for screenshots and trying the app out.
    public let isDemo: Bool
    @ObservationIgnored private var observations: [AnyDatabaseCancellable] = []
    @ObservationIgnored private var detailObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var processingQueue: [String] = []
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored var liveSummaryTask: Task<Void, Never>?
    @ObservationIgnored var calendarTimerTask: Task<Void, Never>?
    @ObservationIgnored var floatingRecorder: FloatingRecorderController?

    // MARK: Data

    public internal(set) var rows: [MeetingRow] = []
    public internal(set) var peopleStats: [PersonStats] = []
    public internal(set) var reviews: [VoiceReview] = []
    public internal(set) var detail: MeetingDetail?
    public internal(set) var upcoming: [UpcomingMeeting] = []

    // MARK: Navigation

    public var section: Section = .meetings
    public var selectedMeetingId: String? {
        didSet {
            guard selectedMeetingId != oldValue else { return }
            observeDetail()
            if player.meetingId != selectedMeetingId { player.stop() }
        }
    }
    public var overlay: Overlay?
    /// A transcript line to scroll to and highlight, for search results.
    public var focusedSegmentId: Int64?
    public var windowRequest: WindowRequest?
    public var windowRequestCount = 0
    public internal(set) var toasts: [Toast] = []

    // MARK: Recording and processing

    public internal(set) var recording: RecordingSession?
    public internal(set) var processingMeetingId: String?
    public internal(set) var liveSummary: LiveSummary?
    public internal(set) var liveSummaryError: String?
    public internal(set) var engineState: SpeechEngineState = .idle

    // MARK: AI

    public internal(set) var summarizing: Set<String> = []
    public internal(set) var providerModels: [ProviderKind: [LLMModel]] = [:]
    public internal(set) var providerStatus: [ProviderKind: ProviderStatus] = [:]

    // MARK: Permissions

    public internal(set) var microphoneAllowed: Bool?
    public internal(set) var calendarAllowed: Bool?
    public internal(set) var notificationsAllowed: Bool?
    public internal(set) var persistentAlerts = false
    public internal(set) var launchAtLogin = false

    public init(database: AppDatabase, settings: AppSettings, secrets: SecretStore = KeychainStore(), engine: SpeechEngine = .shared, isDemo: Bool = false) {
        self.database = database
        self.settings = settings
        self.secrets = secrets
        self.engine = engine
        self.isDemo = isDemo
        startObserving()
        if !isDemo {
            notifications.onAction = { [weak self] action in self?.handle(action) }
            notifications.activate()
        }
    }

    /// Everything that may ask the system for something; called once the first window is up.
    public func launch() {
        floatingRecorder = FloatingRecorderController(model: self)
        DebugRemote.startIfRequested(model: self)
        refreshPermissions()
        guard !isDemo else { return }
        recoverInterruptedMeetings()
        applyRetention()
        for provider in ProviderKind.allCases where isConfigured(provider) {
            Task { await checkProvider(provider) }
        }
        if settings.onboardingDone {
            prepareEngine()
            startCalendar()
            configureCallDetection()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Observation

    private func startObserving() {
        observations.append(ValueObservation.tracking { db in try AppDatabase.fetchMeetingRows(db) }.start(
            in: database.reader, scheduling: .immediate,
            onError: { error in Log.app.error("Meeting list observation failed: \(error.localizedDescription)") },
            onChange: { [weak self] rows in
                MainActor.assumeIsolated {
                    self?.rows = rows
                }
            }
        ))
        observations.append(ValueObservation.tracking { db in
            (try AppDatabase.fetchPeopleStats(db), try AppDatabase.fetchVoiceReviews(db))
        }.start(
            in: database.reader, scheduling: .immediate,
            onError: { error in Log.app.error("People observation failed: \(error.localizedDescription)") },
            onChange: { [weak self] value in
                MainActor.assumeIsolated {
                    self?.peopleStats = value.0
                    self?.reviews = value.1
                }
            }
        ))
    }

    private func observeDetail() {
        detailObservation?.cancel()
        detailObservation = nil
        guard let meetingId = selectedMeetingId else {
            detail = nil
            return
        }
        detailObservation = ValueObservation.tracking { db in try AppDatabase.fetchDetail(db, meetingId: meetingId) }
            .removeDuplicates()
            .start(
                in: database.reader, scheduling: .immediate,
                onError: { error in Log.app.error("Detail observation failed: \(error.localizedDescription)") },
                onChange: { [weak self] detail in
                    MainActor.assumeIsolated {
                        guard let self, self.selectedMeetingId == meetingId else { return }
                        self.detail = detail
                        if detail == nil { self.selectedMeetingId = nil }
                    }
                }
            )
    }

    // MARK: Lookups

    public var people: [Person] { peopleStats.map(\.person) }
    public var me: Person? { people.first(where: \.isMe) }
    public var myName: String { me?.name ?? Self.defaultMyName }
    public var pendingVoiceCount: Int { reviews.count }

    public static var defaultMyName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Ich" : full
    }

    public func person(_ id: String?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    public func row(for meetingId: String) -> MeetingRow? {
        rows.first { $0.id == meetingId }
    }

    /// Meetings grouped by day for the list, newest first.
    public var groupedRows: [(title: String, rows: [MeetingRow])] {
        var groups: [(String, [MeetingRow])] = []
        let calendar = Calendar.current
        for row in rows {
            let title = TimeFormat.dayTitle(row.meeting.startedAt)
            if let last = groups.last, let first = last.1.first, calendar.isDate(first.meeting.startedAt, inSameDayAs: row.meeting.startedAt) {
                groups[groups.count - 1].1.append(row)
            } else {
                groups.append((title, [row]))
            }
        }
        return groups
    }

    // MARK: Window and toasts

    public func request(_ window: WindowRequest) {
        windowRequest = window
        windowRequestCount += 1
    }

    public func showToast(_ title: String, _ message: String = "", isError: Bool = false) {
        let toast = Toast(title: title, message: message, isError: isError)
        toasts.append(toast)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 8 : 4))
            self?.dismissToast(toast.id)
        }
    }

    public func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    public func select(_ meetingId: String?) {
        section = .meetings
        selectedMeetingId = meetingId
    }

    /// Opens the main window and brings the app to the front.
    public func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        request(.main)
    }

    // MARK: Speech models

    public var modelsDownloaded: Bool { isDemo || settings.transcriptionModel.isDownloaded }

    public func prepareEngine() {
        guard !isDemo else {
            engineState = .ready
            return
        }
        let model = settings.transcriptionModel
        let engine = engine
        let relay = WeakModel(self)
        Task {
            do {
                try await engine.prepare(model: model) { state in
                    Task { @MainActor in relay.model?.engineState = state }
                }
                relay.model?.engineState = .ready
            } catch {
                relay.model?.engineState = .failed(error.localizedDescription)
            }
        }
    }

    /// Switches the speech model and loads the new one.
    public func changeTranscriptionModel(_ model: TranscriptionModel) {
        guard model != settings.transcriptionModel else { return }
        settings.transcriptionModel = model
        Task {
            await engine.unload()
            prepareEngine()
        }
    }

    // MARK: Permissions

    public func refreshPermissions() {
        guard !isDemo else {
            microphoneAllowed = true
            calendarAllowed = true
            notificationsAllowed = true
            return
        }
        switch MicrophoneCapture.permission {
        case .authorized: microphoneAllowed = true
        case .notDetermined: microphoneAllowed = nil
        default: microphoneAllowed = false
        }
        calendarAllowed = CalendarService.wasAsked ? CalendarService.hasAccess : nil
        Task {
            let status = await notifications.authorizationStatus()
            switch status {
            case .authorized, .provisional, .ephemeral: notificationsAllowed = true
            case .notDetermined: notificationsAllowed = nil
            default: notificationsAllowed = false
            }
            persistentAlerts = await notifications.usesPersistentAlerts()
        }
    }

    public func requestMicrophone() async {
        _ = await MicrophoneCapture.requestPermission()
        refreshPermissions()
    }

    public func requestCalendar() async {
        _ = await calendar.requestAccess()
        refreshPermissions()
        startCalendar()
    }

    public func requestNotifications() async {
        _ = await notifications.requestAuthorization()
        refreshPermissions()
        await rescheduleReminders()
    }

    /// Opens the right pane of System Settings › Privacy & Security.
    public func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            showToast("Autostart ließ sich nicht ändern", error.localizedDescription, isError: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func finishOnboarding() {
        settings.onboardingDone = true
        prepareEngine()
        startCalendar()
        configureCallDetection()
    }

    // MARK: Processing queue

    public func enqueueProcessing(_ meetingId: String) {
        guard !processingQueue.contains(meetingId), processingMeetingId != meetingId else { return }
        processingQueue.append(meetingId)
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            while let self, !self.processingQueue.isEmpty {
                let next = self.processingQueue.removeFirst()
                await self.process(next)
            }
            self?.processingTask = nil
        }
    }

    private func process(_ meetingId: String) async {
        processingMeetingId = meetingId
        defer { processingMeetingId = nil }
        let options = MeetingProcessor.Options(
            model: settings.transcriptionModel,
            thresholds: settings.voiceStrictness.thresholds,
            learnVoices: settings.learnVoices,
            defaultMyName: Self.defaultMyName
        )
        let processor = MeetingProcessor(database: database, engine: engine)
        do {
            try await processor.process(meetingId: meetingId, options: options)
        } catch {
            showToast("Meeting konnte nicht verarbeitet werden", error.localizedDescription, isError: true)
            return
        }
        await finishAudio(of: meetingId)
        if settings.autoSummarize, summaryProviderReady {
            await generateSummary(meetingId)
        }
    }

    /// Compresses or removes the recording, as the retention setting says.
    private func finishAudio(of meetingId: String) async {
        let retention = settings.audioRetention
        await Task.detached(priority: .utility) {
            if retention == .never {
                AudioArchiver.deleteAudio(meetingId: meetingId)
            } else {
                try? AudioArchiver.compress(meetingId: meetingId)
            }
        }.value
    }

    /// Meetings the app was in the middle of when it quit: finish them now.
    private func recoverInterruptedMeetings() {
        guard let interrupted = try? database.interruptedMeetings() else { return }
        for meeting in interrupted {
            if AudioArchiver.hasAudio(meetingId: meeting.id) {
                try? database.update(meetingId: meeting.id) { meeting in
                    if meeting.status == .recording {
                        meeting.duration = max(meeting.duration, Channel.allCases.compactMap { AppPaths.existingAudio(for: meeting.id, channel: $0) }.map(SpeechAudio.duration).max() ?? 0)
                    }
                    meeting.status = .processing
                }
                enqueueProcessing(meeting.id)
            } else {
                try? database.update(meetingId: meeting.id) { meeting in
                    meeting.status = .failed
                    meeting.errorMessage = "Die Aufnahme wurde unterbrochen, bevor Audio gespeichert war."
                }
            }
        }
    }

    private func applyRetention() {
        guard settings.audioRetention == .month else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for row in rows where row.meeting.startedAt < cutoff && row.meeting.status == .ready {
            AudioArchiver.deleteAudio(meetingId: row.meeting.id)
        }
    }

    public func reprocess(_ meetingId: String) {
        guard AudioArchiver.hasAudio(meetingId: meetingId) else {
            showToast("Keine Aufnahme mehr vorhanden", "Das Audio dieses Meetings wurde gelöscht.", isError: true)
            return
        }
        try? database.update(meetingId: meetingId) { meeting in
            meeting.status = .processing
            meeting.progress = 0
            meeting.processingStep = "Wartet"
        }
        enqueueProcessing(meetingId)
    }
}
