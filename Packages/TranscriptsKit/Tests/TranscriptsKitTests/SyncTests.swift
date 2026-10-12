import CloudKit
import Foundation
import GRDB
import Testing
@testable import TranscriptsKit

@Suite struct SyncTests {
    /// A finished meeting: the user and Anna talking, with a summary, a task and a marker.
    func makeMeeting(_ database: AppDatabase, id: String = "m1", anna: Person) throws {
        let me = try database.mePerson(defaultName: "Lukas")
        try database.save(anna)
        try database.save(Meeting(id: id, title: "Weekly", status: .ready))
        try database.replaceTranscript(meetingId: id, segments: [
            Segment(meetingId: id, speakerKey: "me", channel: .microphone, start: 0, end: 4, text: "Hallo Anna", embedding: [Float](repeating: 0.5, count: 4).embeddingData),
            Segment(meetingId: id, speakerKey: "S1", channel: .microphone, start: 5, end: 9, text: "Hi Lukas"),
        ], speakers: [
            MeetingSpeaker(meetingId: id, key: "me", label: Strings.meLabel, personId: me.id, assignment: .confirmed, channel: .microphone),
            MeetingSpeaker(meetingId: id, key: "S1", label: "Sprecher 1", personId: anna.id, assignment: .confirmed, channel: .microphone, rejectedPersonIds: [me.id]),
        ])
        try database.save(summary: MeetingSummary(meetingId: id, overview: "Kurz", decisions: ["A"], openQuestions: [], model: "x", provider: "y"),
                          actionItems: [ActionItem(meetingId: id, text: "Angebot schicken", owner: "Anna")])
        _ = try database.addMarker(Marker(meetingId: id, time: 3, text: "Wichtig"))
    }

    func pending(_ database: AppDatabase) throws -> [String] {
        try database.syncPendingChanges().map { "\($0.recordType):\($0.recordName)\($0.deleted ? " deleted" : "")" }.sorted()
    }

    func clearPending(_ database: AppDatabase) throws {
        for change in try database.syncPendingChanges() { try database.syncClearPending(change.recordType, change.recordName) }
    }

