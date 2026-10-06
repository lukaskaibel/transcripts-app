import Foundation

extension AppModel {
    // MARK: Providers

    public func apiKey(for provider: ProviderKind) -> String? {
        secrets.secret(for: provider.rawValue)
    }

    public func isConfigured(_ provider: ProviderKind) -> Bool {
        switch provider {
        case .ollama: settings.summaryProvider == .ollama || providerStatus[.ollama] == .connected
        default: !(apiKey(for: provider) ?? "").isEmpty
        }
    }

    public func provider(_ kind: ProviderKind) -> LLMProvider? {
        switch kind {
        case .anthropic: apiKey(for: kind).map { AnthropicProvider(apiKey: $0) }
        case .openAI: apiKey(for: kind).map { OpenAIProvider(apiKey: $0) }
        case .google: apiKey(for: kind).map { GeminiProvider(apiKey: $0) }
        case .ollama: OllamaProvider(baseURL: URL(string: settings.ollamaURL) ?? OllamaProvider.defaultURL)
        }
    }

    /// The model used for a provider: the user's choice, else the first one the provider lists.
    public func model(for kind: ProviderKind) -> String? {
        if let chosen = settings.model(for: kind) { return chosen }
        if let first = providerModels[kind]?.first { return first.id }
        return kind == .anthropic ? AnthropicProvider.defaultModel : nil
    }

    public func modelName(for kind: ProviderKind) -> String? {
        guard let id = model(for: kind) else { return nil }
        return providerModels[kind]?.first { $0.id == id }?.name ?? Self.prettyModelName(id)
    }

    static func prettyModelName(_ id: String) -> String {
        if id.hasPrefix("claude-") {
            // "claude-opus-5-5" → "Claude Opus 5.5"
            let parts = id.split(separator: "-").map(String.init)
            guard parts.count >= 3 else { return id }
            let family = parts[1].capitalized
            let version = parts.dropFirst(2).filter { $0.count <= 2 }.joined(separator: ".")
            return "Claude \(family) \(version)"
        }
        return id
    }

    /// True when summaries can be written right now.
    public var summaryProviderReady: Bool {
        guard let kind = settings.summaryProvider else { return false }
        if kind == .ollama { return providerStatus[.ollama] == .connected || model(for: .ollama) != nil }
        return isConfigured(kind)
    }

    func summaryProvider() -> (LLMProvider, String)? {
        guard let kind = settings.summaryProvider, let provider = provider(kind), let model = model(for: kind) else { return nil }
        return (provider, model)
    }

    /// Asks the provider for its models, which also proves the key works.
    public func checkProvider(_ kind: ProviderKind) async {
        guard let provider = provider(kind) else {
            providerStatus[kind] = .notConfigured
            return
        }
        providerStatus[kind] = .checking
        do {
            let models = try await provider.models()
            providerModels[kind] = models
            providerStatus[kind] = .connected
            if let chosen = settings.model(for: kind), !models.contains(where: { $0.id == chosen }) {
                settings.setModel(nil, for: kind)
            }
        } catch {
            providerStatus[kind] = .failed(error.localizedDescription)
        }
    }

