import Foundation

// MARK: - Naming voices

extension AppModel {
    /// Accepts the suggestion shown for a voice.
    public func confirmSuggestion(_ speaker: MeetingSpeaker) {
        if let personId = speaker.suggestedPersonId {
            assign(speaker, to: personId)
        } else if let name = speaker.suggestedName {
            // The voice's own meeting, which need not be the open one (confirming from the people list).
            let attendees = (try? database.detail(of: speaker.meetingId))?.meeting.attendees ?? []
            let attendee = attendees.first { $0.name == name }
            assign(speaker, toNewPersonNamed: name, email: attendee?.email)
        }
    }

    /// "That's not them": the voice is never suggested as that person again.
    public func rejectSuggestion(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        if let personId = speaker.suggestedPersonId, !speaker.rejectedPersonIds.contains(personId) {
            speaker.rejectedPersonIds.append(personId)
        }
        speaker.candidatePersonIds.removeAll { $0 == speaker.suggestedPersonId }
        speaker.assignment = .unknown
        speaker.suggestedPersonId = nil
        speaker.suggestedName = nil
        speaker.suggestionReason = nil
        speaker.confidence = 0
        try? database.save(speaker)
    }

    /// Names a voice. Its lines count for that person from now on, and every other voice is judged again.
    public func assign(_ speaker: MeetingSpeaker, to personId: String) {
        do {
            try database.assign(speaker, to: personId)
        } catch {
            showToast("Zuordnung fehlgeschlagen", error.localizedDescription, isError: true)
            return
        }
        refreshVoices()
    }

