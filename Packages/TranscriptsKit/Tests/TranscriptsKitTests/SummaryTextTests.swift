import Foundation
import Testing
@testable import TranscriptsKit

@Suite struct SummaryTextTests {
    let tasks = [
        ActionItem(meetingId: "m", text: "PDF-Export beheben", owner: "Lukas", due: "Mi"),
        ActionItem(meetingId: "m", text: "Kunden informieren", done: true, position: 1),
        ActionItem(meetingId: "m", text: "QA-Plan", owner: "Thomas", position: 2),
    ]

    @Test func aTaskCarriesItsOwnerAndDay() {
        #expect(SummaryText.task(tasks[0]) == "PDF-Export beheben (Lukas, Mi)")
        #expect(SummaryText.task(tasks[1]) == "Kunden informieren")
        #expect(SummaryText.task(tasks[2]) == "QA-Plan (Thomas)")
    }

    @Test func tasksBecomeAChecklist() {
        #expect(SummaryText.tasks(tasks) == """
            - [ ] PDF-Export beheben (Lukas, Mi)
            - [x] Kunden informieren
            - [ ] QA-Plan (Thomas)
            """)
    }

    @Test func topicsAsTextOrUnderHeadings() {
        let topics = [
            SummaryTopic(title: "Release 2.4", points: ["Verschoben auf den 14.", "Puffer für QA"]),
            SummaryTopic(title: "Onboarding", points: []),
        ]
        #expect(SummaryText.topics(topics) == """
            Release 2.4
            - Verschoben auf den 14.
            - Puffer für QA

            Onboarding
            """)
        #expect(SummaryText.topics(topics, level: 3) == """
            ### Release 2.4

            - Verschoben auf den 14.
            - Puffer für QA

            ### Onboarding
            """)
    }

    @Test func theWholeSummaryUnderTheMeetingsTitle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = MeetingDetail(
            meeting: Meeting(id: "m", title: "Weekly Produkt-Sync", startedAt: start, duration: 45 * 60, status: .ready),
            segments: [], speakers: [], people: [:],
            summary: MeetingSummary(meetingId: "m", overview: "Das Release wird verschoben.",
                                    topics: [SummaryTopic(title: "Release 2.4", points: ["Verschoben auf den 14."])],
                                    decisions: ["Release am 14. Oktober"], openQuestions: ["Wer informiert die Kunden?"], model: "x", provider: "y"),
            actionItems: Array(tasks.prefix(1)), markers: []
        )
        let date = TimeFormat.meetingLine(start: start, duration: 45 * 60)
        #expect(SummaryText.markdown(detail) == """
            # Weekly Produkt-Sync
            \(date)

            Das Release wird verschoben.

            ## \(String(localized: "Entscheidungen"))

            - Release am 14. Oktober

            ## \(String(localized: "Aufgaben"))

            - [ ] PDF-Export beheben (Lukas, Mi)

            ## \(String(localized: "Offene Fragen"))

            - Wer informiert die Kunden?

            ## \(String(localized: "Themen", comment: "the subjects a meeting went through, in its summary"))

            ### Release 2.4

            - Verschoben auf den 14.
            """)
    }

    @Test func noSummaryNoText() {
        let detail = MeetingDetail(meeting: Meeting(id: "m", title: "Weekly", status: .ready), segments: [], speakers: [], people: [:],
                                   summary: nil, actionItems: [], markers: [])
        #expect(SummaryText.markdown(detail).isEmpty)
    }
}
