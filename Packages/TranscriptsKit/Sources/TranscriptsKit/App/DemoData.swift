import Foundation

/// Sample meetings and people for the demo mode (`-demo YES`), used for screenshots and trying the app out.
enum DemoData {
    static func seed(_ database: AppDatabase) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today)!
        }

        let me = Person(id: "p-me", name: "Lukas Kaibel", isMe: true)
        let anna = Person(id: "p-anna", name: "Anna Berger", email: "anna@example.com")
        let thomas = Person(id: "p-thomas", name: "Thomas Klein", email: "thomas@example.com")
        let miriam = Person(id: "p-miriam", name: "Miriam Okafor", email: "miriam@example.com")
        let jonas = Person(id: "p-jonas", name: "Jonas Weber", email: "jonas@example.com")
        let sarah = Person(id: "p-sarah", name: "Sarah Nguyen")
        let daniel = Person(id: "p-daniel", name: "Daniel Hoffmann")
        let people = [me, anna, thomas, miriam, jonas, sarah, daniel]
        let voices: [String: [Float]] = Dictionary(uniqueKeysWithValues: people.map { ($0.id, randomVoice()) })

        try? database.writer.write { db in
            for person in people { try person.insert(db) }
            for (person, count) in [(me, 3), (anna, 6), (thomas, 5), (miriam, 4), (jonas, 2), (sarah, 1), (daniel, 1)] {
                for index in 0..<count {
                    try Voiceprint(personId: person.id, embedding: jitter(voices[person.id]!, 0.05).embeddingData, meetingId: nil, duration: 60 + Double(index) * 30).insert(db)
                }
            }
        }

        // The meeting from the mockups, fully processed.
        let sync = Meeting(id: "m-sync", title: "Weekly Produkt-Sync", startedAt: at(0, 10), duration: 42 * 60, status: .ready, source: "Zoom", language: "de",
                           attendees: [Attendee(name: "Anna Berger", email: "anna@example.com"), Attendee(name: "Thomas Klein", email: "thomas@example.com"), Attendee(name: "Miriam Okafor", email: "miriam@example.com"), Attendee(name: "Jonas Weber", email: "jonas@example.com")],
                           progress: 1, transcriptionModel: "Parakeet Ultra")
        let syncLines: [(String, Double, Double, String)] = [
            ("S1", 0, 14, "Okay, dann fangen wir an. Drei Themen heute: Release 2.4, der Onboarding-Bug und die offene Backend-Stelle."),
            ("S2", 16, 28, "Zum Release: Wir sind feature-complete, aber der PDF-Export hängt noch bei langen Dokumenten."),
            ("me", 161, 178, "Ich hab mir das am Freitag angeschaut. Es liegt am Rendering der Tabellen, nicht am Export selbst. Ich schätze zwei Tage."),
            ("S1", 185, 191, "Dann verschieben wir auf den 14.? Thomas, passt das für dich?"),
            ("S2", 192, 199, "Ja, der 14. ist realistisch. Dann bleibt noch Puffer für QA."),
            ("S3", 860, 880, "Zum Onboarding: Fast jeder Dritte bricht im zweiten Schritt ab. Das Formular ist einfach zu lang."),
            ("S4", 892, 905, "Wir könnten die Firmendaten optional machen und erst später abfragen."),
            ("S3", 907, 914, "Gute Idee, Jonas. Ich mach bis Mittwoch einen Entwurf dafür."),
            ("S1", 1904, 1920, "Letzter Punkt: die Backend-Stelle. Wir haben drei Kandidaten in der finalen Runde."),
            ("me", 1930, 1938, "Ich kann die technischen Interviews diese Woche übernehmen."),
            ("S1", 1941, 1950, "Super, danke. Dann sind wir durch. Bis nächste Woche!"),
            // Jonas, whom the diarizer heard as Anna for a while.
            ("S1", 1240, 1253, "Kurz noch zum Backend: Die Migration der Sync-Engine braucht noch eine Woche."),
            ("S1", 1260, 1271, "Ich würde die alten Endpunkte bis Ende des Monats parallel laufen lassen."),
            // Someone the app isn't sure about: Thomas or Daniel.
            ("S5", 1500, 1512, "Von Kundenseite kam noch die Frage, ob der Export auch als Excel geht."),
            ("S5", 1530, 1539, "Ich kläre das bis Freitag mit dem Vertrieb."),
        ]
        let jonasInAnna: Set<Int> = [11, 12]
        let syncSpeakers = [
            MeetingSpeaker(meetingId: sync.id, key: "me", label: Strings.me, personId: me.id, assignment: .confirmed, confidence: 1, talkTime: 610, channel: .microphone),
            MeetingSpeaker(meetingId: sync.id, key: "S1", label: Strings.speakerLabel(1), personId: anna.id, assignment: .automatic, confidence: 0.86, talkTime: 790, embedding: jitter(voices[anna.id]!, 0.1).embeddingData, sampleStart: 0, sampleEnd: 12, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S2", label: Strings.speakerLabel(2), personId: thomas.id, assignment: .automatic, confidence: 0.81, talkTime: 530, embedding: jitter(voices[thomas.id]!, 0.1).embeddingData, sampleStart: 16, sampleEnd: 28, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S3", label: Strings.speakerLabel(3), personId: miriam.id, assignment: .confirmed, confidence: 1, talkTime: 400, embedding: jitter(voices[miriam.id]!, 0.1).embeddingData, sampleStart: 860, sampleEnd: 872, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S4", label: Strings.speakerLabel(4), assignment: .suggested, suggestedPersonId: jonas.id, suggestionReason: "Miriam: „Gute Idee, Jonas.“ · Stimme ähnlich wie in 2 früheren Meetings", confidence: 0.64, talkTime: 190, embedding: jitter(voices[jonas.id]!, 0.2).embeddingData, sampleStart: 892, sampleEnd: 905, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S5", label: Strings.speakerLabel(5), talkTime: 21, sampleStart: 1500, sampleEnd: 1512, channel: .system, candidatePersonIds: [thomas.id, daniel.id]),
        ]
        insert(sync, lines: syncLines, speakers: syncSpeakers, into: database) { index, key in
            if jonasInAnna.contains(index) { return voices[jonas.id] }
            if index >= 13 { return nil }
            return syncSpeakers.first { $0.key == key }?.personId.flatMap { voices[$0] } ?? voices[jonas.id]
        }
        try? database.save(
            summary: MeetingSummary(
                meetingId: sync.id,
                overview: "Release 2.4 wird auf den 14. Oktober verschoben, damit der PDF-Export bei langen Dokumenten vorher behoben ist. Fürs Onboarding entsteht ein kürzeres Formular. Lukas übernimmt diese Woche die technischen Interviews.",
                decisions: ["Release 2.4 am 14. statt am 9. Oktober", "Firmendaten im Onboarding werden optional"],
                openQuestions: ["Wer informiert die Kunden über die Verschiebung?"],
                model: "Claude Opus 5.5",
                provider: "Anthropic"
            ),
            actionItems: [
                ActionItem(meetingId: sync.id, text: "Tabellen-Rendering im PDF-Export beheben", owner: "Lukas", due: "Mi"),
                ActionItem(meetingId: sync.id, text: "Entwurf für ein kürzeres Onboarding-Formular", owner: "Miriam", due: "Mi"),
                ActionItem(meetingId: sync.id, text: "Technische Interviews mit drei Kandidaten", owner: "Lukas", due: "Fr"),
                ActionItem(meetingId: sync.id, text: "QA-Plan für Release 2.4", owner: "Thomas", due: "Do"),
            ]
        )
        _ = try? database.addMarker(Marker(meetingId: sync.id, time: 1205, text: "Budget für Testgeräte klären"))

        // More meetings for the list.
        let others: [(String, String, Date, Double, [MeetingSpeaker.Assignment], [Person?], Bool)] = [
            ("m-stadtwerke", "Kundencall Stadtwerke Nord", at(-3, 15, 30), 55 * 60, [.confirmed, .unknown], [sarah, nil], true),
            ("m-11", "1:1 Anna", at(-3, 11), 28 * 60, [.automatic], [anna], true),
            ("m-arch", "Architektur-Review Sync-Engine", at(-4, 16), 72 * 60, [.automatic, .automatic, .automatic, .automatic], [thomas, jonas, anna, miriam], true),
            ("m-interview", "Interview Backend-Entwicklung", at(-4, 13), 47 * 60, [.automatic, .confirmed], [thomas, nil], false),
            ("m-design", "Design-Review Onboarding", at(-5, 10, 30), 35 * 60, [.automatic, .automatic, .automatic], [miriam, anna, jonas], true),
            ("m-review", "Sprint Review 42", at(-5, 9), 58 * 60, [.automatic, .automatic, .automatic, .automatic], [anna, thomas, jonas, miriam], true),
            ("m-hoffmann", "Kundencall Hoffmann", at(-6, 15), 31 * 60, [.automatic], [daniel], true),
            ("m-retro", "Retro Sprint 42", at(-6, 11), 45 * 60, [.automatic, .automatic, .automatic], [anna, thomas, miriam], true),
        ]
        for (id, title, start, duration, assignments, persons, summarized) in others {
            let meeting = Meeting(id: id, title: title, startedAt: start, duration: duration, status: .ready, source: "Zoom", language: "de", progress: 1, transcriptionModel: "Parakeet Ultra")
            var speakers = [MeetingSpeaker(meetingId: id, key: "me", label: Strings.me, personId: me.id, assignment: .confirmed, confidence: 1, talkTime: duration * 0.25, channel: .microphone)]
            var lines: [(String, Double, Double, String)] = [("me", 4, 10, "Hallo zusammen, schön dass es geklappt hat.")]
            var lineVoices: [String: [Float]] = ["me": voices[me.id]!]
            for (index, assignment) in assignments.enumerated() {
                let key = "S\(index + 1)"
                let person = persons[index]
                lineVoices[key] = person.map { voices[$0.id]! } ?? randomVoice()
                speakers.append(MeetingSpeaker(
                    meetingId: id, key: key, label: Strings.speakerLabel(index + 1), personId: person?.id, assignment: assignment,
                    confidence: person == nil ? 0 : 0.8, talkTime: duration * 0.6 / Double(assignments.count),
                    embedding: (person.map { jitter(voices[$0.id]!, 0.1) } ?? randomVoice()).embeddingData,
                    sampleStart: 12 + Double(index) * 20, sampleEnd: 22 + Double(index) * 20, channel: .system
                ))
                lines.append((key, 12 + Double(index) * 20, 22 + Double(index) * 20, "Von meiner Seite gibt es ein kurzes Update zu den offenen Punkten aus der letzten Runde."))
                for round in 0..<5 {
                    let start = 300 + Double(round) * 240 + Double(index) * 50
                    lines.append((key, start, start + 9 + Double((index + round) % 4), Self.filler[(index + round) % Self.filler.count]))
                }
            }
            // Sarah's colleague, whom the diarizer put in with her and who was confirmed as Sarah along with her.
            var colleagueLines: Set<Double> = []
            var noiseLines: Set<Double> = []
            if id == "m-stadtwerke" {
                for round in 0..<5 {
                    let start = 1800 + Double(round) * 60
                    lines.append(("S1", start, start + 10, Self.filler[(round + 2) % Self.filler.count]))
                    colleagueLines.insert(start)
                }
                // Short bits that fit nobody: crosstalk, a cough, "ja, genau".
                for round in 0..<8 {
                    let start = 2200 + Double(round) * 20
                    lines.append(("S1", start, start + 2.5 + Double(round % 3), ["Ja, genau.", "Mhm.", "Okay, ja.", "Moment."][round % 4]))
                    noiseLines.insert(start)
                }
            }
            lines.sort { $0.1 < $1.1 }
            let sorted = lines
            let colleague = randomVoice()
            insert(meeting, lines: lines, speakers: speakers, into: database) { index, key in
                if noiseLines.contains(sorted[index].1) { return randomVoice() }
                return colleagueLines.contains(sorted[index].1) ? colleague : lineVoices[key]
            }
            if summarized {
                try? database.save(
                    summary: MeetingSummary(meetingId: id, overview: "Kurzer Abgleich zu den offenen Punkten; alle Themen sind geklärt.", decisions: [], openQuestions: [], model: "Claude Opus 5.5", provider: "Anthropic"),
                    actionItems: []
                )
            }
        }
    }

    static let filler = [
        "Das sehe ich ähnlich, wir sollten das aber noch mit dem Team abstimmen.",
        "Bei uns ist der Stand unverändert, die Tickets sind alle in Arbeit.",
        "Können wir das nächste Woche noch einmal aufgreifen? Bis dahin habe ich die Zahlen.",
        "Ich schicke euch nachher die Zusammenfassung und die Links zu den Entwürfen.",
    ]

    /// Saves a meeting with its lines; each line gets a voice embedding close to `voice(index, key)`, the
    /// way a real line of that voice would be.
    private static func insert(_ meeting: Meeting, lines: [(String, Double, Double, String)], speakers: [MeetingSpeaker], into database: AppDatabase, voice: (Int, String) -> [Float]?) {
        try? database.save(meeting)
        let segments = lines.enumerated().map { index, line in
            let (key, start, end, text) = line
            return Segment(
                meetingId: meeting.id, speakerKey: key, channel: key == "me" ? .microphone : .system, start: start, end: end, text: text,
                embedding: voice(index, key).map { lineOf($0).embeddingData }
            )
        }
        try? database.replaceTranscript(meetingId: meeting.id, segments: segments, speakers: speakers)
    }

    /// One line of a voice: about as alike to it as real lines are (0.85).
    private static func lineOf(_ voice: [Float]) -> [Float] {
        let noise = randomVoice()
        return VoiceMath.normalized(zip(voice, noise).map { $0 * 0.85 + $1 * 0.53 })
    }

    private static func randomVoice() -> [Float] {
        VoiceMath.normalized((0..<256).map { _ in Float.random(in: -1...1) })
    }

    private static func jitter(_ voice: [Float], _ amount: Float) -> [Float] {
        VoiceMath.normalized(voice.map { $0 + Float.random(in: -amount...amount) })
    }

    static func upcoming() -> [UpcomingMeeting] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let planning = calendar.date(byAdding: .hour, value: 14, to: today)!
        let hoffmann = calendar.date(byAdding: DateComponents(day: 1, hour: 9, minute: 30), to: today)!
        return [
            UpcomingMeeting(eventId: "e-planning", title: "Sprint Planning 43", start: planning, end: planning.addingTimeInterval(3600),
                            attendees: [Attendee(name: "Anna Berger"), Attendee(name: "Thomas Klein"), Attendee(name: "Jonas Weber"), Attendee(name: "Miriam Okafor")],
                            joinURL: URL(string: "https://zoom.us/j/123456789"), app: "Zoom"),
            UpcomingMeeting(eventId: "e-hoffmann", title: "Kundencall Hoffmann", start: hoffmann, end: hoffmann.addingTimeInterval(1800),
                            attendees: [Attendee(name: "Daniel Hoffmann")], joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/demo"), app: "Microsoft Teams"),
        ]
    }
}

extension AppModel {
    /// Fills the parts of the state that normally come from the system.
    func loadDemoState() {
        upcoming = DemoData.upcoming()
        engineState = .ready
        providerStatus = [.anthropic: .connected, .ollama: .connected]
        providerModels = [
            .anthropic: [LLMModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"), LLMModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"), LLMModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5")],
            .ollama: [LLMModel(id: "qwen3.8:27b-mlx", name: "qwen3.8:27b-mlx")],
        ]
        microphoneAllowed = true
        calendarAllowed = true
        notificationsAllowed = true
        persistentAlerts = true
    }
}
