import AppKit
import Foundation

extension AppModel {
    public var isRecording: Bool { recording != nil }

    /// Starts recording, for a calendar meeting if one is given or running right now.
    public func startRecording(event: UpcomingMeeting? = nil) async {
        guard recording == nil else {
            request(.live)
            return
        }
        if isDemo {
            showToast("Demo", "Im Demo-Modus wird nicht aufgenommen.")
            return
        }
        switch MicrophoneCapture.permission {
        case .notDetermined:
            guard await MicrophoneCapture.requestPermission() else {
                refreshPermissions()
                showToast("Kein Zugriff aufs Mikrofon", "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon.", isError: true)
                return
            }
            refreshPermissions()
        case .denied, .restricted:
            showToast("Kein Zugriff aufs Mikrofon", "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon.", isError: true)
            openPrivacySettings("Privacy_Microphone")
            return
        default:
            break
        }

        let now = Date()
        let calendarMeeting = event ?? calendar.meeting(around: now)
        let meeting = Meeting(
            title: calendarMeeting?.title ?? "Meeting \(TimeFormat.time(now))",
            startedAt: now,
            status: .recording,
            origin: .recording,
            source: detector.activeCall?.appName ?? calendarMeeting?.app,
            calendarEventId: calendarMeeting?.eventId,
            attendees: calendarMeeting?.attendees ?? []
        )
        do {
            try database.save(meeting)
            _ = try database.mePerson(defaultName: Self.defaultMyName)
        } catch {
            showToast("Aufnahme konnte nicht starten", error.localizedDescription, isError: true)
            return
        }
        let session = RecordingSession(meeting: meeting, database: database, engine: engine, configuration: .init(
            microphoneUID: settings.microphoneUID,
            echoCancellation: settings.echoCancellation,
            captureSystemAudio: settings.captureSystemAudio,
            thresholds: settings.voiceStrictness.thresholds
        ))
        do {
            try await session.start()
        } catch {
            try? database.deleteMeeting(meeting.id)
            try? FileManager.default.removeItem(at: AppPaths.folder(for: meeting.id))
            showToast("Aufnahme konnte nicht starten", error.localizedDescription, isError: true)
            return
        }
        recording = session
        if let message = session.errorMessage {
            showToast("Systemaudio wird nicht aufgenommen", message, isError: true)
        }
        if engineState != .ready { prepareEngine() }
        if settings.floatingRecorder { floatingRecorder?.show() }
        if settings.openLiveWindow { request(.live) }
        startLiveSummary()
        Task { await rescheduleReminders() }
    }

    /// Stops the recording and hands it to the full transcription pass.
    public func stopRecording() async {
        guard let session = recording, session.state == .recording || session.state == .paused else { return }
        await session.stop()
        recording = nil
        floatingRecorder?.hide()
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        liveSummary = nil
        liveSummaryError = nil
        enqueueProcessing(session.meetingId)
        select(session.meetingId)
        Task { await rescheduleReminders() }
    }

    public func togglePause() {
        guard let session = recording else { return }
        if session.state == .paused { session.resume() } else { session.pause() }
    }

    public func toggleRecording() {
        Task {
            if recording != nil { await stopRecording() } else { await startRecording() }
        }
    }

    // MARK: Live summary

    /// Keeps the live summary fresh: a request every 90 seconds while there is something new to read.
    func startLiveSummary() {
        liveSummaryTask?.cancel()
        guard settings.liveSummary, summaryProviderReady else { return }
        liveSummaryTask = Task { [weak self] in
            var lastLength = 0
            try? await Task.sleep(for: .seconds(45))
            while !Task.isCancelled {
                guard let self, let session = self.recording else { return }
                let transcript = session.transcriptText()
                let words = transcript.split(separator: " ").count
                if words - lastLength >= 40 {
                    lastLength = words
                    await self.updateLiveSummary(transcript: transcript)
                }
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }

    func updateLiveSummary(transcript: String) async {
        guard let (provider, model) = summaryProvider() else { return }
        do {
            liveSummary = try await Summarizer.summarizeLive(transcript: transcript, myName: me?.firstName ?? myName, language: settings.summaryLanguage, provider: provider, model: model)
            liveSummaryError = nil
        } catch {
            liveSummaryError = error.localizedDescription
        }
    }

    /// Turns the live summary on or off from the live window.
    public func setLiveSummary(_ enabled: Bool) {
        settings.liveSummary = enabled
        if enabled {
            startLiveSummary()
            if let session = recording, !session.lines.isEmpty {
                Task { await updateLiveSummary(transcript: session.transcriptText()) }
            }
        } else {
            liveSummaryTask?.cancel()
            liveSummaryTask = nil
        }
    }
}
