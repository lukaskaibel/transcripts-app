import Foundation

extension AppModel {
    public var isRecording: Bool { recording != nil }

    /// In the demo, `-demo.recordFrom <file>` records for real, with the file played as the microphone: the live
    /// transcript, the speech recognition and the processing afterwards, on a simulator or in a test, without anyone's
    /// microphone.
    var demoRecordingFile: URL? {
        guard isDemo else { return nil }
        return UserDefaults.standard.string(forKey: "demo.recordFrom").map { URL(fileURLWithPath: $0) }
    }

    /// Starts recording, for a calendar meeting if one is given or running right now.
    public func startRecording(event: UpcomingMeeting? = nil) async {
        guard recording == nil else {
            request(.live)
            return
        }
        let file = demoRecordingFile
        if isDemo, file == nil {
            #if os(macOS)
            showToast(String(localized: "Demo"), String(localized: "Im Demo-Modus wird nicht aufgenommen."))
            #else
            // A pretend recording, so the recording screen can be tried and photographed.
            startDemoRecording()
            request(.live)
            #endif
            return
        }
        switch file == nil ? MicrophoneCapture.permission : .authorized {
        case .notDetermined:
            guard await MicrophoneCapture.requestPermission() else {
                refreshPermissions()
                showToast(String(localized: "Kein Zugriff aufs Mikrofon"), String(localized: "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon."), isError: true)
                return
            }
            refreshPermissions()
        case .denied, .restricted:
            showToast(String(localized: "Kein Zugriff aufs Mikrofon"), String(localized: "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon."), isError: true)
            openPrivacySettings("Privacy_Microphone")
            return
        default:
            break
        }

        let now = Date()
        let calendarMeeting = event ?? calendar.meeting(around: now, filter: meetingFilter)
        let meeting = Meeting(
            title: calendarMeeting?.title ?? String(localized: "Meeting \(TimeFormat.time(now))", comment: "title of a recording without a calendar event; the time it started"),
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
            showToast(String(localized: "Aufnahme konnte nicht starten"), error.localizedDescription, isError: true)
            return
        }
        let session = RecordingSession(meeting: meeting, database: database, engine: engine, configuration: .init(
            microphoneUID: settings.microphoneUID,
            captureSystemAudio: settings.captureSystemAudio,
            thresholds: settings.voiceStrictness.thresholds
        ), library: voiceLibrary.isEmpty ? nil : voiceLibrary, sources: file.flatMap { try? FileAudioSource(url: $0) }.map { [.microphone: $0] })
        do {
            try await session.start()
        } catch {
            try? database.deleteMeeting(meeting.id)
            try? FileManager.default.removeItem(at: AppPaths.folder(for: meeting.id))
            showToast(String(localized: "Aufnahme konnte nicht starten"), error.localizedDescription, isError: true)
            return
        }
        recording = session
        if let message = session.errorMessage {
            showToast(String(localized: "Systemaudio wird nicht aufgenommen"), message, isError: true)
        }
        if engineState != .ready { prepareEngine() }
        #if os(macOS)
        if settings.floatingRecorder { floatingRecorder?.show() }
        if settings.openLiveWindow { request(.live) }
        #else
        // On iPhone and iPad the recording screen is the place to see it's running, so it always comes up.
        request(.live)
        #endif
        startLiveSummary()
        Task { await rescheduleReminders() }
    }

    /// Stops the recording and hands it to the full transcription pass.
    public func stopRecording() async {
        if isDemo, demoRecordingFile == nil, recording != nil {
            stopDemoRecording()
            showToast(String(localized: "Demo"), String(localized: "Im Demo-Modus wird nicht aufgenommen."))
            return
        }
        guard let session = recording, session.state == .recording || session.state == .paused else { return }
        await session.stop()
        recording = nil
        #if os(macOS)
        floatingRecorder?.hide()
        #endif
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
