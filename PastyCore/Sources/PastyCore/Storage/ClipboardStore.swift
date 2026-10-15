import Foundation

/// Local, persistent clipboard history backed by SQLite (WAL) with an FTS5 index.
///
/// All database work is serialized on this actor, so callers on the main actor never touch SQLite.
public actor ClipboardStore {
    /// How the full-text index tokenizes. Trigram gives true substring matching; older SQLite
    /// builds fall back to word-prefix matching.
    public enum SearchIndexMode: Sendable { case trigram, unicode }

    public nonisolated let searchIndexMode: SearchIndexMode
    /// The database file; `HistoryReader`s open their own connection to it.
    public nonisolated let databasePath: String
    private let db: SQLiteConnection
    /// Set for stores created without a URL: a scratch file removed when the store goes away.
    private nonisolated let temporaryURL: URL?
    /// Cached number of unpinned entries, so enforcing the history limit doesn't count a
    /// million rows on every copy. `nil` when it must be recounted.
    private var unpinnedTotal: Int?

    static let schemaVersion = 2

    /// Keeps the full-text index in step when entries are deleted.
    static let deleteTriggerSQL = """
    CREATE TRIGGER IF NOT EXISTS items_after_delete AFTER DELETE ON items BEGIN
        DELETE FROM items_fts WHERE rowid = old.id;
    END;
    """

    /// Upper bound on full-text candidates per search. Matches are collected newest first, so
    /// a search over a huge history stays fast however common the term is.
    static let searchCandidateLimit = 1_000
    /// Time budget for the scan behind a search; whatever matched by then is ranked and shown.
    static let searchTimeBudget = 0.35

    private static let itemColumns = """
    i.id, i.kind, i.title, i.subtitle, i.file_path, i.is_code, i.pinned, i.created_at, i.updated_at, \
    i.source_bundle, i.source_name, i.byte_size, i.char_count, i.line_count, i.width, i.height, \
    i.file_count, i.copy_count
    """
    private static let itemColumnCount: Int32 = 18

    /// Opens (or creates) a store. Pass `nil` for a throwaway database (deleted with the store).
    public init(url: URL?) throws {
        let temporary = url == nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("pasty-\(UUID().uuidString).sqlite")
            : nil
        let file = url ?? temporary!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteConnection(path: file.path)
        self.db = db
        databasePath = file.path
        temporaryURL = temporary
        searchIndexMode = try Self.migrate(db)
    }

    deinit {
        guard let temporaryURL else { return }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: temporaryURL.path + suffix)
        }
    }

    /// A separate, read-only connection for paging through history synchronously (e.g. from the
    /// main thread while a list scrolls). WAL lets it read while this store writes.
    public nonisolated func makeReader() throws -> HistoryReader {
        try HistoryReader(path: databasePath)
    }

    /// Opens the store at `url`; if the file is unreadable it is moved aside and a fresh one created.
    public static func openRecovering(at url: URL) throws -> ClipboardStore {
        do {
            return try ClipboardStore(url: url)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path + suffix)
                guard fm.fileExists(atPath: file.path) else { continue }
                let backup = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
                try? fm.moveItem(at: file, to: backup)
            }
            return try ClipboardStore(url: url)
        }
    }

    private static func migrate(_ db: SQLiteConnection) throws -> SearchIndexMode {
        // auto_vacuum must be chosen before the first table exists.
        try db.execute("PRAGMA auto_vacuum = INCREMENTAL")
        _ = try db.pragma("journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA foreign_keys = ON")
        try db.execute("PRAGMA temp_store = MEMORY")

        let version = Int(try db.pragma("user_version") ?? "0") ?? 0
        if version == 0 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind INTEGER NOT NULL,
                    is_code INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    copy_count INTEGER NOT NULL DEFAULT 1,
                    byte_size INTEGER NOT NULL DEFAULT 0,
                    char_count INTEGER NOT NULL DEFAULT 0,
                    line_count INTEGER NOT NULL DEFAULT 0,
                    width INTEGER NOT NULL DEFAULT 0,
                    height INTEGER NOT NULL DEFAULT 0,
                    file_count INTEGER NOT NULL DEFAULT 0,
                    content_hash BLOB NOT NULL,
                    source_bundle TEXT,
                    source_name TEXT,
                    title TEXT NOT NULL,
                    subtitle TEXT,
                    file_path TEXT,
                    preview TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_items_updated ON items(updated_at DESC);
                CREATE INDEX IF NOT EXISTS idx_items_hash ON items(content_hash);
                CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(pinned, updated_at DESC);

                CREATE TABLE IF NOT EXISTS representations (
                    item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                    item_index INTEGER NOT NULL,
                    position INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    data BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_representations_item ON representations(item_id);

                CREATE TABLE IF NOT EXISTS thumbnails (
                    item_id INTEGER PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                    data BLOB NOT NULL
                );
                """)
                do {
                    try db.execute("CREATE VIRTUAL TABLE items_fts USING fts5(content, meta, tokenize = 'trigram')")
                } catch {
                    try db.execute("CREATE VIRTUAL TABLE items_fts USING fts5(content, meta, tokenize = 'unicode61 remove_diacritics 2')")
                }
                try db.execute(deleteTriggerSQL)
            }
        }

        if version < 2 {
            // List order is (updated_at, id) so paging by key is exact even when dates tie.
            try db.transaction {
                try db.execute("""
                CREATE INDEX IF NOT EXISTS idx_items_order ON items(updated_at DESC, id DESC);
                CREATE INDEX IF NOT EXISTS idx_items_pinned_order ON items(pinned, updated_at DESC, id DESC);
                DROP INDEX IF EXISTS idx_items_updated;
                DROP INDEX IF EXISTS idx_items_pinned;
                PRAGMA user_version = \(schemaVersion);
                """)
            }
        }

        let definition = try db.prepare("SELECT sql FROM sqlite_master WHERE name = 'items_fts'").firstRow { $0.string(0) } ?? ""
        return definition.contains("trigram") ? .trigram : .unicode
    }

    // MARK: - Writing

    @discardableResult
    public func insert(_ draft: ClipDraft, duplicates: DuplicateHandling = .moveToTop, maxHistory: Int = 1_000) throws -> InsertOutcome {
        let outcome: InsertOutcome = try db.transaction {
            switch duplicates {
            case .moveToTop:
                let existing = try db.prepare("SELECT id FROM items WHERE content_hash = ? ORDER BY updated_at DESC, id DESC LIMIT 1")
                    .bind(.blob(draft.contentHash))
                    .firstRow { $0.int64(0) }
                if let id = existing {
                    try db.prepare("""
                    UPDATE items SET updated_at = ?, copy_count = copy_count + 1,
                        source_bundle = coalesce(?, source_bundle), source_name = coalesce(?, source_name)
                    WHERE id = ?
                    """)
                    .bind(.date(draft.date), .optionalText(draft.source?.bundleID), .optionalText(draft.source?.name), .integer(id))
                    .run()
                    return .updated(id)
                }
            case .ignoreConsecutive:
                let latest = try db.prepare("SELECT content_hash FROM items ORDER BY updated_at DESC, id DESC LIMIT 1").firstRow { $0.data(0) }
                if latest == draft.contentHash {
                    return .skipped
                }
            case .keepAll:
                break
            }
            return .inserted(try insertRow(draft))
        }
        if case .inserted = outcome {
            if let total = unpinnedTotal { unpinnedTotal = total + 1 }
            try enforceLimit(maxHistory: maxHistory)
        }
        return outcome
    }

    private func insertRow(_ draft: ClipDraft, createdAt: Date? = nil, copyCount: Int = 1, pinned: Bool = false) throws -> ClipItem.ID {
        try db.prepare("""
        INSERT INTO items (kind, is_code, pinned, created_at, updated_at, copy_count, byte_size, char_count,
            line_count, width, height, file_count, content_hash, source_bundle, source_name, title, subtitle,
            file_path, preview)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        .bind(
            .int(draft.kind.rawValue), .bool(draft.isCode), .bool(pinned), .date(createdAt ?? draft.date), .date(draft.date),
            .int(max(1, copyCount)),
            .int(draft.byteSize), .int(draft.characterCount), .int(draft.lineCount), .int(draft.imageWidth),
            .int(draft.imageHeight), .int(draft.fileCount), .blob(draft.contentHash),
            .optionalText(draft.source?.bundleID), .optionalText(draft.source?.name), .text(draft.title),
            .optionalText(draft.subtitle), .optionalText(draft.filePath), .text(draft.preview)
        )
        .run()
        let id = db.lastInsertRowID

        let representation = try db.prepare("INSERT INTO representations (item_id, item_index, position, type, data) VALUES (?, ?, ?, ?, ?)")
        for (itemIndex, item) in draft.snapshot.items.enumerated() {
            for (position, rep) in item.representations.enumerated() {
                representation.reset()
                try representation.bind(.integer(id), .int(itemIndex), .int(position), .text(rep.type), .blob(rep.data)).run()
            }
        }

        if let thumbnail = draft.thumbnail {
            try db.prepare("INSERT INTO thumbnails (item_id, data) VALUES (?, ?)").bind(.integer(id), .blob(thumbnail)).run()
        }

        let meta = [draft.source?.name, draft.subtitle].compactMap { $0 }.joined(separator: " ")
        try db.prepare("INSERT INTO items_fts (rowid, content, meta) VALUES (?, ?, ?)")
            .bind(.integer(id), .text(draft.searchContent), .text(meta))
            .run()
        return id
    }

    // MARK: Import

    /// Imports entries from another clipboard manager in one transaction, preserving their dates,
    /// copy counts and pinned state. Content already in history is not duplicated: the existing
    /// entry is pinned if the imported one was, and keeps the more recent date.
    public func importClips(_ clips: [ImportedClip]) throws -> (inserted: Int, merged: Int) {
        unpinnedTotal = nil
        return try db.transaction {
            var inserted = 0
            var merged = 0
            for clip in clips {
                let existing = try db.prepare("SELECT id FROM items WHERE content_hash = ? ORDER BY updated_at DESC, id DESC LIMIT 1")
                    .bind(.blob(clip.draft.contentHash))
                    .firstRow { $0.int64(0) }
                if let id = existing {
                    try db.prepare("""
                    UPDATE items SET pinned = max(pinned, ?), updated_at = max(updated_at, ?),
                        created_at = min(created_at, ?) WHERE id = ?
                    """)
                    .bind(.bool(clip.pinned), .date(clip.draft.date), .date(clip.firstCopiedAt), .integer(id))
                    .run()
                    merged += 1
                } else {
                    _ = try insertRow(clip.draft, createdAt: clip.firstCopiedAt, copyCount: clip.copyCount, pinned: clip.pinned)
                    inserted += 1
                }
            }
            return (inserted, merged)
        }
    }

    /// Number of unpinned entries (the ones the history limit applies to).
    public func unpinnedCount() throws -> Int {
        let count = try db.prepare("SELECT count(*) FROM items WHERE pinned = 0").firstRow { $0.int(0) } ?? 0
        unpinnedTotal = count
        return count
    }

    /// Deletes the oldest unpinned entries beyond `maxHistory`. Pinned entries never count or expire.
    ///
    /// Uses the cached count, so on a normal copy this costs nothing; trimming walks the index
    /// from the oldest end, in batches, rather than skipping over the entries that are kept.
    public func enforceLimit(maxHistory: Int) throws {
        let limit = max(0, maxHistory)
        var count = try unpinnedTotal ?? unpinnedCount()
        while count > limit {
            let batch = min(count - limit, 5_000)
            let deleted: Int = try db.transaction {
                try db.prepare("""
                DELETE FROM items WHERE id IN (
                    SELECT id FROM items WHERE pinned = 0 ORDER BY updated_at ASC, id ASC LIMIT ?
                )
                """)
                .bind(.int(batch))
                .run()
                return db.changes
            }
            guard deleted > 0 else {
                unpinnedTotal = nil
                return
            }
            count -= deleted
        }
        unpinnedTotal = count
    }

    public func setPinned(_ pinned: Bool, for id: ClipItem.ID) throws {
        unpinnedTotal = nil
        try db.prepare("UPDATE items SET pinned = ? WHERE id = ?").bind(.bool(pinned), .integer(id)).run()
    }

    /// Moves an entry to the top, e.g. after it was pasted.
    public func markUsed(_ id: ClipItem.ID, at date: Date = Date()) throws {
        try db.prepare("UPDATE items SET updated_at = ? WHERE id = ?").bind(.date(date), .integer(id)).run()
    }

    public func delete(_ id: ClipItem.ID) throws {
        unpinnedTotal = nil
        try db.prepare("DELETE FROM items WHERE id = ?").bind(.integer(id)).run()
    }

    /// Removes history. Pinned entries survive when `keepPinned` is true.
    public func clear(keepPinned: Bool) throws {
        unpinnedTotal = nil
        // Deleting rows one by one from the full-text index takes about a minute for a million
        // entries; dropping and recreating it (and letting SQLite truncate the plain tables,
        // which needs triggers and foreign keys out of the way) takes seconds. Pinned entries
        // are set aside and put back.
        let tokenizer = searchIndexMode == .trigram ? "trigram" : "unicode61 remove_diacritics 2"
        try db.execute("PRAGMA foreign_keys = OFF")
        defer { try? db.execute("PRAGMA foreign_keys = ON") }
        try db.transaction {
            let keepFilter = keepPinned ? "WHERE pinned = 1" : "WHERE 0"
            try db.execute("""
            CREATE TEMP TABLE keep_items AS SELECT * FROM items \(keepFilter);
            CREATE TEMP TABLE keep_representations AS SELECT * FROM representations WHERE item_id IN (SELECT id FROM keep_items);
            CREATE TEMP TABLE keep_thumbnails AS SELECT * FROM thumbnails WHERE item_id IN (SELECT id FROM keep_items);
            CREATE TEMP TABLE keep_fts AS SELECT rowid AS id, content, meta FROM items_fts WHERE rowid IN (SELECT id FROM keep_items);
            DROP TRIGGER IF EXISTS items_after_delete;
            DROP TABLE items_fts;
            CREATE VIRTUAL TABLE items_fts USING fts5(content, meta, tokenize = '\(tokenizer)');
            DELETE FROM representations;
            DELETE FROM thumbnails;
            DELETE FROM items;
            INSERT INTO items SELECT * FROM keep_items;
            INSERT INTO representations SELECT * FROM keep_representations;
            INSERT INTO thumbnails SELECT * FROM keep_thumbnails;
            INSERT INTO items_fts (rowid, content, meta) SELECT id, content, meta FROM keep_fts;
            DROP TABLE keep_items;
            DROP TABLE keep_representations;
            DROP TABLE keep_thumbnails;
            DROP TABLE keep_fts;
            \(Self.deleteTriggerSQL)
            """)
        }
        try? db.execute("PRAGMA incremental_vacuum")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Reading

    public func items(filter: ClipFilter = .all, limit: Int = 20_000) throws -> [ClipItem] {
        let sql = filter == .pinned
            ? "SELECT \(Self.itemColumns) FROM items i WHERE i.pinned = 1 ORDER BY i.updated_at DESC, i.id DESC LIMIT ?"
            : "SELECT \(Self.itemColumns) FROM items i ORDER BY i.updated_at DESC, i.id DESC LIMIT ?"
        let statement = try db.prepare(sql).bind(.int(limit))
        var result: [ClipItem] = []
        while try statement.step() {
            result.append(Self.item(from: statement))
        }
        return result
    }

    public func item(_ id: ClipItem.ID) throws -> ClipItem? {
        try db.prepare("SELECT \(Self.itemColumns) FROM items i WHERE i.id = ?").bind(.integer(id)).firstRow { Self.item(from: $0) }
    }

    public func count(filter: ClipFilter = .all) throws -> Int {
        let sql = filter == .pinned ? "SELECT count(*) FROM items WHERE pinned = 1" : "SELECT count(*) FROM items"
        return try db.prepare(sql).firstRow { $0.int(0) } ?? 0
    }

    /// Everything a list needs to show `filter` without loading it: the total, the date
    /// sections (from indexed range counts) and the first page. Read as one consistent snapshot.
    public func layout(filter: ClipFilter = .all, now: Date = Date(), calendar: Calendar = .current) throws -> HistoryLayout {
        try db.readTransaction {
            let first = try Self.page(in: db, filter: filter, after: nil, offset: 0, limit: HistoryPager.pageSize)
            let total: Int
            let sections: [ListSection]
            if filter == .pinned {
                total = try db.prepare("SELECT count(*) FROM items WHERE pinned = 1").firstRow { $0.int(0) } ?? 0
                sections = total > 0 ? [ListSection(title: "Pinned", start: 0, count: total)] : []
            } else {
                total = try db.prepare("SELECT count(*) FROM items").firstRow { $0.int(0) } ?? 0
                let boundaries = HistorySections.boundaries(now: now, calendar: calendar)
                let counter = try db.prepare("SELECT count(*) FROM items WHERE updated_at >= ?")
                var cumulative: [Int] = []
                for boundary in boundaries {
                    if let since = boundary.since {
                        counter.reset()
                        cumulative.append(try counter.bind(.date(since)).firstRow { $0.int(0) } ?? 0)
                    } else {
                        cumulative.append(total)
                    }
                }
                sections = HistorySections.sections(cumulativeCounts: cumulative, titles: boundaries.map(\.title))
            }
            return HistoryLayout(total: total, sections: sections, firstPage: first.items, firstPageLastKey: first.lastKey)
        }
    }

    /// One page of history in list order. Pages after the first should pass the previous page's
    /// last key: seeking by key costs the same anywhere in a million entries, unlike an offset.
    static func page(in db: SQLiteConnection, filter: ClipFilter, after key: HistoryKey?, offset: Int, limit: Int) throws -> HistoryPage {
        var clauses: [String] = []
        if filter == .pinned { clauses.append("i.pinned = 1") }
        if key != nil { clauses.append("(i.updated_at, i.id) < (?, ?)") }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let statement = try db.prepare("""
        SELECT \(itemColumns), i.updated_at FROM items i \(whereClause)
        ORDER BY i.updated_at DESC, i.id DESC LIMIT ? OFFSET ?
        """)
        var values: [SQLiteValue] = []
        if let key { values += [.real(key.updatedAt), .integer(key.id)] }
        values += [.int(limit), .int(key == nil ? offset : 0)]
        for (index, value) in values.enumerated() { statement.bind(value, at: Int32(index + 1)) }
        defer { statement.reset() }

        var page = HistoryPage()
        page.items.reserveCapacity(limit)
        while try statement.step() {
            let item = item(from: statement)
            page.items.append(item)
            page.lastKey = HistoryKey(updatedAt: statement.double(itemColumnCount), id: item.id)
        }
        return page
    }

    /// Where an entry sits in list order, or `nil` if it isn't in the list.
    static func position(in db: SQLiteConnection, of id: ClipItem.ID, filter: ClipFilter) throws -> Int? {
        let pinnedClause = filter == .pinned ? " AND pinned = 1" : ""
        guard let updatedAt = try db.prepare("SELECT updated_at FROM items WHERE id = ?\(pinnedClause)")
            .bind(.integer(id)).firstRow({ $0.double(0) }) else { return nil }
        return try db.prepare("SELECT count(*) FROM items WHERE (updated_at, id) > (?, ?)\(pinnedClause)")
            .bind(.real(updatedAt), .integer(id))
            .firstRow { $0.int(0) }
    }

    /// The stored pasteboard contents of an entry, ready to be written back.
    public func snapshot(for id: ClipItem.ID) throws -> PasteboardSnapshot? {
        try Self.snapshot(in: db, for: id)
    }

    static func snapshot(in db: SQLiteConnection, for id: ClipItem.ID) throws -> PasteboardSnapshot? {
        let statement = try db.prepare("SELECT item_index, type, data FROM representations WHERE item_id = ? ORDER BY item_index, position")
            .bind(.integer(id))
        var items: [Int: [PasteboardRepresentation]] = [:]
        while try statement.step() {
            let index = statement.int(0)
            guard let type = statement.string(1) else { continue }
            items[index, default: []].append(PasteboardRepresentation(type: type, data: statement.data(2) ?? Data()))
        }
        guard !items.isEmpty else { return nil }
        return PasteboardSnapshot(items: items.keys.sorted().map { PasteboardItemSnapshot(representations: items[$0]!) })
    }

    public func preview(for id: ClipItem.ID) throws -> String? {
        try db.prepare("SELECT preview FROM items WHERE id = ?").bind(.integer(id)).firstRow { $0.string(0) }
    }

    public func thumbnail(for id: ClipItem.ID) throws -> Data? {
        try db.prepare("SELECT data FROM thumbnails WHERE item_id = ?").bind(.integer(id)).firstRow { $0.data(0) }
    }

    // MARK: - Search

    /// Case-insensitive, substring search across content and metadata, ranked by relevance.
    ///
    /// Scales to a million entries: candidates are gathered newest-first straight from the
    /// full-text index and capped (`searchCandidateLimit`), and the scan has a time budget.
    /// The most recently used entries are always considered too, even if they were first copied
    /// long ago.
    public func search(_ query: String, filter: ClipFilter = .all, limit: Int = 500) throws -> [ClipItem] {
        let search = SearchQuery(query)
        guard !search.isEmpty else { return try items(filter: filter, limit: limit) }

        let indexed = search.tokens.filter { searchIndexMode == .unicode || $0.count >= 3 }
        // SQLite's LIKE only folds ASCII case, so short non-ASCII terms ("é", "日本") are matched
        // in Swift with full Unicode case and diacritic folding instead.
        let unicodeShort = search.tokens.filter { !indexed.contains($0) && !$0.allSatisfy(\.isASCII) }
        let likeTokens = search.tokens.filter { !indexed.contains($0) && !unicodeShort.contains($0) }

        func clauses(qualifier: String) -> (sql: [String], values: [SQLiteValue]) {
            var sql: [String] = []
            var values: [SQLiteValue] = []
            if !indexed.isEmpty {
                sql.append("items_fts MATCH ?")
                let expression = indexed.map { token in
                    let quoted = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    return searchIndexMode == .unicode ? quoted + "*" : quoted
                }
                values.append(.text(expression.joined(separator: " AND ")))
            }
            for token in likeTokens {
                sql.append("(\(qualifier)content LIKE ? ESCAPE '\\' OR \(qualifier)meta LIKE ? ESCAPE '\\')")
                let pattern = "%" + SearchQuery.escapeLike(token) + "%"
                values += [.text(pattern), .text(pattern)]
            }
            if sql.isEmpty { sql.append("1") }
            return (sql, values)
        }

        let sql: String
        let values: [SQLiteValue]
        if filter == .pinned {
            // Few entries are pinned: walk them and check each against the index.
            let (where_, bound) = clauses(qualifier: "f.")
            sql = """
            SELECT \(Self.itemColumns), substr(i.preview, 1, 600), f.meta FROM items i JOIN items_fts f ON f.rowid = i.id
            WHERE i.pinned = 1 AND \(where_.joined(separator: " AND "))
            ORDER BY i.updated_at DESC, i.id DESC LIMIT \(Self.searchCandidateLimit)
            """
            values = bound
        } else {
            // Newest matches straight off the index (rowid order), stopping at the cap; sorting
            // every match by date first would visit all of them.
            let (where_, bound) = clauses(qualifier: "")
            sql = """
            SELECT \(Self.itemColumns), substr(i.preview, 1, 600), f.meta FROM items_fts f JOIN items i ON i.id = f.rowid
            WHERE f.rowid IN (
                SELECT rowid FROM items_fts WHERE \(where_.joined(separator: " AND "))
                ORDER BY rowid DESC LIMIT \(Self.searchCandidateLimit)
            )
            """
            values = bound
        }

        let statement = try db.prepare(sql)
        for (offset, value) in values.enumerated() {
            statement.bind(value, at: Int32(offset + 1))
        }
        defer { statement.reset() }

        func matchesUnicodeShort(_ item: ClipItem, preview: String, meta: String) -> Bool {
            guard !unicodeShort.isEmpty else { return true }
            let haystack = [item.title, preview, meta].joined(separator: "\n")
            return unicodeShort.allSatisfy { haystack.range(of: $0, options: .caseInsensitive) != nil }
        }

        var candidates: [SearchRanker.Candidate] = []
        var seen = Set<ClipItem.ID>()
        db.setDeadline(Self.searchTimeBudget)
        defer { db.setDeadline(nil) }
        var scanned = 0
        var interrupted = false
        do {
            while try statement.step() {
                scanned += 1
                let item = Self.item(from: statement)
                let preview = statement.string(Self.itemColumnCount) ?? ""
                guard matchesUnicodeShort(item, preview: preview, meta: statement.string(Self.itemColumnCount + 1) ?? "") else { continue }
                seen.insert(item.id)
                candidates.append(SearchRanker.Candidate(item: item, preview: preview))
            }
        } catch let error as SQLiteError where error.isInterrupt {
            interrupted = true // out of time: rank what was found
        }
        db.setDeadline(nil)

        // Entries copied long ago but used recently sit low in rowid order; when the index had
        // more matches than the cap (or ran out of time), check the most recently used ones too.
        if filter == .all && (scanned >= Self.searchCandidateLimit || interrupted) {
            let recent = try db.prepare("""
            SELECT \(Self.itemColumns), substr(i.preview, 1, 600), coalesce(i.source_name, '') || ' ' || coalesce(i.subtitle, '')
            FROM items i ORDER BY i.updated_at DESC, i.id DESC LIMIT 300
            """)
            defer { recent.reset() }
            while try recent.step() {
                let item = Self.item(from: recent)
                guard !seen.contains(item.id) else { continue }
                let preview = recent.string(Self.itemColumnCount) ?? ""
                let meta = recent.string(Self.itemColumnCount + 1) ?? ""
                let haystack = [item.title, preview, meta].joined(separator: "\n")
                guard search.tokens.allSatisfy({ haystack.range(of: $0, options: .caseInsensitive) != nil }) else { continue }
                seen.insert(item.id)
                candidates.append(SearchRanker.Candidate(item: item, preview: preview))
            }
        }
        // The ranker breaks ties by order, so present candidates most recently used first.
        candidates.sort { ($0.item.updatedAt, $0.item.id) > ($1.item.updatedAt, $1.item.id) }
        return Array(SearchRanker.rank(candidates, for: search).prefix(limit))
    }

    // MARK: - Mapping

    static func item(from s: Statement) -> ClipItem {
        ClipItem(
            id: s.int64(0),
            kind: ClipKind(rawValue: s.int(1)) ?? .text,
            title: s.string(2) ?? "",
            subtitle: s.string(3),
            filePath: s.string(4),
            isCode: s.bool(5),
            isPinned: s.bool(6),
            createdAt: Date(timeIntervalSince1970: s.double(7)),
            updatedAt: Date(timeIntervalSince1970: s.double(8)),
            sourceBundleID: s.string(9),
            sourceName: s.string(10),
            byteSize: s.int(11),
            characterCount: s.int(12),
            lineCount: s.int(13),
            imageWidth: s.int(14),
            imageHeight: s.int(15),
            fileCount: s.int(16),
            copyCount: s.int(17)
        )
    }
}