    public func assign(_ speaker: MeetingSpeaker, toNewPersonNamed name: String, email: String? = nil) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let person = try database.person(named: name, email: email)
            assign(speaker, to: person.id)
        } catch {
            showToast("Person konnte nicht angelegt werden", error.localizedDescription, isError: true)
        }
    }

    public func assignToMe(_ speaker: MeetingSpeaker) {
        guard let me = try? database.mePerson(defaultName: Self.defaultMyName) else { return }
        assign(speaker, to: me.id)
    }

    /// "That's not them": the name comes off, and the app won't put it back by itself.
    public func unassign(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        if let personId = speaker.personId, !speaker.rejectedPersonIds.contains(personId) {
            speaker.rejectedPersonIds.append(personId)
        }
        speaker.personId = nil
        speaker.assignment = .unknown
        speaker.candidatePersonIds = []
        speaker.confidence = 0
        try? database.save(speaker)
        refreshVoices()
    }

    /// None of the people the app guessed: they are not suggested for this voice again.
    public func rejectGuesses(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        for personId in speaker.guesses where !speaker.rejectedPersonIds.contains(personId) {
            speaker.rejectedPersonIds.append(personId)
        }
        speaker.assignment = .unknown
        speaker.personId = nil
        speaker.suggestedPersonId = nil
        speaker.suggestedName = nil
        speaker.suggestionReason = nil
        speaker.candidatePersonIds = []
        speaker.confidence = 0
        try? database.save(speaker)
        refreshVoices()
    }

    /// A voice the user doesn't need a name for: it keeps its label and leaves the list of voices to name.
    public func ignoreVoice(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        speaker.assignment = .confirmed
        speaker.personId = nil
        speaker.suggestedName = nil
        speaker.suggestedPersonId = nil
        speaker.suggestionReason = nil
        speaker.candidatePersonIds = []
        try? database.save(speaker)
    }

    // MARK: Naming voices one after another

    /// Voices still without a name, worth asking about (a cough or a single "ja" is not): those of
    /// `meetingId` first, the rest newest meeting first.
    public func voicesToName(first meetingId: String? = nil) -> [VoiceReview] {
        let all = (try? database.voiceReviews(limit: 200)) ?? []
        guard let meetingId else { return all }
        return all.filter { $0.speaker.meetingId == meetingId } + all.filter { $0.speaker.meetingId != meetingId }
    }

    public func startNaming(_ meetingId: String? = nil) {
        overlay = .naming(meetingId: meetingId)
    }

    /// After a meeting was processed: if voices wait for a name, offer to name them.
    func promptForVoices(in meetingId: String) {
        // The background check may still name some of them; ask once it is done.
        Task { [weak self] in
            while self?.voiceRefresh != nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard let self else { return }
            let open = self.voicesToName().filter { $0.speaker.meetingId == meetingId }.count
            guard open > 0, let title = self.row(for: meetingId)?.meeting.title else { return }
            self.showToast(
                open == 1 ? "Eine Stimme ohne Namen" : "\(open) Stimmen ohne Namen",
                "„\(title)“ ist fertig.",
                action: .nameVoices(meetingId: meetingId)
            )
        }
    }

    // MARK: Lines the app moved

    /// The app's move was right: the lines stay, and count as the user's word from now on.
    public func acceptMovedLines(_ segmentIds: [Int64]) {
        try? database.acceptMovedLines(segmentIds)
        refreshVoices()
    }

    /// The app's move was wrong: the lines go back, and the app leaves them there.
    public func returnMovedLines(_ segmentIds: [Int64], in meetingId: String) {
        try? database.returnMovedLines(segmentIds, in: meetingId)
        refreshVoices()
    }

    // MARK: Lines and voice groups

    /// Gives some lines of a meeting to a person: they become (part of) that person's voice in the
    /// meeting, confirmed. For a group of lines that sounds unlike the rest of its speaker.
    public func assignLines(_ segmentIds: [Int64], in meetingId: String, to personId: String) {
        do {
            try database.moveLines(segmentIds, in: meetingId, toPerson: personId)
        } catch {
            showToast("Zuordnung fehlgeschlagen", error.localizedDescription, isError: true)
            return
        }
        refreshVoices()
    }

    public func assignLines(_ segmentIds: [Int64], in meetingId: String, toNewPersonNamed name: String, email: String? = nil) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let person = try? database.person(named: name, email: email) else { return }
        assignLines(segmentIds, in: meetingId, to: person.id)
    }

    /// Makes some lines a voice of their own, to be named later.
    public func separateLines(_ segmentIds: [Int64], in meetingId: String) {
        do {
            try database.moveLinesToNewVoice(segmentIds, in: meetingId)
        } catch {
            showToast("Trennen fehlgeschlagen", error.localizedDescription, isError: true)
            return
        }
        refreshVoices()
    }

    /// Lines that should (not) count for their speaker's voice: a cough, crosstalk, someone else.
    public func setLinesIgnored(_ segmentIds: [Int64], ignored: Bool) {
        try? database.setVoiceIgnored(segmentIds, ignored: ignored)
        refreshVoices()
    }

    /// Moves one of a person's voice groups, in every meeting it comes from, to someone else.
    public func move(_ group: VoiceProfile.Group, of profile: VoiceProfile, to personId: String) {
        let samples = group.members.map { profile.samples[$0] }
        do {
            for (meetingId, lines) in Dictionary(grouping: samples.filter { $0.segmentId != nil && $0.meetingId != nil }, by: { $0.meetingId! }) {
                try database.moveLines(lines.compactMap(\.segmentId), in: meetingId, toPerson: personId)
            }
            try database.moveVoiceprints(samples.filter { $0.source == .legacy }.map(\.id), to: personId)
        } catch {
            showToast("Verschieben fehlgeschlagen", error.localizedDescription, isError: true)
            return
        }
        refreshVoices()
    }

    public func move(_ group: VoiceProfile.Group, of profile: VoiceProfile, toNewPersonNamed name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let person = try? database.person(named: name) else { return }
        move(group, of: profile, to: person.id)
    }

    /// Stops (or resumes) learning from one of a person's voice groups; the lines keep their name.
    public func setIgnored(_ group: VoiceProfile.Group, of profile: VoiceProfile, ignored: Bool) {
        let samples = group.members.map { profile.samples[$0] }
        try? database.setVoiceIgnored(samples.compactMap(\.segmentId), ignored: ignored)
        if ignored { try? database.deleteVoiceprints(samples.filter { $0.source == .legacy }.map(\.id)) }
        refreshVoices()
    }

    // MARK: People

    public func rename(_ person: Person, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var person = person
        person.name = trimmed
        try? database.save(person)
    }

    public func merge(_ source: Person, into target: Person) {
        guard source.id != target.id, !source.isMe else { return }
        do {
            try database.mergePerson(source.id, into: target.id)
            showToast("Zusammengeführt", "\(source.name) ist jetzt \(target.name).")
        } catch {
            showToast("Zusammenführen fehlgeschlagen", error.localizedDescription, isError: true)
        }
        refreshVoices()
    }

    public func delete(_ person: Person) {
        guard !person.isMe else { return }
        try? database.deletePerson(person.id)
        refreshVoices()
    }

    /// Stops learning from everything the person said; who said what stays.
    public func forgetVoice(of person: Person) {
        try? database.ignoreVoice(of: person.id)
        refreshVoices()
    }

    // MARK: Keeping voices up to date

    /// Rebuilds what the app knows about everyone's voice and judges every unsettled voice again (see
    /// `VoiceRecheck`). Runs in the background; calls while it runs make it run once more afterwards.
    public func refreshVoices() {
        guard voiceRefresh == nil else {
            voiceRefreshAgain = true
            return
        }
        let database = database
        let thresholds = settings.voiceStrictness.thresholds
        let learn = settings.learnVoices
        voiceRefresh = Task { [weak self] in
            let library = await Task.detached(priority: .utility) { () -> VoiceLibrary in
                func load() -> VoiceLibrary {
                    VoiceLibrary(samples: ((try? database.voiceSamples()) ?? []).filter { learn || $0.source != .automatic })
                }
                // Names first, then lines in the wrong place; a move can make a name clearer, so twice at most.
                var library = load()
                for _ in 0..<2 {
                    let renamed = (try? VoiceRecheck.run(database: database, library: library, thresholds: thresholds)) ?? 0
                    if renamed > 0 { library = load() }
                    let moved = (try? VoiceRecheck.moveStrayLines(database: database, library: library, thresholds: thresholds)) ?? 0
                    if moved > 0 { library = load() }
                    if renamed == 0, moved == 0 { break }
                }
                return library
            }.value
            guard let self else { return }
            self.voiceLibrary = library
            self.voiceRefresh = nil
            if self.voiceRefreshAgain {
                self.voiceRefreshAgain = false
                self.refreshVoices()
            }
        }
    }

    /// Once after an update: repairs call tracks recorded at the wrong rate, and gives the lines of older
    /// meetings voice embeddings of their own, so their voices count line by line.
    func startVoiceMaintenance() {
        guard !isDemo else { return }
        let database = database
        let engine = engine
        let relay = WeakModel(self)
        let checked = settings.callTracksChecked
        let model = settings.transcriptionModel
        Task.detached(priority: .utility) {
            if !checked {
                let rows: [MeetingRow] = (try? database.meetingRows()) ?? []
                let meetings: [Meeting] = rows.map(\.meeting).filter { meeting in
                    meeting.origin == .recording && (meeting.status == .ready || meeting.status == .failed)
                }
                let repaired = meetings.map(\.id).filter { (try? CallTrackRepair.repairFile(meetingId: $0)) == true }
                await MainActor.run { relay.model?.settings.callTracksChecked = true }
                if !repaired.isEmpty {
                    await MainActor.run {
                        guard let model = relay.model else { return }
                        model.showToast(
                            repaired.count == 1 ? "Eine Aufnahme wird repariert" : "\(repaired.count) Aufnahmen werden repariert",
                            "Die Gesprächspartner waren zu schnell und doppelt zu hören. Die Meetings werden neu verarbeitet."
                        )
                        for id in repaired { model.reprocess(id) }
                    }
                }
            }
            let queued: Set<String> = await MainActor.run { relay.model?.queuedMeetings ?? [] }
            let candidates: [Meeting] = (try? database.meetingsWithoutLineVoices()) ?? []
            let older = candidates.filter { meeting in !queued.contains(meeting.id) && AudioArchiver.hasAudio(meetingId: meeting.id) }
            guard !older.isEmpty else { return }
            let processor = MeetingProcessor(database: database, engine: engine)
            for meeting in older {
                do {
                    try await processor.embedLines(meetingId: meeting.id, model: model)
                } catch {
                    Log.pipeline.error("Line voices for \(meeting.id) failed: \(error.localizedDescription)")
                }
            }
            await MainActor.run { relay.model?.refreshVoices() }
        }
    }
}

extension AppDatabase {
    /// Older averaged voice samples (by `VoiceSample.id`, "print-…") that belong to someone else.
    func moveVoiceprints(_ sampleIds: [String], to personId: String) throws {
        let ids = sampleIds.compactMap { $0.hasPrefix("print-") ? String($0.dropFirst(6)) : nil }
        guard !ids.isEmpty else { return }
        try writer.write { db in
            for id in ids { try db.execute(sql: "UPDATE voiceprint SET personId = ? WHERE id = ?", arguments: [personId, id]) }
        }
    }

    func deleteVoiceprints(_ sampleIds: [String]) throws {
        let ids = sampleIds.compactMap { $0.hasPrefix("print-") ? String($0.dropFirst(6)) : nil }
        guard !ids.isEmpty else { return }
        _ = try writer.write { db in try Voiceprint.deleteAll(db, keys: ids) }
    }
}
