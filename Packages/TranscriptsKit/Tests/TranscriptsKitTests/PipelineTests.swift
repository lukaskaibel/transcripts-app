import Foundation
import Testing
@testable import TranscriptsKit

private func words(_ text: String, start: Double, step: Double = 0.4) -> [TimedWord] {
    text.split(separator: " ").enumerated().map { index, word in
        TimedWord(text: String(word), start: start + Double(index) * step, end: start + Double(index) * step + step * 0.8)
    }
}

@Suite struct TranscriptAssemblyTests {
    @Test func wordsTakeTheSpeakerOfTheirTurn() {
        let all = words("Hallo zusammen", start: 0) + words("Guten Morgen", start: 2)
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1), SpeakerTurn(speaker: "B", start: 1.9, end: 3)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "A", "B", "B"])
    }

    @Test func wordsInGapsGoToTheNearestTurn() {
        let all = [TimedWord(text: "a", start: 5.0, end: 5.2), TimedWord(text: "b", start: 9.0, end: 9.1)]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 4.5), SpeakerTurn(speaker: "B", start: 9.5, end: 12)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "B"])
    }

    @Test func singleStrayWordIsSmoothedAway() {
        let all = words("eins zwei drei", start: 0)
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 0.35), SpeakerTurn(speaker: "B", start: 0.35, end: 0.75), SpeakerTurn(speaker: "A", start: 0.75, end: 2)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "A", "A"])
    }

    @Test func lateSpeakerChangeMovesBackToTheSentenceStart() {
        // The real case from the test meeting: word times without gaps, and the diarizer gave the first
        // 1.3 s of Anna ("Letzter Punkt ist die Stelle") to Miriam as a short turn of its own.
        let all = [
            TimedWord(text: "kürzere", start: 60.72, end: 61.36), TimedWord(text: "Formular.", start: 61.36, end: 62.48),
            TimedWord(text: "Letzter", start: 62.48, end: 63.04), TimedWord(text: "Punkt", start: 63.04, end: 63.28),
            TimedWord(text: "ist", start: 63.28, end: 63.36), TimedWord(text: "die", start: 63.68, end: 63.84),
            TimedWord(text: "Stelle", start: 63.84, end: 64.16), TimedWord(text: "im", start: 64.16, end: 64.32),
            TimedWord(text: "Backend,", start: 64.32, end: 65.12),
        ]
        let turns = [
            SpeakerTurn(speaker: "M", start: 56.91, end: 62.22),
            SpeakerTurn(speaker: "M", start: 62.73, end: 64.01),
            SpeakerTurn(speaker: "A", start: 64.01, end: 69.71),
        ]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["M", "M", "A", "A", "A", "A", "A", "A", "A"])
    }

    @Test func sentenceStartGivenToAStrayVoiceJoinsTheRest() {
        // From the 30-minute test: the diarizer gave the start of Anna's sentence to a voice that said
        // nothing else ("Dann verschieben wir das Release auf den | 14. Oktober."), right after Thomas.
        let all = [
            TimedWord(text: "lösen.", start: 424.4, end: 425.4),
            TimedWord(text: "Dann", start: 425.52, end: 425.8), TimedWord(text: "verschieben", start: 425.8, end: 426.4),
            TimedWord(text: "wir", start: 426.4, end: 426.6), TimedWord(text: "das", start: 426.6, end: 426.8),
            TimedWord(text: "Release", start: 426.8, end: 427.3), TimedWord(text: "auf", start: 427.3, end: 427.6),
            TimedWord(text: "den", start: 427.6, end: 427.9), TimedWord(text: "14.", start: 427.92, end: 428.5),
            TimedWord(text: "Oktober.", start: 428.5, end: 429.2), TimedWord(text: "Thomas,", start: 429.6, end: 430.0),
            TimedWord(text: "passt", start: 430.0, end: 430.3), TimedWord(text: "das?", start: 430.3, end: 430.8),
        ]
        let turns = [
            SpeakerTurn(speaker: "T", start: 417.6, end: 425.45),
            SpeakerTurn(speaker: "X", start: 425.5, end: 427.9),
            SpeakerTurn(speaker: "A", start: 427.9, end: 431.0),
        ]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["T"] + Array(repeating: "A", count: 12))
    }

    @Test func aLoneLastWordGoesBackToTheSentence() {
        // From a live recording: "… die Texte für das neue | Formular." with the last word as its own voice.
        let all = [
            TimedWord(text: "für", start: 37.6, end: 37.8), TimedWord(text: "das", start: 37.8, end: 38.0),
            TimedWord(text: "neue", start: 38.0, end: 38.5), TimedWord(text: "Formular.", start: 38.51, end: 39.1),
        ]
        let turns = [SpeakerTurn(speaker: "A", start: 32.8, end: 38.5), SpeakerTurn(speaker: "B", start: 38.5, end: 39.2)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "A", "A", "A"])
        // A capitalised sentence of several words after a missing full stop stays with its voice.
        let next = [
            TimedWord(text: "an", start: 0, end: 0.3), TimedWord(text: "mir", start: 0.3, end: 0.6),
            TimedWord(text: "Ich", start: 0.7, end: 0.9), TimedWord(text: "kann", start: 0.9, end: 1.2),
            TimedWord(text: "helfen.", start: 1.2, end: 1.8),
        ]
        let nextTurns = [SpeakerTurn(speaker: "A", start: 0, end: 0.65), SpeakerTurn(speaker: "B", start: 0.65, end: 2)]
        #expect(TranscriptAssembly.speakers(for: next, turns: nextTurns) == ["A", "A", "B", "B", "B"])
    }

    @Test func numbersContinueASentence() {
        #expect(TranscriptAssembly.continuesSentence("14."))
        #expect(TranscriptAssembly.continuesSentence("und"))
        #expect(!TranscriptAssembly.continuesSentence("Danke."))
    }

    @Test func interruptionsWithinOneTurnStay() {
        // Someone stops mid-sentence and another person takes over: no short turn, nothing moves.
        let all = [
            TimedWord(text: "Gut.", start: 0, end: 0.4), TimedWord(text: "Ich", start: 0.4, end: 0.6),
            TimedWord(text: "glaube", start: 0.6, end: 0.9), TimedWord(text: "Nein,", start: 1.0, end: 1.4),
            TimedWord(text: "warte.", start: 1.4, end: 1.8),
        ]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 0.95), SpeakerTurn(speaker: "B", start: 0.95, end: 2)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "A", "A", "B", "B"])
    }

    @Test func sentenceEndGivenToAnotherVoiceComesBack() {
        // "Ich kann bei den Tests unterstützen, | wenn Thomas mir die Testfälle schickt." — one sentence,
        // the second half a separate short turn of another voice.
        let all = [
            TimedWord(text: "Ich", start: 19.8, end: 20.2), TimedWord(text: "kann", start: 20.2, end: 20.5),
            TimedWord(text: "unterstützen,", start: 20.5, end: 22.2), TimedWord(text: "wenn", start: 22.2, end: 22.5),
            TimedWord(text: "Thomas", start: 22.5, end: 23.0), TimedWord(text: "schickt.", start: 23.0, end: 25.1),
            TimedWord(text: "Hallo", start: 25.9, end: 26.3),
        ]
        let turns = [
            SpeakerTurn(speaker: "J", start: 20.15, end: 22.0),
            SpeakerTurn(speaker: "T", start: 22.0, end: 25.2),
            SpeakerTurn(speaker: "P", start: 25.89, end: 32.2),
        ]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["J", "J", "J", "J", "J", "J", "P"])
    }

    @Test func pauseBreaksStartAtTheRightWord() {
        let all = [
            TimedWord(text: "Formular.", start: 61.36, end: 62.48), TimedWord(text: "Ich", start: 62.48, end: 62.9),
            TimedWord(text: "auch.", start: 62.9, end: 63.4),
        ]
        let turns = [SpeakerTurn(speaker: "A", start: 55, end: 62.22), SpeakerTurn(speaker: "A", start: 63.7, end: 64.5)]
        #expect(TranscriptAssembly.pauseBreaks(words: all, turns: turns) == [1])
        // A word that began in the silence, before the diarizer noticed the new turn, opens the new line.
        let late = [TimedWord(text: "Ende.", start: 68, end: 69.7), TimedWord(text: "Ich", start: 75.6, end: 75.92), TimedWord(text: "würde", start: 75.92, end: 76.3)]
        let lateTurns = [SpeakerTurn(speaker: "A", start: 64, end: 69.71), SpeakerTurn(speaker: "J", start: 75.93, end: 82)]
        #expect(TranscriptAssembly.pauseBreaks(words: late, turns: lateTurns) == [1])
    }

    @Test func changesAtSentenceEndsStay() {
        let all = [
            TimedWord(text: "Gut.", start: 0, end: 0.4), TimedWord(text: "Danke.", start: 1.2, end: 1.6),
            TimedWord(text: "Bitte.", start: 2.0, end: 2.4),
        ]
        let turns = [SpeakerTurn(speaker: "A", start: 0, end: 1.7), SpeakerTurn(speaker: "B", start: 1.9, end: 3)]
        #expect(TranscriptAssembly.speakers(for: all, turns: turns) == ["A", "A", "B"])
    }

    @Test func noTurnsMeansOneSpeaker() {
        #expect(TranscriptAssembly.speakers(for: words("a b", start: 0), turns: []) == ["S1", "S1"])
    }

    @Test func linesBreakAtSpeakerChangesAndLongPauses() {
        let all = words("Das ist gut.", start: 0) + words("Finde ich auch.", start: 1.4) + words("Weiter geht's.", start: 6)
        let speakers = ["A", "A", "A", "B", "B", "B", "B", "B"]
        let lines = TranscriptAssembly.lines(words: all, speakers: speakers, channel: .system)
        #expect(lines.map(\.text) == ["Das ist gut.", "Finde ich auch.", "Weiter geht's."])
        #expect(lines.map(\.speakerKey) == ["A", "B", "B"])
    }

    @Test func joinKeepsPunctuationAttached() {
        let joined = TranscriptAssembly.join([
            TimedWord(text: "Hallo", start: 0, end: 0.2), TimedWord(text: ",", start: 0.2, end: 0.3),
            TimedWord(text: "Welt", start: 0.3, end: 0.5), TimedWord(text: "!", start: 0.5, end: 0.6),
        ])
        #expect(joined == "Hallo, Welt!")
    }

    @Test func echoesOfTheCallAreDropped() {
        let system = [DraftLine(speakerKey: "S1", channel: .system, start: 10, end: 13, words: words("Wir verschieben das Release auf Oktober", start: 10, step: 0.5))]
        let echo = DraftLine(speakerKey: "me", channel: .microphone, start: 10.2, end: 13.2, words: words("wir verschieben das Release auf Oktober", start: 10.2, step: 0.5))
        let mine = DraftLine(speakerKey: "me", channel: .microphone, start: 20, end: 22, words: words("Einverstanden, machen wir so", start: 20))
        let kept = TranscriptAssembly.removeEchoes(microphone: [echo, mine], system: system)
        #expect(kept == [mine])
    }

    @Test func ownWordsDuringTheCallStay() {
        let system = [DraftLine(speakerKey: "S1", channel: .system, start: 10, end: 13, words: words("Was meinst du dazu", start: 10))]
        let mine = DraftLine(speakerKey: "me", channel: .microphone, start: 11, end: 13, words: words("Ich finde das gut", start: 11))
        #expect(TranscriptAssembly.removeEchoes(microphone: [mine], system: system) == [mine])
    }

    @Test func renumberingFollowsFirstAppearance() {
        let lines = [
            DraftLine(speakerKey: "speaker_7", channel: .system, start: 0, end: 1, words: words("a", start: 0)),
            DraftLine(speakerKey: "speaker_2", channel: .system, start: 1, end: 2, words: words("b", start: 1)),
            DraftLine(speakerKey: "speaker_7", channel: .system, start: 2, end: 3, words: words("c", start: 2)),
        ]
        let (renumbered, mapping) = TranscriptAssembly.renumbered(lines)
        #expect(renumbered.map(\.speakerKey) == ["S1", "S2", "S1"])
        #expect(mapping == ["speaker_7": "S1", "speaker_2": "S2"])
    }

    @Test func mergeSortsByTime() {
        let a = [DraftLine(speakerKey: "S1", channel: .system, start: 5, end: 6, words: words("später", start: 5))]
        let b = [DraftLine(speakerKey: "me", channel: .microphone, start: 1, end: 2, words: words("früher", start: 1))]
        #expect(TranscriptAssembly.merged(a, b).map(\.text) == ["früher", "später"])
    }
}

