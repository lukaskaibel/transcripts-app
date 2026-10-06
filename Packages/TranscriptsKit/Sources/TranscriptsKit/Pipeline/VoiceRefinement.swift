import Foundation

/// A second opinion on the speaker separation, from voices the app already knows.
///
/// The diarizer sometimes puts two similar voices into one speaker, mostly in short meetings or on
/// poor connections. Each line is compared with the voice library on its own: when a speaker's lines
/// clearly belong to two known people, the speaker is split, and lines that sound like nobody in that
/// speaker get a voice of their own. Without known voices nothing changes.
public enum VoiceRefinement {
    /// A piece of speech the diarizer gave one voice: a turn, with its embedding when long enough.
    public struct Unit: Sendable {
        public var key: String
        public var duration: Double
        public var embedding: [Float]?
        /// Names the speaker gives for themselves in this piece ("hier ist Paula").
        public var introducedNames: [String]

        public init(key: String, duration: Double, embedding: [Float]?, introducedNames: [String] = []) {
            self.key = key
            self.duration = duration
            self.embedding = embedding
            self.introducedNames = introducedNames
        }
    }

    /// The (possibly changed) voice key for each unit.
    public static func refine(
        _ units: [Unit],
        library: VoiceLibrary,
        thresholds: VoiceThresholds,
        excluding: Set<String> = [],
        nameOf: (String) -> String? = { _ in nil }
    ) -> [String] {
        var keys = units.map(\.key)
        guard !library.isEmpty else { return keys }
        var used = Set(keys)
        func newKey() -> String {
            var number = used.count + 1
            while used.contains("S\(number)") { number += 1 }
            let key = "S\(number)"
            used.insert(key)
            return key
        }
        func speech(_ indices: [Int]) -> Double {
            indices.reduce(0) { $0 + units[$1].duration }
        }

        var seen: [String] = []
        for key in units.map(\.key) where !seen.contains(key) && key != MeetingSpeaker.meKey { seen.append(key) }
        for key in seen {
            let indices = units.indices.filter { units[$0].key == key }
            var strong: [String: [Int]] = [:]
            var weak: [Int] = []
            var introduced: [String: [Int]] = [:]
            for index in indices {
                guard let embedding = units[index].embedding else { continue }
                let matches = library.rank(embedding, excluding: excluding)
                if let best = matches.first, best.similarity >= thresholds.automatic,
                   best.similarity - (matches.dropFirst().first?.similarity ?? 0) >= thresholds.margin {
                    // Someone who introduces themselves by another name is not this person, however alike they sound.
                    if let name = units[index].introducedNames.first, let known = nameOf(best.personId),
                       NameEvidenceFinder.normalizedName(name) != NameEvidenceFinder.normalizedName(known) {
                        introduced[NameEvidenceFinder.normalizedName(name), default: []].append(index)
                    } else {
                        strong[best.personId, default: []].append(index)
                    }
                } else {
                    weak.append(index)
                }
            }
            for group in introduced.values {
                let separate = newKey()
                for index in group { keys[index] = separate }
            }
            // Only people with a real share of this voice count; one stray piece proves nothing.
            let groups = strong.filter { speech($0.value) >= 4 || $0.value.count >= 2 }
                .sorted { speech($0.value) > speech($1.value) }
            guard let dominant = groups.first else { continue }

            var groupKeys: [String: String] = [dominant.key: key]
            for group in groups.dropFirst() {
                let split = newKey()
                groupKeys[group.key] = split
                for index in group.value { keys[index] = split }
            }

            // The other pieces go to whichever of these people they sound most like, or, if they sound
            // like none of them, to a new voice.
            var strays: [Int] = []
            var introducedWeak: [String: [Int]] = [:]
            for index in weak {
                guard let embedding = units[index].embedding else { continue }
                let scores = groups.map { group -> (String, Float) in
                    let voices = library.voices[group.key] ?? []
                    return (group.key, voices.map { VoiceMath.cosine(embedding, $0) }.max() ?? 0)
                }.sorted { $0.1 > $1.1 }
                guard let best = scores.first else { continue }
                let runnerUp = scores.dropFirst().first?.1 ?? 0
                let clear = best.1 - runnerUp >= 0.05
                // Here too: a piece that introduces itself by another name than the person it would go to
                // is someone else.
                if let name = units[index].introducedNames.first, let known = nameOf(clear ? best.0 : dominant.key),
                   NameEvidenceFinder.normalizedName(name) != NameEvidenceFinder.normalizedName(known) {
                    introducedWeak[NameEvidenceFinder.normalizedName(name), default: []].append(index)
                } else if best.1 < thresholds.suggestion - 0.15, units[index].duration >= 2 {
                    strays.append(index)
                } else if clear, let target = groupKeys[best.0] {
                    keys[index] = target
                }
            }
            for group in introducedWeak.values {
                let separate = newKey()
                for index in group { keys[index] = separate }
            }
            if speech(strays) >= 3 {
                let stray = newKey()
                for index in strays { keys[index] = stray }
            }
        }
        return keys
    }
}
