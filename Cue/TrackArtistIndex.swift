import Foundation
import SQLite3

/// Plex exposes a separate track credit on compilations. Build its display order only on demand.
/// The empty SQLite filename creates a private temporary database that disappears on close.
actor TrackArtistIndex {
    private let db: OpaquePointer
    private var nextBatch: Int? = 0
    private var listing: (query: String, ascending: Bool, count: Int)?

    init() throws {
        var handle: OpaquePointer?
        guard sqlite3_open("", &handle) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw MusicError("Couldn’t create the temporary track index.")
        }
        db = handle
        let result = sqlite3_create_collation(handle, "artistList", SQLITE_UTF8, nil) { _, n, a, m, b in
            if n == m, let a, let b, memcmp(a, b, Int(n)) == 0 { return 0 }
            let left = String(decoding: UnsafeRawBufferPointer(start: a, count: Int(n)), as: UTF8.self)
            let right = String(decoding: UnsafeRawBufferPointer(start: b, count: Int(m)), as: UTF8.self)
            return Int32(left.localizedStandardCompare(right).rawValue)
        }
        guard result == SQLITE_OK else { throw MusicError("Couldn’t configure artist sorting.") }
        try Self.execute(handle, """
            PRAGMA cache_size = -512;
            PRAGMA temp_store = FILE;
            CREATE TABLE tracks (
                id TEXT UNIQUE, title TEXT, artist TEXT COLLATE artistList, albumID TEXT,
                album TEXT COLLATE artistList, albumArtist TEXT, year INTEGER, disc INTEGER,
                number INTEGER, duration REAL, part TEXT, searchable TEXT
            );
            CREATE TABLE listing (position INTEGER PRIMARY KEY, track INTEGER);
            """)
    }

    deinit { sqlite3_close(db) }

    func page(query: String, ascending: Bool, offset: Int,
              load: (Int) async throws -> CatalogPage) async throws -> CatalogPage {
        while let start = nextBatch {
            try Task.checkCancellation()
            let batch = try await load(start)
            try Task.checkCancellation()
            // A second request can finish the same batch while this one awaits Plex.
            guard start == nextBatch else { continue }
            try insert(batch.rows)
            nextBatch = batch.next
        }
        try Task.checkCancellation()
        let term = Self.fold(query)
        if listing?.query != term || listing?.ascending != ascending {
            try order(query: term, ascending: ascending)
        }
        let read = try Statement(db, """
            SELECT id, title, artist, albumID, album, albumArtist, year, disc, number, duration, part
            FROM listing JOIN tracks ON tracks.rowid = listing.track
            WHERE position > ? ORDER BY position LIMIT ?
            """)
        sqlite3_bind_int64(read.sql, 1, Int64(offset))
        sqlite3_bind_int(read.sql, 2, Int32(CatalogPage.capacity))
        var rows: [MusicRow] = []
        while try read.step() == SQLITE_ROW {
            let track = Track(id: read.text(0)!, title: read.text(1)!, artist: read.text(2)!,
                              disc: Int(sqlite3_column_int64(read.sql, 7)), number: Int(sqlite3_column_int64(read.sql, 8)),
                              duration: sqlite3_column_double(read.sql, 9), part: read.text(10))
            let year = sqlite3_column_type(read.sql, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(read.sql, 6))
            let album = Album(id: read.text(3)!, title: read.text(4)!, artist: read.text(5)!, year: year)
            rows.append(.track(track, album))
        }
        let count = listing?.count ?? 0
        let end = offset + rows.count
        return CatalogPage(rows: rows, total: count, next: end < count ? end : nil)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private func insert(_ rows: [MusicRow]) throws {
        let write = try Statement(db, "INSERT OR REPLACE INTO tracks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        try transaction {
            for case .track(let t, let a) in rows {
                try Task.checkCancellation()
                sqlite3_reset(write.sql)
                for (i, text) in [t.id, t.title, t.artist, a.id, a.title, a.artist].enumerated() {
                    try write.bind(text, at: Int32(i + 1))
                }
                if let year = a.year { sqlite3_bind_int64(write.sql, 7, Int64(year)) }
                else { sqlite3_bind_null(write.sql, 7) }
                sqlite3_bind_int64(write.sql, 8, Int64(t.disc))
                sqlite3_bind_int64(write.sql, 9, Int64(t.number))
                sqlite3_bind_double(write.sql, 10, t.duration)
                try write.bind(t.part, at: 11)
                try write.bind(Self.fold([t.title, t.artist, a.title, a.artist].joined(separator: "\n")), at: 12)
                _ = try write.step()
            }
        }
    }

    private func order(query: String, ascending: Bool) throws {
        let filter = query.isEmpty ? "" : "WHERE instr(searchable, ?) > 0"
        let direction = ascending ? "ASC" : "DESC"
        let sorted = try Statement(db, """
            INSERT INTO listing(track) SELECT rowid FROM tracks \(filter)
            ORDER BY artist \(direction), album, albumID, disc, number, id
            """)
        if !query.isEmpty { try sorted.bind(query, at: 1) }
        // A new sort or tab switch can cancel a large SQLite sort between VM instructions.
        sqlite3_progress_handler(db, 4096, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        try transaction {
            // Reuse the collation work across searches and changes of direction.
            try Self.execute(db, "CREATE INDEX IF NOT EXISTS byArtist ON tracks(artist, album, albumID, disc, number, id)")
            try Self.execute(db, "DELETE FROM listing")
            _ = try sorted.step()
        }
        listing = (query, ascending, Int(sqlite3_changes64(db)))
    }

    private func transaction(_ work: () throws -> Void) throws {
        try Self.execute(db, "BEGIN")
        do {
            try work()
            try Self.execute(db, "COMMIT")
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MusicError("Couldn’t update the temporary track index.")
        }
    }

    private final class Statement {
        let sql: OpaquePointer
        init(_ db: OpaquePointer, _ query: String) throws {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &pointer, nil) == SQLITE_OK, let pointer else {
                throw MusicError("Couldn’t read the temporary track index.")
            }
            sql = pointer
        }

        deinit { sqlite3_finalize(sql) }

        func bind(_ value: String?, at index: Int32) throws {
            let result = sqlite3_bind_text(sql, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard result == SQLITE_OK else { throw MusicError("Couldn’t store track metadata.") }
        }

        func text(_ column: Int32) -> String? {
            sqlite3_column_text(sql, column).map { String(cString: $0) }
        }

        func step() throws -> Int32 {
            let result = sqlite3_step(sql)
            guard result == SQLITE_ROW || result == SQLITE_DONE else {
                try Task.checkCancellation()
                throw MusicError("Couldn’t read or write the temporary track index.")
            }
            return result
        }
    }
}