@Suite struct CallDetectorTests {
    @Test @MainActor func callStartsAfterTheDelayAndEndsAfterQuiet() {
        let detector = CallDetector()
        var started: [String] = []
        var ended: [String] = []
        detector.onCallStarted = { started.append($0.appName) }
        detector.onCallEnded = { ended.append($0.appName) }
        let zoom = DetectedCall(bundleID: "us.zoom.xos", appName: "Zoom")
        let t0 = Date()
        detector.update(with: zoom, now: t0)
        #expect(detector.activeCall == nil)
        detector.update(with: zoom, now: t0.addingTimeInterval(5))
        #expect(started == ["Zoom"])
        detector.update(with: nil, now: t0.addingTimeInterval(10))
        detector.update(with: nil, now: t0.addingTimeInterval(20))
        #expect(ended.isEmpty)
        detector.update(with: nil, now: t0.addingTimeInterval(31))
        #expect(ended == ["Zoom"])
        #expect(detector.activeCall == nil)
    }

    @Test @MainActor func aBriefMicrophoneUseIsNoCall() {
        let detector = CallDetector()
        var started = 0
        detector.onCallStarted = { _ in started += 1 }
        let t0 = Date()
        detector.update(with: DetectedCall(bundleID: "com.google.Chrome.helper", appName: "Google Chrome"), now: t0)
        detector.update(with: nil, now: t0.addingTimeInterval(2))
        detector.update(with: DetectedCall(bundleID: "com.google.Chrome.helper", appName: "Google Chrome"), now: t0.addingTimeInterval(3))
        #expect(started == 0)
    }

