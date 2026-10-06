import Foundation

/// A transcript line before it is saved.
public struct DraftLine: Equatable, Sendable {
    public var speakerKey: String
    public var channel: Channel
    public var start: Double
    public var end: Double
    public var words: [TimedWord]

    public init(speakerKey: String, channel: Channel, start: Double, end: Double, words: [TimedWord]) {
        self.speakerKey = speakerKey
        self.channel = channel
        self.start = start
        self.end = end
        self.words = words
    }

    public var text: String { TranscriptAssembly.join(words) }
    public var duration: Double { end - start }
}

/// Turns timed words and "who spoke when" into readable transcript lines.
public enum TranscriptAssembly {
    /// A pause this long starts a new line even when the same person keeps talking.
    static let pauseForNewLine = 1.6
    /// Lines longer than this are split at the next sentence end.
    static let maxLineDuration = 40.0

    /// The diarization speaker for every word: the turn around the word's middle, else the nearest turn
    /// within a second, else whoever spoke the word before.
    public static func speakers(for words: [TimedWord], turns: [SpeakerTurn]) -> [String] {
        guard !turns.isEmpty else { return words.map { _ in "S1" } }
        var speakers: [String] = []
        var turnIndices: [Int] = []
        speakers.reserveCapacity(words.count)
        var cursor = 0
        var previous: (speaker: String, turn: Int)?
        for word in words {
            let middle = (word.start + word.end) / 2
            // Turns are sorted by start; everything before the cursor ended more than 5 s ago.
            while cursor < turns.count - 1, turns[cursor].end < middle - 5 { cursor += 1 }
            var best: (turn: Int, distance: Double, length: Double)?
            var index = cursor
            while index < turns.count, turns[index].start <= middle + 5 {
                let turn = turns[index]
                let distance = middle < turn.start ? turn.start - middle : (middle > turn.end ? middle - turn.end : 0)
                let length = turn.end - turn.start
                // Inside two overlapping turns the shorter one is usually an interjection; keep the longer.
                if best == nil || distance < best!.distance || (distance == best!.distance && length > best!.length) {
                    best = (index, distance, length)
                }
                index += 1
            }
            let chosen: (speaker: String, turn: Int)
            if let best, best.distance <= 1.0 {
                chosen = (turns[best.turn].speaker, best.turn)
            } else if let previous {
                chosen = previous
            } else {
                let nearest = turns.indices.min { abs(turns[$0].start - middle) < abs(turns[$1].start - middle) }!
                chosen = (turns[nearest].speaker, nearest)
            }
            speakers.append(chosen.speaker)
            turnIndices.append(chosen.turn)
            previous = chosen
        }
        return smoothed(speakers, turns: turnIndices, words: words)
    }

    /// Cleans up the speaker changes the voice model places a little off:
    ///
    /// - a single word that disagrees with both neighbours is a boundary error;
    /// - a change in the middle of a sentence, where the sentence began with a short turn of the
    ///   previous voice, really happened at the start of the sentence: the model gave the first second
    ///   of the new voice to the old one. (The speech model's word times run without gaps, so the
    ///   turn boundary is the only reliable sign of the pause.)
    static func smoothed(_ speakers: [String], turns: [Int]? = nil, words: [TimedWord]) -> [String] {
        guard speakers.count >= 3 else { return speakers }
        var result = speakers
        for index in 1..<(speakers.count - 1) {
            let before = result[index - 1]
            let after = speakers[index + 1]
            if speakers[index] != before, before == after, words[index].end - words[index].start < 0.6 {
                result[index] = before
            }
        }
        guard let turns else { return result }
        for change in 1..<result.count where result[change] != result[change - 1] {
            // Only changes that cut a sentence in two: no sentence end before, a lowercase word after.
            guard !endsSentence(words[change - 1].text), continuesSentence(words[change].text) else { continue }
            var start = change - 1
            while start > 0, result[start - 1] == result[change - 1], !endsSentence(words[start - 1].text) {
                start -= 1
            }
            // The cut-off part must be the start of the sentence.
            guard start == 0 || endsSentence(words[start - 1].text) else { continue }
            // The sentence must start a turn of its own, and that turn must be short.
            guard start == 0 || turns[start] != turns[start - 1] else { continue }
            // Either the voice before the sentence was late to change, or the diarizer gave just this piece
            // to a voice of its own. Then the other voice must go on talking after the sentence; otherwise
            // the sentence is split between two short turns and the end is the stray part (see below).
            let lateChange = start > 0 && result[start - 1] == result[change - 1]
            if !lateChange {
                var end = change
                while end < result.count - 1, result[end + 1] == result[change], !endsSentence(words[end].text) {
                    end += 1
                }
                guard endsSentence(words[end].text), end < result.count - 1, turns[end + 1] == turns[end] else { continue }
            }
            let stretch = words[change - 1].end - words[start].start
            if stretch <= 2.5 {
                for index in start..<change { result[index] = result[change] }
            }
        }
        // The mirror case: the end of a sentence was given to another voice as a short turn of its own
        // ("Ich kann bei den Tests unterstützen, | wenn Thomas mir die Testfälle schickt."), and that
        // voice says nothing else in the turn.
        for change in 1..<result.count where result[change] != result[change - 1] {
            guard !endsSentence(words[change - 1].text) else { continue }
            var end = change
            while end < result.count - 1, result[end + 1] == result[change], !endsSentence(words[end].text) {
                end += 1
            }
            guard endsSentence(words[end].text), turns[change] != turns[change - 1] else { continue }
            let turnEnds = end == result.count - 1 || turns[end + 1] != turns[end]
            let stretch = words[end].end - words[change].start
            // A capitalised word may begin a sentence the model left unpunctuated; a lone word ending the
            // sentence ("für das neue | Formular.") is no sentence of its own though.
            guard continuesSentence(words[change].text) || (end == change && stretch < 1.0) else { continue }
            if turnEnds, stretch <= 3.5 {
                for index in change...end { result[index] = result[change - 1] }
            }
        }
        return result
    }