    /// Stores a key, checks it, and makes the provider the summary provider if none was chosen yet.
    public func saveKey(_ key: String, for kind: ProviderKind) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try secrets.setSecret(trimmed, for: kind.rawValue)
        } catch {
            providerStatus[kind] = .failed(error.localizedDescription)
            return false
        }
        await checkProvider(kind)
        guard providerStatus[kind] == .connected else {
            try? secrets.setSecret(nil, for: kind.rawValue)
            return false
        }
        if settings.summaryProvider == nil || !summaryProviderReady { settings.summaryProvider = kind }
        return true
    }

    public func removeKey(for kind: ProviderKind) {
        try? secrets.setSecret(nil, for: kind.rawValue)
        providerStatus[kind] = .notConfigured
        providerModels[kind] = nil
        if settings.summaryProvider == kind {
            settings.summaryProvider = ProviderKind.allCases.first { $0 != kind && isConfigured($0) }
        }
    }

    public func connectOllama(url: String) async {
        settings.ollamaURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        await checkProvider(.ollama)
        if providerStatus[.ollama] == .connected, settings.summaryProvider == nil {
            settings.summaryProvider = .ollama
        }
    }

    public func choose(model: String, for kind: ProviderKind) {
        settings.setModel(model, for: kind)
        settings.summaryProvider = kind
    }

    // MARK: Summaries

    public func isSummarizing(_ meetingId: String) -> Bool {
        summarizing.contains(meetingId)
    }

    /// Writes (or rewrites) the summary of a meeting.
    public func generateSummary(_ meetingId: String) async {
        guard !summarizing.contains(meetingId) else { return }
        guard let (provider, model) = summaryProvider() else {
            showToast("Kein KI-Modell eingerichtet", "Hinterlege in den Einstellungen unter KI einen API-Key oder verbinde Ollama.", isError: true)
            return
        }
        guard let detail = try? database.detail(of: meetingId), !detail.segments.isEmpty else {
            showToast("Nichts zusammenzufassen", "Dieses Meeting hat noch kein Transkript.")
            return
        }
        summarizing.insert(meetingId)
        defer { summarizing.remove(meetingId) }
        do {
            let outcome = try await Summarizer.summarize(detail, myName: me?.name ?? myName, language: settings.summaryLanguage, provider: provider, model: model)
            let summary = MeetingSummary(
                meetingId: meetingId,
                overview: outcome.overview,
                decisions: outcome.decisions,
                openQuestions: outcome.openQuestions,
                model: modelName(for: provider.kind) ?? model,
                provider: provider.kind.title
            )
            let items = outcome.actionItems.map { ActionItem(meetingId: meetingId, text: $0.text, owner: $0.owner, due: $0.due) }
            try database.save(summary: summary, actionItems: items)
            if !detail.meeting.titleIsCustom, detail.meeting.calendarEventId == nil, !outcome.title.isEmpty {
                try database.update(meetingId: meetingId) { $0.title = outcome.title }
            }
            applyNameHints(outcome.speakerNames, in: detail)
        } catch {
            showToast("Zusammenfassung fehlgeschlagen", error.localizedDescription, isError: true)
        }
    }

    public func deleteSummary(_ meetingId: String) {
        try? database.deleteSummary(of: meetingId)
    }

    /// Names the language model found for unknown voices become suggestions.
    func applyNameHints(_ hints: [SpeakerNameHint], in detail: MeetingDetail) {
        guard !hints.isEmpty else { return }
        let identifier = SpeakerIdentifier(library: VoiceLibrary(), people: people, attendees: detail.meeting.attendees, thresholds: settings.voiceStrictness.thresholds) { $0 }
        for hint in hints {
            guard var speaker = detail.speakers.first(where: { $0.label.lowercased() == hint.speakerLabel.lowercased() }),
                  speaker.assignment == .unknown else { continue }
            speaker.assignment = .suggested
            if let person = identifier.person(named: hint.name) {
                speaker.suggestedPersonId = person.id
            } else {
                speaker.suggestedName = identifier.attendee(named: hint.name)?.name ?? hint.name
            }
            speaker.suggestionReason = hint.evidence.isEmpty ? "Aus dem Gesprächsverlauf" : "„\(hint.evidence)“"
            try? database.save(speaker)
        }
    }

    public func toggleActionItem(_ item: ActionItem) {
        guard let id = item.id else { return }
        try? database.setActionItem(id, done: !item.done)
    }
}

// MARK: - Speakers and people

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

    public func rejectSuggestion(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        speaker.assignment = .unknown
        speaker.suggestedPersonId = nil
        speaker.suggestedName = nil
        speaker.suggestionReason = nil
        speaker.confidence = 0
        try? database.save(speaker)
    }

    /// Names a voice. The voice is learned, and other meetings' unknown voices are checked against it.
    public func assign(_ speaker: MeetingSpeaker, to personId: String) {
        do {
            try database.assign(speaker, to: personId)
        } catch {
            showToast("Zuordnung fehlgeschlagen", error.localizedDescription, isError: true)
            return
        }
        refreshVoiceSuggestions()
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
        let me = (try? database.mePerson(defaultName: Self.defaultMyName))
        guard let me else { return }
        assign(speaker, to: me.id)
    }

    public func unassign(_ speaker: MeetingSpeaker) {
        var speaker = speaker
        speaker.personId = nil
        speaker.assignment = .unknown
        speaker.confidence = 0
        try? database.save(speaker)
    }

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
    }

    public func delete(_ person: Person) {
        guard !person.isMe else { return }
        try? database.deletePerson(person.id)
    }

    public func forgetVoice(of person: Person) {
        try? database.deleteVoiceprints(of: person.id)
    }

    /// Re-checks unknown voices of all meetings against the voice library, after it learned something.
    public func refreshVoiceSuggestions() {
        let database = database
        let thresholds = settings.voiceStrictness.thresholds
        Task.detached(priority: .utility) {
            guard let prints = try? database.voiceprints(), let people = try? database.people() else { return }
            let library = VoiceLibrary(voiceprints: prints)
            let me = people.first(where: \.isMe)?.id
            guard let reviews = try? database.voiceReviews(limit: 200) else { return }
            for review in reviews where review.speaker.assignment == .unknown {
                guard let data = review.speaker.embedding else { continue }
                let matches = library.rank([Float](embeddingData: data), excluding: me.map { [$0] } ?? [])
                guard let best = matches.first, best.similarity >= thresholds.suggestion else { continue }
                var speaker = review.speaker
                speaker.assignment = .suggested
                speaker.suggestedPersonId = best.personId
                speaker.confidence = Double(best.similarity)
                speaker.suggestionReason = "Stimme ähnlich wie in \(best.samples == 1 ? "einem früheren Meeting" : "\(best.samples) früheren Meetings")"
                try? database.save(speaker)
            }
        }
    }
}
