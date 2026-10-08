import Foundation

/// Sample meetings and people for the demo mode (`-demo YES`), used for screenshots and trying the app out. The
/// meetings are held in German when the interface is German, and in English otherwise.
enum DemoData {
    static func seed(_ database: AppDatabase) {
        let t = AppLanguage.current == .german ? Texts.german : Texts.english
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
        let sync = Meeting(id: "m-sync", title: t.syncTitle, startedAt: at(0, 10), duration: 42 * 60, status: .ready, source: "Zoom", language: t.language, calendarEventId: "e-weekly-sync",
                           attendees: [Attendee(name: "Anna Berger", email: "anna@example.com"), Attendee(name: "Thomas Klein", email: "thomas@example.com"), Attendee(name: "Miriam Okafor", email: "miriam@example.com"), Attendee(name: "Jonas Weber", email: "jonas@example.com")],
                           progress: 1, transcriptionModel: "Parakeet Ultra")
        let syncLines = zip(Self.syncTiming, t.syncLines).map { ($0.0, $0.1, $0.2, $1) }
        let jonasInAnna: Set<Int> = [11, 12]
        let syncSpeakers = [
            MeetingSpeaker(meetingId: sync.id, key: "me", label: Strings.meLabel, personId: me.id, assignment: .confirmed, confidence: 1, talkTime: 610, channel: .microphone),
            MeetingSpeaker(meetingId: sync.id, key: "S1", label: Strings.speakerLabel(1), personId: anna.id, assignment: .automatic, confidence: 0.86, talkTime: 790, embedding: jitter(voices[anna.id]!, 0.1).embeddingData, sampleStart: 0, sampleEnd: 12, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S2", label: Strings.speakerLabel(2), personId: thomas.id, assignment: .automatic, confidence: 0.81, talkTime: 530, embedding: jitter(voices[thomas.id]!, 0.1).embeddingData, sampleStart: 16, sampleEnd: 28, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S3", label: Strings.speakerLabel(3), personId: miriam.id, assignment: .confirmed, confidence: 1, talkTime: 400, embedding: jitter(voices[miriam.id]!, 0.1).embeddingData, sampleStart: 860, sampleEnd: 872, channel: .system),
            MeetingSpeaker(meetingId: sync.id, key: "S4", label: Strings.speakerLabel(4), assignment: .suggested, suggestedPersonId: jonas.id, suggestionReason: "Miriam: „\(t.goodIdea)“ · \(SpeakerIdentifier.voiceReasonPrefix) 2 früheren Meetings", confidence: 0.64, talkTime: 190, embedding: jitter(voices[jonas.id]!, 0.2).embeddingData, sampleStart: 892, sampleEnd: 905, channel: .system),
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
                overview: t.overview,
                decisions: t.decisions,
                openQuestions: t.openQuestions,
                model: "Claude Opus 5.5",
                provider: "Anthropic"
            ),
            actionItems: zip(t.tasks, [("Lukas", 0), ("Miriam", 0), ("Lukas", 2), ("Thomas", 1)]).map { task, owner in
                ActionItem(meetingId: sync.id, text: task, owner: owner.0, due: t.days[owner.1])
            }
        )
        _ = try? database.addMarker(Marker(meetingId: sync.id, time: 1205, text: t.marker))

