import Foundation

/// A position in list order (newest first): entries sort by `updatedAt`, then `id`.
public struct HistoryKey: Sendable, Hashable {
    /// The stored value, exactly as SQLite has it (not round-tripped through `Date`), so seeking
    /// past it never skips or repeats an entry.
    public var updatedAt: Double
    public var id: ClipItem.ID

    public init(updatedAt: Double, id: ClipItem.ID) {
        self.updatedAt = updatedAt
        self.id = id
    }
}

public struct HistoryPage: Sendable {
    public var items: [ClipItem] = []
    /// Key of the last entry, to fetch the following page from.
    public var lastKey: HistoryKey?
}

/// The shape of a list without its contents: see `ClipboardStore.layout(filter:now:calendar:)`.
public struct HistoryLayout: Sendable {
    public var total: Int
    public var sections: [ListSection]
    public var firstPage: [ClipItem]
    public var firstPageLastKey: HistoryKey?
}

/// A read-only connection for paging through history synchronously.
///
/// Not thread-safe: use each reader from one thread (the app keeps one on the main thread, where
/// a page of 200 rows reads in well under a millisecond).
public final class HistoryReader {
    private let db: SQLiteConnection

    init(path: String) throws {
        db = try SQLiteConnection(path: path, create: false)
        try db.execute("PRAGMA query_only = 1")
    }

    public func page(filter: ClipFilter, after key: HistoryKey?, offset: Int = 0, limit: Int = HistoryPager.pageSize) throws -> HistoryPage {
        try ClipboardStore.page(in: db, filter: filter, after: key, offset: offset, limit: limit)
    }

    /// Where an entry sits in list order, or `nil` if it isn't in the list.
    public func position(of id: ClipItem.ID, filter: ClipFilter) throws -> Int? {
        try ClipboardStore.position(in: db, of: id, filter: filter)
    }
}

/// Random access to a list of any length, loading fixed-size pages on demand and keeping a
/// bounded number of them. Built from a `HistoryLayout`; rebuild it when history changes.
///
/// Sequential pages are fetched by key (constant cost at any depth); jumps use an offset.
public final class HistoryPager {
    public static let pageSize = 200
    static let maxCachedPages = 40

    public let filter: ClipFilter
    public let count: Int
    private let reader: HistoryReader
    private var pages: [Int: HistoryPage] = [:]
    /// Page fetches performed (not counting the first page), for tests and diagnostics.
    public private(set) var fetches = 0

    public init(reader: HistoryReader, filter: ClipFilter, layout: HistoryLayout) {
        self.reader = reader
        self.filter = filter
        count = layout.total
        if !layout.firstPage.isEmpty {
            pages[0] = HistoryPage(items: layout.firstPage, lastKey: layout.firstPageLastKey)
        }
    }

    /// The entry at `index`, or `nil` past the end (or if history changed underneath and the row
    /// is gone; the next rebuild fixes that).
    public func item(at index: Int) -> ClipItem? {
        guard index >= 0, index < count else { return nil }
        let number = index / Self.pageSize
        let page = pages[number] ?? load(number)
        let offset = index % Self.pageSize
        guard let page, offset < page.items.count else { return nil }
        return page.items[offset]
    }

    /// Index of an entry: from the loaded pages if possible, otherwise asked of the database.
    public func index(of id: ClipItem.ID) -> Int? {
        for (number, page) in pages {
            if let offset = page.items.firstIndex(where: { $0.id == id }) {
                return number * Self.pageSize + offset
            }
        }
        guard let position = try? reader.position(of: id, filter: filter), position < count else { return nil }
        return position
    }

    private func load(_ number: Int) -> HistoryPage? {
        fetches += 1
        let previous = pages[number - 1]
        let page: HistoryPage?
        if let previous, previous.items.count == Self.pageSize, let key = previous.lastKey {
            page = try? reader.page(filter: filter, after: key)
        } else {
            page = try? reader.page(filter: filter, after: nil, offset: number * Self.pageSize)
        }
        guard let page else { return nil }
        pages[number] = page
        if pages.count > Self.maxCachedPages {
            // Drop the page farthest from where the list is now.
            if let farthest = pages.keys.max(by: { abs($0 - number) < abs($1 - number) }) {
                pages[farthest] = nil
            }
        }
        return page
    }
}
