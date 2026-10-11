import Foundation

/// Local, persistent clipboard history backed by SQLite (WAL) with an FTS5 index.
///
/// All database work is serialized on this actor, so callers on the main actor never touch SQLite.
public actor ClipboardStore {
    /// How the full-text index tokenizes. Trigram gives true substring matching; older SQLite
    /// builds fall back to word-prefix matching.
    public enum SearchIndexMode: Sendable { case trigram, unicode }

    public nonisolated let searchIndexMode: SearchIndexMode
    private let db: SQLiteConnection

    static let schemaVersion = 1

    private static let itemColumns = """
    i.id, i.kind, i.title, i.subtitle, i.file_path, i.is_code, i.pinned, i.created_at, i.updated_at, \
    i.source_bundle, i.source_name, i.byte_size, i.char_count, i.line_count, i.width, i.height, \
    i.file_count, i.copy_count
    """
    private static let itemColumnCount: Int32 = 18

    /// Opens (or creates) a store. Pass `nil` for an in-memory database.
    public init(url: URL?) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let db = try SQLiteConnection(path: url?.path ?? ":memory:")
        self.db = db
        searchIndexMode = try Self.migrate(db)
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
                try db.execute("""
                CREATE TRIGGER IF NOT EXISTS items_after_delete AFTER DELETE ON items BEGIN
                    DELETE FROM items_fts WHERE rowid = old.id;
                END;
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
                let existing = try db.prepare("SELECT id FROM items WHERE content_hash = ? ORDER BY updated_at DESC LIMIT 1")
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
                let latest = try db.prepare("SELECT content_hash FROM items ORDER BY updated_at DESC LIMIT 1").firstRow { $0.data(0) }
                if latest == draft.contentHash {
                    return .skipped
                }
            case .keepAll:
                break
            }
            return .inserted(try insertRow(draft))
        }
        if case .inserted = outcome {
            try enforceLimit(maxHistory: maxHistory)
        }
        return outcome
    }

    private func insertRow(_ draft: ClipDraft) throws -> ClipItem.ID {
        try db.prepare("""
        INSERT INTO items (kind, is_code, pinned, created_at, updated_at, copy_count, byte_size, char_count,
            line_count, width, height, file_count, content_hash, source_bundle, source_name, title, subtitle,
            file_path, preview)
        VALUES (?, ?, 0, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """)
        .bind(
            .int(draft.kind.rawValue), .bool(draft.isCode), .date(draft.date), .date(draft.date),
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

        let meta = [draft.source?.name, draft.subtitle, draft.kind.displayName].compactMap { $0 }.joined(separator: " ")
        try db.prepare("INSERT INTO items_fts (rowid, content, meta) VALUES (?, ?, ?)")
            .bind(.integer(id), .text(draft.searchContent), .text(meta))
            .run()
        return id
    }

    /// Deletes the oldest unpinned entries beyond `maxHistory`. Pinned entries never count or expire.
    public func enforceLimit(maxHistory: Int) throws {
        try db.prepare("""
        DELETE FROM items WHERE id IN (
            SELECT id FROM items WHERE pinned = 0 ORDER BY updated_at DESC LIMIT -1 OFFSET ?
        )
        """)
        .bind(.int(max(0, maxHistory)))
        .run()
    }

    public func setPinned(_ pinned: Bool, for id: ClipItem.ID) throws {
        try db.prepare("UPDATE items SET pinned = ? WHERE id = ?").bind(.bool(pinned), .integer(id)).run()
    }

    /// Moves an entry to the top, e.g. after it was pasted.
    public func markUsed(_ id: ClipItem.ID, at date: Date = Date()) throws {
        try db.prepare("UPDATE items SET updated_at = ? WHERE id = ?").bind(.date(date), .integer(id)).run()
    }

    public func delete(_ id: ClipItem.ID) throws {
        try db.prepare("DELETE FROM items WHERE id = ?").bind(.integer(id)).run()
    }

    /// Removes history. Pinned entries survive when `keepPinned` is true.
    public func clear(keepPinned: Bool) throws {
        try db.transaction {
            if keepPinned {
                try db.prepare("DELETE FROM items WHERE pinned = 0").run()
            } else {
                try db.prepare("DELETE FROM items").run()
            }
        }
        try? db.execute("PRAGMA incremental_vacuum")
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - Reading

    public func items(filter: ClipFilter = .all, limit: Int = 20_000) throws -> [ClipItem] {
        let sql = filter == .pinned
            ? "SELECT \(Self.itemColumns) FROM items i WHERE i.pinned = 1 ORDER BY i.updated_at DESC LIMIT ?"
            : "SELECT \(Self.itemColumns) FROM items i ORDER BY i.updated_at DESC LIMIT ?"
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

    /// The stored pasteboard contents of an entry, ready to be written back.
    public func snapshot(for id: ClipItem.ID) throws -> PasteboardSnapshot? {
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
    public func search(_ query: String, filter: ClipFilter = .all, limit: Int = 500) throws -> [ClipItem] {
        let search = SearchQuery(query)
        guard !search.isEmpty else { return try items(filter: filter, limit: limit) }

        var clauses: [String] = []
        var values: [SQLiteValue] = []

        let indexed = search.tokens.filter { searchIndexMode == .unicode || $0.count >= 3 }
        if !indexed.isEmpty {
            clauses.append("items_fts MATCH ?")
            let expression = indexed.map { token in
                let quoted = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                return searchIndexMode == .unicode ? quoted + "*" : quoted
            }
            values.append(.text(expression.joined(separator: " AND ")))
        }
        for token in search.tokens where !indexed.contains(token) {
            clauses.append("(f.content LIKE ? ESCAPE '\\' OR f.meta LIKE ? ESCAPE '\\')")
            let pattern = "%" + SearchQuery.escapeLike(token) + "%"
            values.append(.text(pattern))
            values.append(.text(pattern))
        }
        if filter == .pinned { clauses.append("i.pinned = 1") }

        let sql = """
        SELECT \(Self.itemColumns), i.preview FROM items_fts f JOIN items i ON i.id = f.rowid
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY i.updated_at DESC LIMIT 2000
        """
        let statement = try db.prepare(sql)
        for (offset, value) in values.enumerated() {
            statement.bind(value, at: Int32(offset + 1))
        }

        var candidates: [SearchRanker.Candidate] = []
        while try statement.step() {
            let item = Self.item(from: statement)
            let preview = statement.string(Self.itemColumnCount) ?? ""
            candidates.append(SearchRanker.Candidate(item: item, preview: preview))
        }
        return Array(SearchRanker.rank(candidates, for: search).prefix(limit))
    }

    // MARK: - Mapping

    private static func item(from s: Statement) -> ClipItem {
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