    @Test func changesAreNoted() throws {
        let database = try AppDatabase.inMemory()
        let anna = Person(id: "anna", name: "Anna")
        try makeMeeting(database, anna: anna)
        let me = try database.mePerson(defaultName: "Lukas")
        #expect(try pending(database) == ["Meeting:m1", "Person:anna", "Person:\(me.id)"].sorted())

        try clearPending(database)
        try database.setActionItem(try #require(try database.detail(of: "m1")?.actionItems.first?.id), done: true)
        #expect(try pending(database) == ["Meeting:m1"])

        try clearPending(database)
        try database.save(Voiceprint(id: "v1", personId: "anna", embedding: Data([1, 2]), meetingId: "m1", duration: 4))
        #expect(try pending(database) == ["Voiceprint:v1"])

        try clearPending(database)
        try database.deleteMeeting("m1")
        #expect(try pending(database) == ["Meeting:m1 deleted", "MeetingAudio:m1 deleted", "Voiceprint:v1"])
    }

    @Test func aChangeAfterSendingStaysPending() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "anna", name: "Anna"))
        let sentAt = try #require(try database.syncPendingChangedAt(SyncRecordType.person, "anna"))
        Thread.sleep(forTimeInterval: 0.01)
        try database.save(Person(id: "anna", name: "Anna Berg"))
        try database.syncClearPending(SyncRecordType.person, "anna", upTo: sentAt)
        #expect(try pending(database) == ["Person:anna"])
        try database.syncClearPending(SyncRecordType.person, "anna")
        #expect(try pending(database).isEmpty)
    }

    @Test func meetingsGoUpOnceFinished() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Meeting(id: "live", title: "Läuft", status: .recording))
        guard case .notFinished = try database.syncMeetingPayload("live") else { Issue.record("a running recording went up"); return }
        guard case .gone = try database.syncMeetingPayload("nope") else { Issue.record("a missing meeting had a payload"); return }
        #expect(try database.syncFinishedMeetings().isEmpty)
    }

    @Test func aMeetingArrivesWithItsPeople() throws {
        let mac = try AppDatabase.inMemory()
        let anna = Person(id: "anna", name: "Anna")
        try makeMeeting(mac, anna: anna)
        guard case .ready(let payload) = try mac.syncMeetingPayload("m1") else { Issue.record("no payload"); return }
        // The user is "me" in iCloud, whatever their id on this device.
        #expect(payload.speakers.first { $0.key == "me" }?.personId == SyncNames.me)
        #expect(payload.speakers.first { $0.key == "S1" }?.rejectedPersonIds == [SyncNames.me])
        #expect(payload.people.map(\.name).sorted() == ["Anna", "Lukas"])

        let phone = try AppDatabase.inMemory()
        let phoneMe = try phone.mePerson(defaultName: "Lukas")
        try clearPending(phone)
        try phone.syncApply(meeting: try SyncCoding.decoder.decode(MeetingPayload.self, from: SyncCoding.encoder.encode(payload)))

        // Written without counting as a change of the phone.
        #expect(try pending(phone).isEmpty)
        let detail = try #require(try phone.detail(of: "m1"))
        #expect(detail.segments.map(\.text) == ["Hallo Anna", "Hi Lukas"])
        #expect(detail.segments.first?.embedding != nil)
        #expect(detail.speaker(for: "me")?.personId == phoneMe.id)
        #expect(detail.speaker(for: "S1")?.rejectedPersonIds == [phoneMe.id])
        #expect(detail.displayName(for: "S1") == "Anna")
        #expect(detail.summary?.overview == "Kurz")
        #expect(detail.actionItems.map(\.text) == ["Angebot schicken"])
        #expect(detail.markers.map(\.text) == ["Wichtig"])

        // The phone sends back exactly what it got, so nothing goes up for nothing.
        guard case .ready(let echo) = try phone.syncMeetingPayload("m1") else { Issue.record("no payload on the phone"); return }
        #expect(SyncCoding.digest(try SyncCoding.encoder.encode(echo)) == SyncCoding.digest(try SyncCoding.encoder.encode(payload)))
    }

    @Test func applyingAgainReplacesTheContent() throws {
        let mac = try AppDatabase.inMemory()
        try makeMeeting(mac, anna: Person(id: "anna", name: "Anna"))
        guard case .ready(var payload) = try mac.syncMeetingPayload("m1") else { Issue.record("no payload"); return }
        let phone = try AppDatabase.inMemory()
        try phone.syncApply(meeting: payload)
        payload.meeting.title = "Weekly Sync"
        payload.segments.removeLast()
        payload.markers = []
        try phone.syncApply(meeting: payload)
        let detail = try #require(try phone.detail(of: "m1"))
        #expect(detail.meeting.title == "Weekly Sync")
        #expect(detail.segments.count == 1)
        #expect(detail.markers.isEmpty)
    }

    @Test func twoDevicesThatMetTheSamePersonMakeOneOfThem() throws {
        let phone = try AppDatabase.inMemory()
        try makeMeeting(phone, anna: Person(id: "zz-anna", name: "Anna"))
        try clearPending(phone)
        // Anna as the Mac knows her, with another id.
        let payload = PersonPayload(name: "Anna", email: nil, isMe: false, createdAt: Date(), github: nil)
        let (local, twin) = try phone.syncApply(person: payload, recordName: "aa-anna")
        #expect(local == "aa-anna")
        #expect(twin == "zz-anna")
        try phone.syncMergeTwins(local, try #require(twin))
        // The smaller id stays, on every device the same.
        #expect(try phone.people().filter { !$0.isMe }.map(\.id) == ["aa-anna"])
        #expect(try phone.detail(of: "m1")?.speaker(for: "S1")?.personId == "aa-anna")
        // The merge goes up, so the Mac learns where Anna's voices went.
        #expect(try pending(phone).contains("Person:zz-anna deleted"))
        #expect(try pending(phone).contains("Meeting:m1"))
    }

    @Test func theUserIsTheUserOnEveryDevice() throws {
        let phone = try AppDatabase.inMemory()
        let me = try phone.mePerson(defaultName: "Ich")
        try clearPending(phone)
        let payload = PersonPayload(name: "Lukas Kaibel", email: "l@example.com", isMe: true, createdAt: Date(), github: nil)
        let (local, twin) = try phone.syncApply(person: payload, recordName: SyncNames.me)
        #expect(local == me.id)
        #expect(twin == nil)
        #expect(try phone.people().first { $0.isMe }?.name == "Lukas Kaibel")
        #expect(try phone.syncPersonName(me.id) == SyncNames.me)
        #expect(try pending(phone).isEmpty)
    }

    @Test func voicesArriveForTheirPerson() throws {
        let phone = try AppDatabase.inMemory()
        let payload = VoiceprintPayload(personId: "anna", personName: "Anna", embedding: Data([1, 2, 3]), meetingId: "elsewhere", duration: 12, createdAt: Date())
        try phone.syncApply(voiceprint: payload, recordName: "v1")
        let print = try #require(try phone.voiceprints().first)
        #expect(print.personId == "anna")
        // The meeting isn't on this device (yet): the sample stays without it.
        #expect(print.meetingId == nil)
        #expect(try phone.people().map(\.name) == ["Anna"])
        #expect(try pending(phone).isEmpty)
    }

    @Test func deletionsFromElsewhere() throws {
        let phone = try AppDatabase.inMemory()
        try makeMeeting(phone, anna: Person(id: "anna", name: "Anna"))
        try phone.save(Person(id: "anna-2", name: "Anna"))
        try clearPending(phone)
        // Anna was merged into her namesake on the other device.
        try phone.syncApplyDeletion(SyncRecordType.person, "anna")
        #expect(try phone.detail(of: "m1")?.speaker(for: "S1")?.personId == "anna-2")
        try phone.syncApplyDeletion(SyncRecordType.meeting, "m1")
        #expect(try phone.detail(of: "m1") == nil)
        #expect(try pending(phone).isEmpty)
    }

    @Test func theLaterChangeWins() throws {
        let database = try AppDatabase.inMemory()
        try database.save(Person(id: "anna", name: "Anna"))
        let changedAt = try #require(try database.syncPendingChangedAt(SyncRecordType.person, "anna"))
        #expect(try database.syncRemoteWins(SyncRecordType.person, "anna", remoteModifiedAt: changedAt + 10))
        #expect(try !database.syncRemoteWins(SyncRecordType.person, "anna", remoteModifiedAt: changedAt - 10))
        // Nothing changed here: iCloud wins.
        #expect(try database.syncRemoteWins(SyncRecordType.person, "ben", remoteModifiedAt: 0))
    }

    @Test func everythingGoesUpOnTheFirstSync() throws {
        let database = try AppDatabase.inMemory()
        try makeMeeting(database, anna: Person(id: "anna", name: "Anna"))
        try clearPending(database)
        try database.syncEnqueueEverything(includeAudio: true)
        let me = try database.mePerson(defaultName: "Lukas")
        #expect(try pending(database) == ["Meeting:m1", "Person:anna", "Person:\(me.id)"].sorted())
    }

    @Test func bookkeepingSurvivesAndResets() throws {
        let database = try AppDatabase.inMemory()
        let record = CKRecord(recordType: SyncRecordType.person, recordID: CKRecord.ID(recordName: "Person:anna", zoneID: CKRecordZone.ID(zoneName: "Test")))
        let fields = CloudSync.systemFields(of: record)
        try database.syncSetRecordInfo(SyncRecordType.person, "anna", systemFields: fields, digest: "abc")
        // A save without a digest keeps the one there was.
        try database.syncSetRecordInfo(SyncRecordType.person, "anna", systemFields: fields, digest: nil)
        let info = try database.syncRecordInfo(SyncRecordType.person, "anna")
        #expect(info.digest == "abc")
        let restored = try #require(info.systemFields.flatMap(CloudSync.record(fromSystemFields:)))
        #expect(restored.recordID.recordName == "Person:anna")
        #expect(restored.recordID.zoneID.zoneName == "Test")
        try database.syncSetMeta("engineState", Data([1]))
        try database.syncResetBookkeeping()
        #expect(try database.syncRecordInfo(SyncRecordType.person, "anna").systemFields == nil)
        #expect(try database.syncMeta("engineState") == nil)
    }
}
