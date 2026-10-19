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
        guard !startingRecording else { return }
        startingRecording = true
        defer { startingRecording = false }
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
        guard await microphoneUsable() else { return }

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
        let session = makeSession(for: meeting)
        do {
            try await session.start()
        } catch {
            try? database.deleteMeeting(meeting.id)
            try? FileManager.default.removeItem(at: AppPaths.folder(for: meeting.id))
            showToast(String(localized: "Aufnahme konnte nicht starten"), error.localizedDescription, isError: true)
            return
        }
        recording = session
        didStart(session)
    }

    /// Whether a stopped meeting can be recorded further: one this device recorded, whose audio is still here,
    /// while nothing else is being recorded.
    public func canResume(_ meeting: Meeting) -> Bool {
        recording == nil && meeting.origin == .recording && meeting.status != .recording
            && AppPaths.existingAudio(for: meeting.id, channel: .microphone) != nil
    }

    /// The meeting recorded last, if it ended within the last half hour and can be recorded further: for going on
    /// after a stop by mistake or a break.
    public var recentlyStoppedMeeting: Meeting? {
        guard let meeting = rows.first(where: { $0.meeting.origin == .recording })?.meeting,
              meeting.startedAt.addingTimeInterval(meeting.duration) > Date().addingTimeInterval(-30 * 60),
              canResume(meeting) else { return nil }
        return meeting
    }

    /// Records more of a stopped meeting: the new audio goes on after the old, the live transcript after the
    /// transcript, and afterwards the whole meeting is transcribed again, with the names given before kept.
    public func resumeRecording(_ meetingId: String) async {
        guard recording == nil else {
            request(.live)
            return
        }
        guard !startingRecording, let meeting = try? database.detail(of: meetingId)?.meeting, canResume(meeting) else { return }
        startingRecording = true
        defer { startingRecording = false }
        if isDemo, demoRecordingFile == nil {
            showToast(String(localized: "Demo"), String(localized: "Im Demo-Modus wird nicht aufgenommen."))
            return
        }
        guard await microphoneUsable() else { return }
        // A pass over the part before would be out of date.
        cancelProcessing(meetingId)
        try? database.update(meetingId: meetingId) { meeting in
            meeting.status = .recording
            meeting.progress = 0
            meeting.processingStep = nil
            meeting.errorMessage = nil
        }
        // Compressing the recording files of the part before: the new recording takes their place.
        await finishingAudio[meetingId]?.value
        guard let previous = try? database.detail(of: meetingId) else { return }
        let session = makeSession(for: previous.meeting, continuing: previous)
        do {
            try await session.start()
        } catch {
            // Everything recorded before is still in the files: transcribed again, the meeting is as it was.
            reprocess(meetingId)
            showToast(String(localized: "Aufnahme konnte nicht starten"), error.localizedDescription, isError: true)
            return
        }
        recording = session
        didStart(session)
    }

    /// Asks for the microphone if it wasn't asked yet; false, with a word to the user, where it isn't allowed.
    private func microphoneUsable() async -> Bool {
        switch demoRecordingFile == nil ? MicrophoneCapture.permission : .authorized {
        case .notDetermined:
            guard await MicrophoneCapture.requestPermission() else {
                refreshPermissions()
                showToast(String(localized: "Kein Zugriff aufs Mikrofon"), String(localized: "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon."), isError: true)
                return false
            }
            refreshPermissions()
            return true
        case .denied, .restricted:
            showToast(String(localized: "Kein Zugriff aufs Mikrofon"), String(localized: "Erlaube ihn in den Systemeinstellungen unter Datenschutz & Sicherheit › Mikrofon."), isError: true)
            openPrivacySettings("Privacy_Microphone")
            return false
        default:
            return true
        }
    }

    private func makeSession(for meeting: Meeting, continuing previous: MeetingDetail? = nil) -> RecordingSession {
        let file = demoRecordingFile
        return RecordingSession(meeting: meeting, database: database, engine: engine, configuration: .init(
            microphoneUID: settings.microphoneUID,
            captureSystemAudio: settings.captureSystemAudio,
            thresholds: settings.voiceStrictness.thresholds,
            callAudioWorkedBefore: settings.callAudioWorked
        ), library: voiceLibrary.isEmpty ? nil : voiceLibrary, sources: file.flatMap { try? FileAudioSource(url: $0) }.map { [.microphone: $0] }, continuing: previous)
    }

    /// What follows the start of a recording: the recorder on screen, the live summary.
    private func didStart(_ session: RecordingSession) {
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
        if session.systemAudioHeard { settings.callAudioWorked = true }
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