        // Where earlier meetings' tasks went on GitHub, so the app has something to suggest.
        let web = GitHubTarget(repository: DemoGitHubService.webApp, project: DemoGitHubService.webProject)
        let pdf = GitHubTarget(repository: DemoGitHubService.pdf, project: DemoGitHubService.webProject)
        let support = GitHubTarget(repoId: DemoGitHubService.support.id, repo: DemoGitHubService.support.nameWithOwner, isPrivate: true, projectId: "P-support", projectTitle: "Support")
        let group = [anna.id, miriam.id, thomas.id].sorted()
        try? database.writer.write { db in
            var routes = [
                GitHubRoute(kind: .series, key: "e-weekly-sync", label: t.syncTitle, target: web, count: 3, lastUsedAt: at(-7, 10, 45)),
                GitHubRoute(kind: .title, key: TargetSuggester.normalizedTitle(t.syncTitle), label: t.syncTitle, target: web, count: 3, lastUsedAt: at(-7, 10, 45)),
                GitHubRoute(kind: .people, key: group.joined(separator: ","), label: TargetSuggester.names([anna.name, thomas.name, miriam.name]), members: group, target: web, count: 4, lastUsedAt: at(-5, 9, 50)),
                GitHubRoute(kind: .people, key: [anna.id, thomas.id].sorted().joined(separator: ","), label: TargetSuggester.names([thomas.name, anna.name]), members: [anna.id, thomas.id].sorted(), target: pdf, count: 1, lastUsedAt: at(-8, 14)),
                GitHubRoute(kind: .title, key: TargetSuggester.normalizedTitle(t.titles[6]), label: t.titles[6], target: support, count: 2, lastUsedAt: at(-6, 15, 40)),
            ]
            for index in routes.indices { try routes[index].insert(db) }
        }

