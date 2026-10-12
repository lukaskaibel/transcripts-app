import Foundation
import GRDB

/// What iCloud sync keeps in the database: the records changed here and not yet in iCloud, iCloud's bookkeeping per
/// record, and the sync engine's state.
///
/// Triggers write every change of a meeting (and of its lines, speakers, summary, tasks and markers), a person or a
/// voice sample into `syncPending`, so nothing is missed, not even across a crash or with sync turned off. While a
/// change from iCloud is written, `syncApplying` holds a row and the triggers keep still: what came from iCloud
/// doesn't go back.
enum SyncSchema {
    static func create(_ db: Database) throws {
        try db.create(table: "syncPending") { t in
            t.column("recordType", .text).notNull()
            t.column("recordName", .text).notNull()
            t.column("deleted", .boolean).notNull().defaults(to: false)
            /// Seconds since 1970, when the change happened.
            t.column("changedAt", .double).notNull()
            t.primaryKey(["recordType", "recordName"])
        }
        try db.create(table: "syncRecord") { t in
            t.column("recordType", .text).notNull()
            t.column("recordName", .text).notNull()
            /// The record's system fields as iCloud last returned them, so the next save carries its change tag.
            t.column("systemFields", .blob)
            /// A digest of what was last sent or received, so an unchanged record isn't sent again.
            t.column("digest", .text)
            t.primaryKey(["recordType", "recordName"])
        }
        try db.create(table: "syncMeta") { t in
            t.primaryKey("key", .text)
            t.column("value", .blob)
        }
        try db.create(table: "syncApplying") { t in
            t.column("flag", .integer)
        }

        let now = "(julianday('now') - 2440587.5) * 86400.0"
        let quiet = "WHEN NOT EXISTS (SELECT 1 FROM syncApplying)"
        /// A change of the record itself: it exists (again) or is gone.
        func own(_ table: String, _ type: String, _ key: String = "id") throws {
            for (event, row, deleted) in [("INSERT", "NEW", 0), ("UPDATE", "NEW", 0), ("DELETE", "OLD", 1)] {
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) \(quiet)
                    BEGIN
                        INSERT INTO syncPending (recordType, recordName, deleted, changedAt)
                        VALUES ('\(type)', \(row).\(key), \(deleted), \(now))
                        ON CONFLICT (recordType, recordName) DO UPDATE SET deleted = excluded.deleted, changedAt = excluded.changedAt;
                    END
                    """)
            }
        }
        /// A change of a part of a meeting: the meeting changed (unless it is being deleted).
        func part(_ table: String) throws {
            for (event, row) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                try db.execute(sql: """
                    CREATE TRIGGER sync_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) \(quiet)
                    BEGIN
                        INSERT INTO syncPending (recordType, recordName, deleted, changedAt)
                        VALUES ('\(SyncRecordType.meeting)', \(row).meetingId, 0, \(now))
                        ON CONFLICT (recordType, recordName) DO UPDATE SET changedAt = excluded.changedAt;
                    END
                    """)
            }
        }
        try own("meeting", SyncRecordType.meeting)
        for table in ["segment", "meetingSpeaker", "summary", "actionItem", "marker"] {
            try part(table)
        }
        try own("person", SyncRecordType.person)
        try own("voiceprint", SyncRecordType.voiceprint)
        // A meeting's audio goes with it.
        try db.execute(sql: """
            CREATE TRIGGER sync_meeting_audio_delete AFTER DELETE ON meeting \(quiet)
            BEGIN
                INSERT INTO syncPending (recordType, recordName, deleted, changedAt)
                VALUES ('\(SyncRecordType.audio)', OLD.id, 1, \(now))
                ON CONFLICT (recordType, recordName) DO UPDATE SET deleted = 1, changedAt = excluded.changedAt;
            END
            """)
    }
}

/// The kinds of records in iCloud.
enum SyncRecordType {
    static let meeting = "Meeting"
    static let audio = "MeetingAudio"
    static let person = "Person"
    static let voiceprint = "Voiceprint"

    /// In the order a fetch is written: people before the voices and meetings that refer to them.
    static let applyOrder = [person, voiceprint, meeting, audio]
}