    /// Words that start a new line because the voice paused: the first word of a diarization turn that
    /// began well after the previous one ended. (The speech model's word times have no gaps of their own.)
    public static func pauseBreaks(words: [TimedWord], turns: [SpeakerTurn], minimumPause: Double = 1.2) -> Set<Int> {
        guard turns.count > 1 else { return [] }
        // The silence between two turns: the new line starts with the first word spoken after it began.
        let gaps = zip(turns.dropFirst(), turns).compactMap { next, previous in
            next.start - previous.end >= minimumPause ? previous.end : nil
        }
        var breaks = Set<Int>()
        var cursor = 0
        for gapStart in gaps {
            while cursor < words.count, words[cursor].start < gapStart - 0.05 { cursor += 1 }
            if cursor > 0, cursor < words.count { breaks.insert(cursor) }
        }
        return breaks
    }

    /// Groups consecutive words by speaker into lines.
    public static func lines(words: [TimedWord], speakers: [String], channel: Channel, breaks: Set<Int> = []) -> [DraftLine] {
        precondition(words.count == speakers.count)
        var lines: [DraftLine] = []
        var current: DraftLine?
        for (index, (word, speaker)) in zip(words, speakers).enumerated() {
            if var line = current {
                let pause = word.start - line.end
                let sentenceEnded = line.words.last.map { endsSentence($0.text) } ?? false
                let tooLong = line.duration > maxLineDuration && sentenceEnded
                if speaker != line.speakerKey || pause > pauseForNewLine || tooLong || breaks.contains(index) {
                    lines.append(line)
                    current = DraftLine(speakerKey: speaker, channel: channel, start: word.start, end: word.end, words: [word])
                } else {
                    line.words.append(word)
                    line.end = max(line.end, word.end)
                    current = line
                }
            } else {
                current = DraftLine(speakerKey: speaker, channel: channel, start: word.start, end: word.end, words: [word])
            }
        }
        if let current { lines.append(current) }
        return lines.filter { !$0.text.isEmpty }
    }

    /// Words to text. The model attaches punctuation to the word before it, so a space between words is right.
    public static func join(_ words: [TimedWord]) -> String {
        var text = ""
        for word in words {
            let piece = word.text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            if text.isEmpty || piece.first.map({ ",.!?;:…)".contains($0) }) == true {
                text += piece
            } else {
                text += " " + piece
            }
        }
        return text
    }

    /// A word that carries a sentence on rather than starting one: the speech model capitalises
    /// sentence starts, so a lowercase word is mid-sentence.
    /// A word that can't start a sentence: lowercase, or a number ("auf den | 14. Oktober").
    static func continuesSentence(_ word: String) -> Bool {
        word.first.map { $0.isLowercase || $0.isNumber } ?? false
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".!?…".contains(last)
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    /// Drops microphone lines that only repeat what the call played (the call came out of the speakers
    /// and back into the microphone). A line counts as an echo when most of its words were said on the
    /// call within a second and a half of it.
    public static func removeEchoes(microphone: [DraftLine], system: [DraftLine]) -> [DraftLine] {
        let systemWords = system.flatMap(\.words).sorted { $0.start < $1.start }
        guard !systemWords.isEmpty else { return microphone }
        return microphone.filter { line in
            let words = line.words.map { normalized($0.text) }.filter { !$0.isEmpty }
            guard !words.isEmpty else { return false }
            let window = (line.start - 1.5)...(line.end + 1.5)
            let nearby = Set(systemWords.lazy.filter { window.contains($0.start) }.map { normalized($0.text) })
            guard !nearby.isEmpty else { return true }
            let echoed = words.filter { nearby.contains($0) }.count
            let fraction = Double(echoed) / Double(words.count)
            return words.count <= 2 ? fraction < 1 : fraction < 0.6
        }
    }

    /// Renames diarization speakers to "S1", "S2", … in order of their first word.
    public static func renumbered(_ lines: [DraftLine], prefix: String = "S") -> (lines: [DraftLine], mapping: [String: String]) {
        var mapping: [String: String] = [:]
        var lines = lines
        for index in lines.indices {
            let original = lines[index].speakerKey
            if let mapped = mapping[original] {
                lines[index].speakerKey = mapped
            } else {
                let key = "\(prefix)\(mapping.count + 1)"
                mapping[original] = key
                lines[index].speakerKey = key
            }
        }
        return (lines, mapping)
    }

    /// Merges the two channels into one transcript in time order.
    public static func merged(_ a: [DraftLine], _ b: [DraftLine]) -> [DraftLine] {
        (a + b).sorted { $0.start == $1.start ? $0.channel == .system : $0.start < $1.start }
    }
}