    @Test func knownAppsAreRecognised() {
        #expect(CallDetector.callApp(for: "us.zoom.xos") == "Zoom")
        #expect(CallDetector.callApp(for: "com.microsoft.teams2") == "Microsoft Teams")
        #expect(CallDetector.callApp(for: "com.google.Chrome.helper") == "Google Chrome")
        #expect(CallDetector.callApp(for: "com.apple.Music") == nil)
    }
}

@Suite struct MeetingLinkTests {
    @Test func findsTheCallLinkAndTheApp() throws {
        let zoom = try #require(MeetingLinks.find(in: ["Join: https://us02web.zoom.us/j/8123456789?pwd=abc>"]))
        #expect(zoom.app == "Zoom")
        #expect(zoom.url.absoluteString == "https://us02web.zoom.us/j/8123456789?pwd=abc")
        #expect(MeetingLinks.find(in: ["https://meet.google.com/abc-defg-hij"])?.app == "Google Meet")
        #expect(MeetingLinks.find(in: ["<https://teams.microsoft.com/l/meetup-join/19%3ameeting>"])?.app == "Microsoft Teams")
        #expect(MeetingLinks.find(in: ["Raum 3.12, bitte pünktlich"]) == nil)
    }
}

@Suite struct FormattingTests {
    @Test func clockAndDuration() {
        #expect(TimeFormat.clock(0) == "00:00")
        #expect(TimeFormat.clock(754) == "12:34")
        #expect(TimeFormat.clock(3_754) == "1:02:34")
        #expect(TimeFormat.duration(38) == "38 s")
        #expect(TimeFormat.duration(42 * 60) == "42 min")
        #expect(TimeFormat.duration(72 * 60) == "1 h 12 min")
        #expect(TimeFormat.duration(120 * 60) == "2 h")
    }

    @Test func dayTitles() {
        let now = Date()
        #expect(TimeFormat.dayTitle(now, now: now) == "Heute")
        #expect(TimeFormat.dayTitle(now.addingTimeInterval(-86_400), now: now) == "Gestern")
        #expect(TimeFormat.compactDay(now, now: now) == "Heute")
    }
}
