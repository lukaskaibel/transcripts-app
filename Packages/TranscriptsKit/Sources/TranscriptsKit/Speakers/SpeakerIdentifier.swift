import Foundation

/// A voice of one meeting, ready to be named.
public struct VoiceToName: Sendable {
    public var key: String
    public var embedding: [Float]?
    public var talkTime: Double

    public init(key: String, embedding: [Float]?, talkTime: Double) {
        self.key = key
        self.embedding = embedding
        self.talkTime = talkTime
    }
}

/// What the app concluded about one voice.
public struct IdentityDecision: Equatable, Sendable {
    public var assignment: MeetingSpeaker.Assignment
    public var personId: String?
    public var suggestedPersonId: String?
    public var suggestedName: String?
    public var reason: String?
    public var confidence: Double
    /// Whom the voice may be, when it isn't named: the closest voices, most likely first.
    public var candidates: [String] = []

    public static let unknown = IdentityDecision(assignment: .unknown, personId: nil, suggestedPersonId: nil, suggestedName: nil, reason: nil, confidence: 0)
}

/// Puts the voice library, the calendar and what was said together to name the voices of a meeting.
///
/// The app only names a voice by itself when the voice clearly matches someone it has learned before.
/// Everything less certain becomes a suggestion that waits for one click, so a wrong guess never
/// trains the library.
public struct SpeakerIdentifier {
    public var library: VoiceLibrary
    public var people: [Person]
    /// Invitees of the calendar event, without the user.
    public var attendees: [Attendee]
    public var thresholds: VoiceThresholds
    /// The display name of a speaker key, for quoting ("Miriam: „Gute Idee, Jonas.“").
    public var nameOfKey: (String) -> String

    public init(library: VoiceLibrary, people: [Person], attendees: [Attendee], thresholds: VoiceThresholds, nameOfKey: @escaping (String) -> String) {
        self.library = library
        self.people = people
        self.attendees = attendees
        self.thresholds = thresholds
        self.nameOfKey = nameOfKey
    }

    public func decide(voices: [VoiceToName], guesses: [String: [NameGuess]]) -> [String: IdentityDecision] {
        let me = people.first(where: \.isMe)?.id
        let boosted = Set(attendees.compactMap { person(for: $0)?.id })
        var decisions: [String: IdentityDecision] = [:]
        for voice in voices {
            let matches = voice.embedding.map { library.rank($0, boosted: boosted, excluding: me.map { [$0] } ?? []) } ?? []
            var decision = decide(voice: voice, matches: matches, guess: guesses[voice.key]?.first)
            if decision.assignment != .automatic {
                decision.candidates = VoiceLibrary.candidates(matches, thresholds: thresholds)
            }
            decisions[voice.key] = decision
        }
        // A one-to-one call: the only other voice is most likely the only other invitee.
        let undecided = voices.filter { decisions[$0.key]?.assignment == .unknown }
        if voices.count == 1, undecided.count == 1, attendees.count == 1, let attendee = attendees.first {
            let key = undecided[0].key
            if let person = person(for: attendee) {
                decisions[key] = IdentityDecision(assignment: .suggested, personId: nil, suggestedPersonId: person.id, suggestedName: nil, reason: Self.calendarReason, confidence: 0.5)
            } else {
                decisions[key] = IdentityDecision(assignment: .suggested, personId: nil, suggestedPersonId: nil, suggestedName: attendee.name, reason: Self.calendarReason, confidence: 0.5)
            }
        }
        return decisions
    }