        // More meetings for the list.
        let others: [(String, String, Date, Double, [MeetingSpeaker.Assignment], [Person?], Bool)] = [
            ("m-stadtwerke", t.titles[0], at(-3, 15, 30), 55 * 60, [.confirmed, .unknown], [sarah, nil], true),
            ("m-11", t.titles[1], at(-3, 11), 28 * 60, [.automatic], [anna], true),
            ("m-arch", t.titles[2], at(-4, 16), 72 * 60, [.automatic, .automatic, .automatic, .automatic], [thomas, jonas, anna, miriam], true),
            ("m-interview", t.titles[3], at(-4, 13), 47 * 60, [.automatic, .confirmed], [thomas, nil], false),
            ("m-design", t.titles[4], at(-5, 10, 30), 35 * 60, [.automatic, .automatic, .automatic], [miriam, anna, jonas], true),
            ("m-review", t.titles[5], at(-5, 9), 58 * 60, [.automatic, .automatic, .automatic, .automatic], [anna, thomas, jonas, miriam], true),
            ("m-hoffmann", t.titles[6], at(-6, 15), 31 * 60, [.automatic], [daniel], true),
            ("m-retro", t.titles[7], at(-6, 11), 45 * 60, [.automatic, .automatic, .automatic], [anna, thomas, miriam], true),
        ]
        for (id, title, start, duration, assignments, persons, summarized) in others {
            let meeting = Meeting(id: id, title: title, startedAt: start, duration: duration, status: .ready, source: "Zoom", language: t.language, progress: 1, transcriptionModel: "Parakeet Ultra")
            var speakers = [MeetingSpeaker(meetingId: id, key: "me", label: Strings.meLabel, personId: me.id, assignment: .confirmed, confidence: 1, talkTime: duration * 0.25, channel: .microphone)]
            var lines: [(String, Double, Double, String)] = [("me", 4, 10, t.hello)]
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
                lines.append((key, 12 + Double(index) * 20, 22 + Double(index) * 20, t.update))
                for round in 0..<5 {
                    let start = 300 + Double(round) * 240 + Double(index) * 50
                    lines.append((key, start, start + 9 + Double((index + round) % 4), t.filler[(index + round) % t.filler.count]))
                }
            }
            // Sarah's colleague, whom the diarizer put in with her and who was confirmed as Sarah along with her.
            var colleagueLines: Set<Double> = []
            var noiseLines: Set<Double> = []
            if id == "m-stadtwerke" {
                for round in 0..<5 {
                    let start = 1800 + Double(round) * 60
                    lines.append(("S1", start, start + 10, t.filler[(round + 2) % t.filler.count]))
                    colleagueLines.insert(start)
                }
                // Short bits that fit nobody: crosstalk, a cough, "ja, genau".
                for round in 0..<8 {
                    let start = 2200 + Double(round) * 20
                    lines.append(("S1", start, start + 2.5 + Double(round % 3), t.noise[round % 4]))
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
                    summary: MeetingSummary(meetingId: id, overview: t.shortOverview, decisions: [], openQuestions: [], model: "Claude Opus 5.5", provider: "Anthropic"),
                    actionItems: []
                )
            }
        }
    }

    /// Who speaks when in the weekly sync.
    static let syncTiming: [(String, Double, Double)] = [
        ("S1", 0, 14), ("S2", 16, 28), ("me", 161, 178), ("S1", 185, 191), ("S2", 192, 199), ("S3", 860, 880), ("S4", 892, 905),
        ("S3", 907, 914), ("S1", 1904, 1920), ("me", 1930, 1938), ("S1", 1941, 1950),
        // Jonas, whom the diarizer heard as Anna for a while.
        ("S1", 1240, 1253), ("S1", 1260, 1271),
        // Someone the app isn't sure about: Thomas or Daniel.
        ("S5", 1500, 1512), ("S5", 1530, 1539),
    ]

    /// What is said and written in the demo, in German and in English.
    struct Texts {
        var language: String
        var syncTitle: String
        var syncLines: [String]
        var goodIdea: String
        var overview: String
        var decisions: [String]
        var openQuestions: [String]
        var tasks: [String]
        /// Wednesday, Thursday, Friday, short.
        var days: [String]
        var marker: String
        var titles: [String]
        var hello: String
        var update: String
        var filler: [String]
        var noise: [String]
        var shortOverview: String
        var upcoming: [String]
        var calendars: [String]

        static let german = Texts(
            language: "de",
            syncTitle: "Weekly Produkt-Sync",
            syncLines: [
                "Okay, dann fangen wir an. Drei Themen heute: Release 2.4, der Onboarding-Bug und die offene Backend-Stelle.",
                "Zum Release: Wir sind feature-complete, aber der PDF-Export hängt noch bei langen Dokumenten.",
                "Ich hab mir das am Freitag angeschaut. Es liegt am Rendering der Tabellen, nicht am Export selbst. Ich schätze zwei Tage.",
                "Dann verschieben wir auf den 14.? Thomas, passt das für dich?",
                "Ja, der 14. ist realistisch. Dann bleibt noch Puffer für QA.",
                "Zum Onboarding: Fast jeder Dritte bricht im zweiten Schritt ab. Das Formular ist einfach zu lang.",
                "Wir könnten die Firmendaten optional machen und erst später abfragen.",
                "Gute Idee, Jonas. Ich mach bis Mittwoch einen Entwurf dafür.",
                "Letzter Punkt: die Backend-Stelle. Wir haben drei Kandidaten in der finalen Runde.",
                "Ich kann die technischen Interviews diese Woche übernehmen.",
                "Super, danke. Dann sind wir durch. Bis nächste Woche!",
                "Kurz noch zum Backend: Die Migration der Sync-Engine braucht noch eine Woche.",
                "Ich würde die alten Endpunkte bis Ende des Monats parallel laufen lassen.",
                "Von Kundenseite kam noch die Frage, ob der Export auch als Excel geht.",
                "Ich kläre das bis Freitag mit dem Vertrieb.",
            ],
            goodIdea: "Gute Idee, Jonas.",
            overview: "Release 2.4 wird auf den 14. Oktober verschoben, damit der PDF-Export bei langen Dokumenten vorher behoben ist. Fürs Onboarding entsteht ein kürzeres Formular. Lukas übernimmt diese Woche die technischen Interviews.",
            decisions: ["Release 2.4 am 14. statt am 9. Oktober", "Firmendaten im Onboarding werden optional"],
            openQuestions: ["Wer informiert die Kunden über die Verschiebung?"],
            tasks: ["Tabellen-Rendering im PDF-Export beheben", "Entwurf für ein kürzeres Onboarding-Formular", "Technische Interviews mit drei Kandidaten", "QA-Plan für Release 2.4"],
            days: ["Mi", "Do", "Fr"],
            marker: "Budget für Testgeräte klären",
            titles: ["Kundencall Stadtwerke Nord", "1:1 Anna", "Architektur-Review Sync-Engine", "Interview Backend-Entwicklung", "Design-Review Onboarding", "Sprint Review 42", "Kundencall Hoffmann", "Retro Sprint 42"],
            hello: "Hallo zusammen, schön dass es geklappt hat.",
            update: "Von meiner Seite gibt es ein kurzes Update zu den offenen Punkten aus der letzten Runde.",
            filler: [
                "Das sehe ich ähnlich, wir sollten das aber noch mit dem Team abstimmen.",
                "Bei uns ist der Stand unverändert, die Tickets sind alle in Arbeit.",
                "Können wir das nächste Woche noch einmal aufgreifen? Bis dahin habe ich die Zahlen.",
                "Ich schicke euch nachher die Zusammenfassung und die Links zu den Entwürfen.",
            ],
            noise: ["Ja, genau.", "Mhm.", "Okay, ja.", "Moment."],
            shortOverview: "Kurzer Abgleich zu den offenen Punkten; alle Themen sind geklärt.",
            upcoming: ["Sprint Planning 43", "Kundencall Hoffmann"],
            calendars: ["Arbeit", "Vertrieb"]
        )

        static let english = Texts(
            language: "en",
            syncTitle: "Weekly Product Sync",
            syncLines: [
                "Okay, let's get started. Three topics today: release 2.4, the onboarding bug and the open backend role.",
                "On the release: we're feature-complete, but the PDF export still hangs on long documents.",
                "I looked into it on Friday. It's the table rendering, not the export itself. I'd say two days.",
                "So we move it to the 14th? Thomas, does that work for you?",
                "Yes, the 14th is realistic. That still leaves some buffer for QA.",
                "On onboarding: almost one in three people drop off at the second step. The form is simply too long.",
                "We could make the company details optional and ask for them later.",
                "Good idea, Jonas. I'll have a draft ready by Wednesday.",
                "Last point: the backend role. We have three candidates in the final round.",
                "I can take the technical interviews this week.",
                "Great, thanks. That's everything. See you next week!",
                "One more thing on the backend: migrating the sync engine needs another week.",
                "I'd keep the old endpoints running in parallel until the end of the month.",
                "The customer also asked whether the export works with Excel.",
                "I'll check with sales by Friday.",
            ],
            goodIdea: "Good idea, Jonas.",
            overview: "Release 2.4 moves to October 14 so the PDF export can be fixed for long documents first. Onboarding gets a shorter form. Lukas takes the technical interviews this week.",
            decisions: ["Release 2.4 on October 14 instead of October 9", "Company details become optional in onboarding"],
            openQuestions: ["Who tells the customers about the delay?"],
            tasks: ["Fix table rendering in the PDF export", "Draft a shorter onboarding form", "Technical interviews with three candidates", "QA plan for release 2.4"],
            days: ["Wed", "Thu", "Fri"],
            marker: "Sort out the budget for test devices",
            titles: ["Customer call Northside Utilities", "1:1 Anna", "Architecture review: sync engine", "Interview: backend developer", "Design review: onboarding", "Sprint Review 42", "Customer call Hoffmann", "Retro Sprint 42"],
            hello: "Hi everyone, glad we could make it work.",
            update: "A quick update from my side on the open points from last time.",
            filler: [
                "I see it the same way, but we should check with the team first.",
                "Nothing new on our side, the tickets are all in progress.",
                "Can we come back to this next week? I'll have the numbers by then.",
                "I'll send you the summary and the links to the drafts afterwards.",
            ],
            noise: ["Yes, exactly.", "Mhm.", "Okay, yes.", "One moment."],
            shortOverview: "A short check-in on the open points; everything is settled.",
            upcoming: ["Sprint Planning 43", "Customer call Hoffmann"],
            calendars: ["Work", "Sales"]
        )
    }

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
        let t = AppLanguage.current == .german ? Texts.german : Texts.english
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let planning = calendar.date(byAdding: .hour, value: 14, to: today)!
        let hoffmann = calendar.date(byAdding: DateComponents(day: 1, hour: 9, minute: 30), to: today)!
        return [
            UpcomingMeeting(eventId: "e-planning", title: t.upcoming[0], start: planning, end: planning.addingTimeInterval(3600),
                            attendees: [Attendee(name: "Anna Berger"), Attendee(name: "Thomas Klein"), Attendee(name: "Jonas Weber"), Attendee(name: "Miriam Okafor")],
                            joinURL: URL(string: "https://zoom.us/j/123456789"), app: "Zoom",
                            calendarId: "c-work", calendarTitle: t.calendars[0], calendarColor: [0.20, 0.47, 0.96], isRecurring: true),
            UpcomingMeeting(eventId: "e-hoffmann", title: t.upcoming[1], start: hoffmann, end: hoffmann.addingTimeInterval(1800),
                            attendees: [Attendee(name: "Daniel Hoffmann")], joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/demo"), app: "Microsoft Teams",
                            calendarId: "c-sales", calendarTitle: t.calendars[1], calendarColor: [0.96, 0.58, 0.16]),
        ]
    }
}

