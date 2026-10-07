import Foundation

/// A second look at each line of a running meeting.
///
/// The live diarizer sees only a few seconds at a time and can lump similar voices together; once such
/// a voice is named, everything the others say would carry that name. So each line is checked on its
/// own, like `VoiceRefinement` does after the meeting: a line that clearly sounds like another known
/// person, or in which someone introduces themselves by another name, goes to that person instead.
public enum LiveLineCheck {
    public enum Outcome: Equatable, Sendable {
        case keep
        /// Another voice of this meeting is that person already.
        case move(to: String)
        /// Someone not heard in this meeting yet: a known person, or a name they gave themselves.
        case newVoice(personId: String?, suggestedName: String?)
    }

    /// - Parameters:
    ///   - voice: The line's own embedding, if it was long enough for one.
    ///   - names: Names of the known people, by ID.
    public static func check(
        key: String,
        voice: [Float]?,
        text: String,
        voices: [String: LiveVoice],
        library: VoiceLibrary,
        names: [String: String],
        me: String?,
        thresholds: VoiceThresholds,
        finder: NameEvidenceFinder
    ) -> Outcome {
        // Only a voice that carries a name can carry the wrong one.
        guard let current = voices[key], let currentPerson = current.personId, let currentName = current.name else { return .keep }

        if let introduced = finder.introducedNames(in: text).first {
            let name = NameEvidenceFinder.normalizedName(introduced)
            guard name != NameEvidenceFinder.normalizedName(currentName) else { return .keep }
            let other = voices.values.first { voice in
                voice.key != key && [voice.name, voice.suggestedName].compactMap { $0 }.contains { NameEvidenceFinder.normalizedName($0) == name }
            }
            if let other { return .move(to: other.key) }
            return .newVoice(personId: nil, suggestedName: introduced)
        }

        guard let voice, !library.isEmpty else { return .keep }
        let matches = library.rank(voice, excluding: me.map { [$0] } ?? [])
        guard let best = matches.first, best.personId != currentPerson, names[best.personId] != nil,
              best.similarity >= thresholds.automatic,
              best.similarity - (matches.dropFirst().first?.similarity ?? 0) >= thresholds.margin else { return .keep }
        if let other = voices.values.first(where: { $0.personId == best.personId }) { return .move(to: other.key) }
        return .newVoice(personId: best.personId, suggestedName: nil)
    }

    /// A line of the microphone that sounds like the call and not like the user: the call through the
    /// speakers. Measured on the app's first real meetings, this catches about three quarters of such lines
    /// and none the user spoke alone.
    ///
    /// - Parameters:
    ///   - user: How alike the line is to the user's voice, if the app knows it.
    ///   - call: How alike it is to the closest voice of the call (or anyone else the app knows).
    public static func isEchoOfCall(user: Float?, call: Float) -> Bool {
        guard let user else { return call >= 0.7 }
        return user < 0.4 && call >= 0.55 && call >= user + 0.15
    }
}
