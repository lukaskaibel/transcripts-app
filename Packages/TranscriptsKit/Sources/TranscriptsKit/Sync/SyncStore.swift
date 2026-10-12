import CryptoKit
import Foundation
import GRDB

/// A change made on this device that iCloud doesn't have yet.
struct SyncPendingChange: Equatable, Sendable {
    var recordType: String
    var recordName: String
    var deleted: Bool
    /// Seconds since 1970.
    var changedAt: Double
}

/// The user of a device has their own id there; in iCloud they are "me", so every device finds itself.
enum SyncNames {
    static let me = "me"
}

/// What goes up for a meeting.
enum MeetingUpload: Sendable {
    case ready(MeetingPayload)
    /// Deleted (the deletion goes up instead).
    case gone
    /// Still recording or being processed: it goes up once it is finished.
    case notFinished
}

/// A meeting as it travels: the meeting and everything that hangs on it, with the people it refers to by name, so a
/// meeting that arrives before its people still knows who spoke.
struct MeetingPayload: Codable, Equatable, Sendable {
    struct PersonStub: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var meeting: Meeting
    var segments: [Segment]
    var speakers: [MeetingSpeaker]
    var summary: MeetingSummary?
    var actionItems: [ActionItem]
    var markers: [Marker]
    var people: [PersonStub]
}

/// A person as it travels (their id is the record's name).
struct PersonPayload: Codable, Equatable, Sendable {
    var name: String
    var email: String?
    var isMe: Bool
    var createdAt: Date
    var github: GitHubUser?
}

/// A voice sample as it travels, with its person's name for the case it arrives first.
struct VoiceprintPayload: Codable, Equatable, Sendable {
    var personId: String
    var personName: String
    var embedding: Data
    var meetingId: String?
    var duration: Double
    var createdAt: Date
}

enum SyncCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static let decoder = JSONDecoder()

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The files of a meeting's recording that travel: what is played and processed after a meeting, not the raw
/// capture of a running recording or a repaired track's original.
enum SyncAudio {
    static func files(of meetingId: String) -> [URL] {
        let folder = AppPaths.folder(for: meetingId)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { name in
                (name.hasSuffix(".m4a") || name.hasPrefix("import.")) && !name.hasPrefix("system-original") && !name.hasPrefix("extracted")
            }
            .sorted()
            .map { folder.appendingPathComponent($0) }
    }

    /// Names and sizes, so the same recording isn't sent twice.
    static func digest(of files: [URL]) -> String {
        let parts = files.map { url -> String in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return "\(url.lastPathComponent):\(size)"
        }
        return SyncCoding.digest(Data(parts.joined(separator: "|").utf8))
    }
}

extension AppDatabase {
    // MARK: Pending changes

    func syncPendingChanges() throws -> [SyncPendingChange] {
        try reader.read { db in
            try Row.fetchAll(db, sql: "SELECT recordType, recordName, deleted, changedAt FROM syncPending ORDER BY changedAt").map { row in
                SyncPendingChange(recordType: row["recordType"], recordName: row["recordName"], deleted: row["deleted"], changedAt: row["changedAt"])
            }
        }
    }