    private func decide(voice: VoiceToName, matches: [VoiceMatch], guess: NameGuess?) -> IdentityDecision {
        let best = matches.first
        let runnerUp = matches.dropFirst().first?.similarity ?? 0
        let usableGuess = guess.flatMap { $0.score >= 1.2 ? $0 : nil }
        let guessedPerson = usableGuess.flatMap { person(named: $0.name) }

        if let best, best.similarity >= thresholds.automatic, best.similarity - runnerUp >= thresholds.margin {
            if let usableGuess, usableGuess.bestClue.kind == .introduction, guessedPerson?.id != best.personId,
               NameEvidenceFinder.normalizedName(usableGuess.name) != NameEvidenceFinder.normalizedName(people.first { $0.id == best.personId }?.name ?? "") {
                // The voice says one person, the introduction another: ask.
                return IdentityDecision(
                    assignment: .suggested, personId: nil, suggestedPersonId: guessedPerson?.id,
                    suggestedName: guessedPerson == nil ? (attendee(named: usableGuess.name)?.name ?? usableGuess.name) : nil,
                    reason: reason(for: usableGuess.bestClue), confidence: min(Double(best.similarity), 1)
                )
            }
            return IdentityDecision(assignment: .automatic, personId: best.personId, suggestedPersonId: nil, suggestedName: nil, reason: voiceReason(best), confidence: min(Double(best.similarity), 1))
        }

        if let usableGuess {
            let quote = reason(for: usableGuess.bestClue)
            if let guessedPerson {
                let similarity = matches.first { $0.personId == guessedPerson.id }?.similarity ?? 0
                return IdentityDecision(assignment: .suggested, personId: nil, suggestedPersonId: guessedPerson.id, suggestedName: nil, reason: quote, confidence: min(Double(max(similarity, 0)), 1))
            }
            let attendeeName = attendee(named: usableGuess.name)?.name
            return IdentityDecision(assignment: .suggested, personId: nil, suggestedPersonId: nil, suggestedName: attendeeName ?? usableGuess.name, reason: quote, confidence: 0)
        }

        if let best, best.similarity >= thresholds.suggestion {
            return IdentityDecision(assignment: .suggested, personId: nil, suggestedPersonId: best.personId, suggestedName: nil, reason: voiceReason(best), confidence: min(Double(best.similarity), 1))
        }
        return .unknown
    }

    // MARK: Matching names to people

    /// The known person a spoken name refers to: same full name, or a first name only one person has.
    /// Among several people with that first name, a calendar invitee wins.
    func person(named name: String) -> Person? {
        let lowered = name.lowercased()
        let candidates = people.filter { !$0.isMe }
        if let exact = candidates.first(where: { $0.name.lowercased() == lowered }) { return exact }
        let first = NameEvidenceFinder.normalizedName(name)
        let sameFirst = candidates.filter { NameEvidenceFinder.normalizedName($0.name) == first }
        if sameFirst.count == 1 { return sameFirst[0] }
        if sameFirst.count > 1 {
            let invited = sameFirst.filter { person in attendees.contains { matches($0, person) } }
            if invited.count == 1 { return invited[0] }
        }
        return nil
    }

    func person(for attendee: Attendee) -> Person? {
        people.first { !$0.isMe && matches(attendee, $0) }
    }

    func attendee(named name: String) -> Attendee? {
        let first = NameEvidenceFinder.normalizedName(name)
        let found = attendees.filter { NameEvidenceFinder.normalizedName($0.name) == first || $0.name.lowercased() == name.lowercased() }
        return found.count == 1 ? found[0] : nil
    }

    private func matches(_ attendee: Attendee, _ person: Person) -> Bool {
        if let email = attendee.email?.lowercased(), let personEmail = person.email?.lowercased(), email == personEmail { return true }
        return attendee.name.lowercased() == person.name.lowercased()
    }

    // MARK: Reasons shown to the user

    func reason(for clue: NameClue) -> String {
        switch clue.kind {
        case .introduction:
            return "„\(clue.quote)“"
        case .assistant:
            return clue.quote.isEmpty ? Self.conversationReason : "„\(clue.quote)“"
        case .askedBefore, .answeredAfter:
            return "\(nameOfKey(clue.quoteSpeakerKey)): „\(clue.quote)“"
        }
    }

    private func voiceReason(_ match: VoiceMatch) -> String {
        Self.voiceReason(match)
    }

    static func voiceReason(_ match: VoiceMatch) -> String {
        match.meetings == 1 ? "\(voiceReasonPrefix) einem früheren Meeting" : "\(voiceReasonPrefix) \(match.meetings) früheren Meetings"
    }

    // Reasons are stored in German and shown in the interface's language by `Strings.reason(_:)`.
    static let voiceReasonPrefix = "Stimme ähnlich wie in"
    static let conversationReason = "Aus dem Gesprächsverlauf"
    static let calendarReason = "Einziger weiterer Teilnehmer im Kalender"

    /// 2 for "Stimme ähnlich wie in 2 früheren Meetings", 1 for "… einem früheren Meeting".
    static func meetings(inVoiceReason reason: String) -> Int? {
        guard reason.hasPrefix(voiceReasonPrefix) else { return nil }
        let rest = reason.dropFirst(voiceReasonPrefix.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("einem") { return 1 }
        return rest.split(separator: " ").first.flatMap { Int($0) }
    }

    /// Whether a suggestion rests on the voice alone (rather than on a name that was said).
    static func isVoiceReason(_ reason: String?) -> Bool {
        reason?.hasPrefix(voiceReasonPrefix) ?? false
    }
}