extension DemoData {
    /// What the language model would propose for the sample tasks (by their place in the weekly's list).
    static func issueSuggestions(for tasks: [ActionItem], labels: [GitHubLabel]) -> [IssueSuggestion] {
        let has = Set(labels.map(\.name))
        let german = AppLanguage.current == .german
        return tasks.enumerated().map { index, task in
            func pick(_ names: [String]) -> [String] { names.filter(has.contains) }
            switch task.position {
            case 0:
                return IssueSuggestion(index: index, labels: pick(["bug", "pdf-export"]),
                                       context: german ? "Beim Export langer Dokumente bricht das Tabellen-Rendering ab. Das muss vor Release 2.4 behoben sein, das deshalb auf den 14. Oktober verschoben wird." : "Table rendering breaks when long documents are exported. It has to be fixed before release 2.4, which moves to October 14 for it.",
                                       quote: german ? "Es liegt am Rendering der Tabellen, nicht am Export selbst." : "It's the table rendering, not the export itself.", quoteSpeaker: "Lukas Kaibel", quoteTime: "02:41")
            case 1:
                return IssueSuggestion(index: index, labels: pick(["enhancement", "onboarding"]),
                                       context: german ? "Fast jeder Dritte bricht das Onboarding im zweiten Schritt ab. Die Firmendaten werden optional und erst später abgefragt." : "Almost one in three people drop off at the second onboarding step. Company details become optional and are asked for later.",
                                       quote: german ? "Ich mach bis Mittwoch einen Entwurf dafür." : "I'll have a draft ready by Wednesday.", quoteSpeaker: "Miriam Okafor", quoteTime: "15:07")
            case 2:
                return IssueSuggestion(index: index, include: false, reason: german ? "Eher kein Repo-Thema" : "Not really repo work")
            case 3:
                return IssueSuggestion(index: index, labels: pick(["qa"]),
                                       context: german ? "Nach der Verschiebung auf den 14. Oktober bleibt Puffer für die Qualitätssicherung." : "Moving to October 14 leaves some buffer for QA.",
                                       quote: german ? "Dann bleibt noch Puffer für QA." : "That still leaves some buffer for QA.", quoteSpeaker: "Thomas Klein", quoteTime: "03:12")
            default:
                return IssueSuggestion(index: index)
            }
        }
    }
}

extension AppModel {
    /// Fills the parts of the state that normally come from the system.
    func loadDemoState() {
        upcoming = DemoData.upcoming().filter(meetingFilter.allows)
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