    /// Marks a record as changed here, for what the triggers can't see (a meeting's audio files).
    func syncMarkChanged(_ recordType: String, _ recordName: String, deleted: Bool = false) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO syncPending (recordType, recordName, deleted, changedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT (recordType, recordName) DO UPDATE SET deleted = excluded.deleted, changedAt = excluded.changedAt
                """, arguments: [recordType, recordName, deleted, Date().timeIntervalSince1970])
        }
    }

    /// When a record changed here, if it did since iCloud last had it.
    func syncPendingChangedAt(_ recordType: String, _ recordName: String) throws -> Double? {
        try reader.read { db in
            try Double.fetchOne(db, sql: "SELECT changedAt FROM syncPending WHERE recordType = ? AND recordName = ?", arguments: [recordType, recordName])
        }
    }

    /// The meetings that may go up: not recording or being processed.
    func syncFinishedMeetings() throws -> Set<String> {
        try reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM meeting WHERE status IN ('ready', 'failed')"))
        }
    }

    /// A meeting's recording was made, compressed or deleted here: it goes up, or away from iCloud if it was there.
    func syncAudioChanged(_ meetingId: String) throws {
        if !SyncAudio.files(of: meetingId).isEmpty {
            try syncMarkChanged(SyncRecordType.audio, meetingId)
        } else if try syncRecordInfo(SyncRecordType.audio, meetingId).systemFields != nil {
            try syncMarkChanged(SyncRecordType.audio, meetingId, deleted: true)
        }
    }

    /// Forgets a pending change once iCloud has it, unless the record changed again since `changedAt`.
    func syncClearPending(_ recordType: String, _ recordName: String, upTo changedAt: Double = .infinity) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM syncPending WHERE recordType = ? AND recordName = ? AND changedAt <= ?",
                           arguments: [recordType, recordName, changedAt])
        }
    }

    /// Everything on this device, for the first sync or after switching iCloud accounts.
    func syncEnqueueEverything(includeAudio: Bool) throws {
        let now = Date().timeIntervalSince1970
        try writer.write { db in
            func add(_ type: String, _ names: [String]) throws {
                for name in names {
                    try db.execute(sql: """
                        INSERT INTO syncPending (recordType, recordName, deleted, changedAt) VALUES (?, ?, 0, ?)
                        ON CONFLICT (recordType, recordName) DO NOTHING
                        """, arguments: [type, name, now])
                }
            }
            let meetings = try String.fetchAll(db, sql: "SELECT id FROM meeting")
            try add(SyncRecordType.meeting, meetings)
            if includeAudio {
                try add(SyncRecordType.audio, meetings.filter { !SyncAudio.files(of: $0).isEmpty })
            }
            try add(SyncRecordType.person, try String.fetchAll(db, sql: "SELECT id FROM person"))
            try add(SyncRecordType.voiceprint, try String.fetchAll(db, sql: "SELECT id FROM voiceprint"))
        }
    }

    // MARK: Bookkeeping

    func syncRecordInfo(_ recordType: String, _ recordName: String) throws -> (systemFields: Data?, digest: String?) {
        try reader.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT systemFields, digest FROM syncRecord WHERE recordType = ? AND recordName = ?",
                                       arguments: [recordType, recordName])
            return (row?["systemFields"], row?["digest"])
        }
    }

    func syncSetRecordInfo(_ recordType: String, _ recordName: String, systemFields: Data?, digest: String?) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO syncRecord (recordType, recordName, systemFields, digest) VALUES (?, ?, ?, ?)
                ON CONFLICT (recordType, recordName) DO UPDATE SET systemFields = excluded.systemFields,
                    digest = COALESCE(excluded.digest, syncRecord.digest)
                """, arguments: [recordType, recordName, systemFields, digest])
        }
    }

    func syncForgetRecordInfo(_ recordType: String, _ recordName: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM syncRecord WHERE recordType = ? AND recordName = ?", arguments: [recordType, recordName])
        }
    }

    func syncMeta(_ key: String) throws -> Data? {
        try reader.read { db in try Data.fetchOne(db, sql: "SELECT value FROM syncMeta WHERE key = ?", arguments: [key]) }
    }

    func syncSetMeta(_ key: String, _ value: Data?) throws {
        try writer.write { db in
            if let value {
                try db.execute(sql: "INSERT INTO syncMeta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                               arguments: [key, value])
            } else {
                try db.execute(sql: "DELETE FROM syncMeta WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Forgets what iCloud knew (after signing out or into another account); the data on this device stays.
    func syncResetBookkeeping() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM syncRecord")
            try db.execute(sql: "DELETE FROM syncMeta")
        }
    }

    // MARK: Reading what goes up

    private func localMeId(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT id FROM person WHERE isMe = 1 LIMIT 1")
    }

    /// The record name a person has in iCloud: "me" for the user.
    func syncPersonName(_ personId: String) throws -> String {
        try reader.read { db in try localMeId(db) == personId ? SyncNames.me : personId }
    }

    func syncLocalMeId() throws -> String? {
        try reader.read { db in try localMeId(db) }
    }

    /// A meeting with everything on it.
    func syncMeetingPayload(_ meetingId: String) throws -> MeetingUpload {
        try reader.read { db -> MeetingUpload in
            guard let meeting = try Meeting.fetchOne(db, key: meetingId) else { return .gone }
            guard meeting.status == .ready || meeting.status == .failed else { return .notFinished }
            let me = try localMeId(db)
            func out(_ id: String?) -> String? { id.map { $0 == me ? SyncNames.me : $0 } }
            var segments = try Segment.filter(Column("meetingId") == meetingId).order(Column("start"), Column("id")).fetchAll(db)
            for index in segments.indices { segments[index].id = nil }
            var speakers = try MeetingSpeaker.filter(Column("meetingId") == meetingId).order(Column("key")).fetchAll(db)
            var referenced = Set<String>()
            for index in speakers.indices {
                for id in [speakers[index].personId, speakers[index].suggestedPersonId].compactMap({ $0 }) + speakers[index].candidatePersonIds {
                    referenced.insert(id)
                }
                speakers[index].personId = out(speakers[index].personId)
                speakers[index].suggestedPersonId = out(speakers[index].suggestedPersonId)
                speakers[index].rejectedPersonIds = speakers[index].rejectedPersonIds.compactMap { out($0) }
                speakers[index].candidatePersonIds = speakers[index].candidatePersonIds.compactMap { out($0) }
            }
            var items = try ActionItem.filter(Column("meetingId") == meetingId).order(Column("position"), Column("id")).fetchAll(db)
            for index in items.indices { items[index].id = nil }
            var markers = try Marker.filter(Column("meetingId") == meetingId).order(Column("time"), Column("id")).fetchAll(db)
            for index in markers.indices { markers[index].id = nil }
            let people = try Person.filter(keys: Array(referenced)).fetchAll(db)
                .map { MeetingPayload.PersonStub(id: out($0.id) ?? $0.id, name: $0.name) }
                .sorted { $0.id < $1.id }
            return .ready(MeetingPayload(
                meeting: meeting, segments: segments, speakers: speakers,
                summary: try MeetingSummary.fetchOne(db, key: meetingId),
                actionItems: items, markers: markers, people: people
            ))
        }
    }

    func syncPersonPayload(_ personId: String) throws -> PersonPayload? {
        try reader.read { db in
            try Person.fetchOne(db, key: personId).map {
                PersonPayload(name: $0.name, email: $0.email, isMe: $0.isMe, createdAt: $0.createdAt, github: $0.github)
            }
        }
    }

    func syncVoiceprintPayload(_ id: String) throws -> VoiceprintPayload? {
        try reader.read { db in
            guard let print = try Voiceprint.fetchOne(db, key: id),
                  let person = try Person.fetchOne(db, key: print.personId) else { return nil }
            return VoiceprintPayload(personId: person.isMe ? SyncNames.me : person.id, personName: person.name, embedding: print.embedding,
                                     meetingId: print.meetingId, duration: print.duration, createdAt: print.createdAt)
        }
    }

    // MARK: Writing what comes down

    /// Writes a change from iCloud without it counting as a change here.
    private func applying<T>(_ work: (Database) throws -> T) throws -> T {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO syncApplying (flag) VALUES (1)")
            defer { try? db.execute(sql: "DELETE FROM syncApplying") }
            return try work(db)
        }
    }

    /// The local id for a person's id in iCloud, creating the user or a person the meeting names if they aren't here.
    private func localPersonId(_ id: String, name: String?, _ db: Database) throws -> String {
        if id == SyncNames.me {
            if let me = try localMeId(db) { return me }
            let me = Person(name: name ?? String(localized: "Ich", comment: "the user's own name when macOS knows none"), isMe: true)
            try me.insert(db)
            return me.id
        }
        if try Person.exists(db, key: id) == false {
            try Person(id: id, name: name ?? "?").insert(db)
        }
        return id
    }

    func syncApply(meeting payload: MeetingPayload) throws {
        try applying { db in
            var names: [String: String] = [:]
            for stub in payload.people {
                names[stub.id] = try localPersonId(stub.id, name: stub.name, db)
            }
            func local(_ id: String?) throws -> String? {
                guard let id else { return nil }
                if let known = names[id] { return known }
                let mapped = try localPersonId(id, name: nil, db)
                names[id] = mapped
                return mapped
            }
            let meetingId = payload.meeting.id
            try payload.meeting.save(db)
            try Segment.filter(Column("meetingId") == meetingId).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).deleteAll(db)
            try ActionItem.filter(Column("meetingId") == meetingId).deleteAll(db)
            try Marker.filter(Column("meetingId") == meetingId).deleteAll(db)
            try MeetingSummary.deleteOne(db, key: meetingId)
            for var segment in payload.segments {
                segment.id = nil
                segment.meetingId = meetingId
                try segment.insert(db)
            }
            for var speaker in payload.speakers {
                speaker.meetingId = meetingId
                speaker.personId = try local(speaker.personId)
                speaker.suggestedPersonId = try local(speaker.suggestedPersonId)
                speaker.rejectedPersonIds = try speaker.rejectedPersonIds.compactMap { try local($0) }
                speaker.candidatePersonIds = try speaker.candidatePersonIds.compactMap { try local($0) }
                try speaker.insert(db)
            }
            if let summary = payload.summary { try summary.insert(db) }
            for var item in payload.actionItems {
                item.id = nil
                item.meetingId = meetingId
                try item.insert(db)
            }
            for var marker in payload.markers {
                marker.id = nil
                marker.meetingId = meetingId
                try marker.insert(db)
            }
        }
    }

    /// A person from iCloud. Returns the person here with the same name and another id, if there is one: two
    /// devices that each met someone make two people of them, which `syncMergeTwins` makes one again.
    func syncApply(person payload: PersonPayload, recordName: String) throws -> (local: String, twin: String?) {
        try applying { db in
            let id = try localPersonId(recordName, name: payload.name, db)
            guard var person = try Person.fetchOne(db, key: id) else { return (id, nil) }
            person.name = payload.name
            person.email = payload.email
            person.github = payload.github ?? person.github
            if !person.isMe { person.createdAt = payload.createdAt }
            try person.update(db)
            guard !person.isMe else { return (id, nil) }
            let twin = try String.fetchOne(db, sql: """
                SELECT id FROM person WHERE isMe = 0 AND id != ? AND lower(trim(name)) = lower(trim(?)) ORDER BY id LIMIT 1
                """, arguments: [id, payload.name])
            return (id, twin)
        }
    }

    /// Two people of the same name become one, on every device the same: the one with the smaller id stays. Written
    /// as a change of this device, so the others learn which voices and meetings moved.
    func syncMergeTwins(_ first: String, _ second: String) throws {
        let (keep, drop) = first < second ? (first, second) : (second, first)
        try mergePerson(drop, into: keep)
    }

    func syncApply(voiceprint payload: VoiceprintPayload, recordName: String) throws {
        try applying { db in
            let personId = try localPersonId(payload.personId, name: payload.personName, db)
            let meetingId = try payload.meetingId.flatMap { try Meeting.exists(db, key: $0) ? $0 : nil }
            try Voiceprint(id: recordName, personId: personId, embedding: payload.embedding, meetingId: meetingId,
                           duration: payload.duration, createdAt: payload.createdAt).save(db)
        }
    }

    /// A record deleted on another device. A person who has a namesake here is merged into them rather than deleted,
    /// since that is what the other device did.
    func syncApplyDeletion(_ recordType: String, _ recordName: String) throws {
        switch recordType {
        case SyncRecordType.meeting:
            try applying { db in _ = try Meeting.deleteOne(db, key: recordName) }
            try? FileManager.default.removeItem(at: AppPaths.folder(for: recordName))
        case SyncRecordType.audio:
            for file in SyncAudio.files(of: recordName) { try? FileManager.default.removeItem(at: file) }
        case SyncRecordType.person:
            guard recordName != SyncNames.me else { return }
            let twin = try reader.read { db in
                try String.fetchOne(db, sql: """
                    SELECT other.id FROM person AS gone JOIN person AS other
                    ON other.id != gone.id AND other.isMe = 0 AND lower(trim(other.name)) = lower(trim(gone.name))
                    WHERE gone.id = ? ORDER BY other.id LIMIT 1
                    """, arguments: [recordName])
            }
            if let twin {
                try applying { db in
                    try db.execute(sql: "UPDATE meetingSpeaker SET personId = ? WHERE personId = ?", arguments: [twin, recordName])
                    try db.execute(sql: "UPDATE meetingSpeaker SET suggestedPersonId = ? WHERE suggestedPersonId = ?", arguments: [twin, recordName])
                    try db.execute(sql: "UPDATE voiceprint SET personId = ? WHERE personId = ?", arguments: [twin, recordName])
                    _ = try Person.deleteOne(db, key: recordName)
                }
            } else {
                try applying { db in
                    try db.execute(sql: "UPDATE meetingSpeaker SET assignment = 'unknown', confidence = 0 WHERE personId = ?", arguments: [recordName])
                    _ = try Person.deleteOne(db, key: recordName)
                }
            }
        case SyncRecordType.voiceprint:
            try applying { db in _ = try Voiceprint.deleteOne(db, key: recordName) }
        default:
            break
        }
    }

    /// A meeting's recording from iCloud, unless this device has its own.
    func syncApplyAudio(meetingId: String, files: [(name: String, url: URL)]) throws {
        guard SyncAudio.files(of: meetingId).isEmpty else { return }
        let folder = AppPaths.folder(for: meetingId)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files where !file.name.contains("/") {
            let target = folder.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: file.url, to: target)
        }
    }

    /// What iCloud has for a record is newer than the change here: when the change here is older (or there is none).
    func syncRemoteWins(_ recordType: String, _ recordName: String, remoteModifiedAt: Double) throws -> Bool {
        try reader.read { db in
            guard let local = try Double.fetchOne(db, sql: "SELECT changedAt FROM syncPending WHERE recordType = ? AND recordName = ?",
                                                  arguments: [recordType, recordName]) else { return true }
            return remoteModifiedAt >= local
        }
    }
}
