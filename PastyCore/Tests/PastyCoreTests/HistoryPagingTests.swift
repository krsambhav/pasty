import XCTest
@testable import PastyCore

/// The paged list behind the panel: layout, key-based paging, positions, and the cached
/// retention count.
final class HistoryPagingTests: XCTestCase {
    private func seeded(_ count: Int, sameDate: Bool = false, pinEvery: Int = 0) async throws -> ClipboardStore {
        let store = try ClipboardStore(url: nil)
        var batch: [ImportedClip] = []
        for index in 0..<count {
            let date = Date(timeIntervalSince1970: sameDate ? 1_000_000 : 1_000_000 + Double(index))
            batch.append(ImportedClip(draft: .text("entry \(index)", date: date), firstCopiedAt: date, copyCount: 1,
                                      pinned: pinEvery > 0 && index % pinEvery == 0))
        }
        _ = try await store.importClips(batch)
        return store
    }

    func testPagerMatchesFullListing() async throws {
        let store = try await seeded(1_050)
        let layout = try await store.layout()
        XCTAssertEqual(layout.total, 1_050)
        XCTAssertEqual(layout.firstPage.count, HistoryPager.pageSize)
        let pager = HistoryPager(reader: try store.makeReader(), filter: .all, layout: layout)
        let expected = try await store.items(limit: -1).map(\.id)
        XCTAssertEqual((0..<pager.count).compactMap { pager.item(at: $0)?.id }, expected)
        XCTAssertNil(pager.item(at: pager.count))
        XCTAssertNil(pager.item(at: -1))
        // Pages after the first were fetched by key, one each.
        XCTAssertEqual(pager.fetches, 5)
    }

    func testReaderReadsSnapshotsLikeTheStore() async throws {
        let store = try await seeded(3)
        let reader = try store.makeReader()
        let first = try await store.items().first
        let id = try XCTUnwrap(first?.id)
        let fromStore = try await store.snapshot(for: id)
        XCTAssertNotNil(fromStore)
        XCTAssertEqual(try reader.snapshot(for: id), fromStore)
        XCTAssertNil(try reader.snapshot(for: -1))
    }

    func testPagingIsExactWhenDatesTie() async throws {
        let store = try await seeded(450, sameDate: true)
        let pager = HistoryPager(reader: try store.makeReader(), filter: .all, layout: try await store.layout())
        let ids = (0..<pager.count).compactMap { pager.item(at: $0)?.id }
        XCTAssertEqual(ids.count, 450)
        XCTAssertEqual(Set(ids).count, 450, "no entry skipped or repeated across page boundaries")
        XCTAssertEqual(ids, ids.sorted(by: >), "ties break by id, newest first")
    }

    func testRandomAccessAndPositions() async throws {
        let store = try await seeded(2_000)
        let reader = try store.makeReader()
        let pager = HistoryPager(reader: reader, filter: .all, layout: try await store.layout())
        // Jump deep (offset), then step back and forth.
        let deep = try XCTUnwrap(pager.item(at: 1_777))
        XCTAssertEqual(deep.title, "entry 222")
        XCTAssertEqual(pager.item(at: 1_776)?.title, "entry 223")
        XCTAssertEqual(pager.index(of: deep.id), 1_777)
        // Not in a loaded page: asked of the database.
        let fresh = HistoryPager(reader: reader, filter: .all, layout: try await store.layout())
        XCTAssertEqual(fresh.index(of: deep.id), 1_777)
        XCTAssertNil(fresh.index(of: 999_999))
    }

    func testPinnedLayoutAndPaging() async throws {
        let store = try await seeded(1_000, pinEvery: 3)
        let layout = try await store.layout(filter: .pinned)
        XCTAssertEqual(layout.total, 334)
        XCTAssertEqual(layout.sections, [ListSection(title: "Pinned", start: 0, count: 334)])
        let pager = HistoryPager(reader: try store.makeReader(), filter: .pinned, layout: layout)
        let items = (0..<pager.count).compactMap { pager.item(at: $0) }
        XCTAssertEqual(items.count, 334)
        XCTAssertTrue(items.allSatisfy(\.isPinned))
        XCTAssertEqual(pager.index(of: items[300].id), 300)
    }

    func testDateSectionsFromCounts() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try ClipboardStore(url: nil)
        let agos: [TimeInterval] = [60, 3_600, 86_400 * 1.2, 86_400 * 3, 86_400 * 30, -500]
        for (index, ago) in agos.enumerated() {
            try await store.insert(.text("item \(index)", date: now.addingTimeInterval(-ago)), duplicates: .keepAll)
        }
        let layout = try await store.layout(now: now, calendar: calendar)
        XCTAssertEqual(layout.sections.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
        XCTAssertEqual(layout.sections.map(\.count), [3, 1, 1, 1])
        XCTAssertEqual(layout.sections.map(\.start), [0, 3, 4, 5])
        let empty = try await ClipboardStore(url: nil).layout()
        XCTAssertEqual(empty.total, 0)
        XCTAssertTrue(empty.sections.isEmpty)
    }

    func testRetentionWithCachedCountStaysExact() async throws {
        let store = try ClipboardStore(url: nil)
        var pinnedID: ClipItem.ID?
        for index in 0..<30 {
            let id = try await store.insert(.text("item \(index)", date: Date(timeIntervalSince1970: Double(index))), maxHistory: 10).itemID
            if index == 0 { pinnedID = id }
            if index == 0, let id { try await store.setPinned(true, for: id) }
            if index == 15 { try await store.delete(try await store.items(limit: 1)[0].id) }
        }
        var unpinned = try await store.unpinnedCount()
        XCTAssertEqual(unpinned, 10)
        let pinnedStillThere = try await store.item(pinnedID!)
        XCTAssertNotNil(pinnedStillThere)
        // Lowering the limit trims in batches from the oldest end.
        try await store.enforceLimit(maxHistory: 3)
        unpinned = try await store.unpinnedCount()
        XCTAssertEqual(unpinned, 3)
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["item 29", "item 28", "item 27", "item 0"])
    }

    func testClearKeepsPinnedAndRebuildsTheIndex() async throws {
        let store = try await seeded(500, pinEvery: 100)
        try await store.clear(keepPinned: true)
        var count = try await store.count()
        XCTAssertEqual(count, 5)
        let found = try await store.search("entry 400")
        XCTAssertEqual(found.first?.title, "entry 400", "pinned entries stay searchable")
        let snapshot = try await store.snapshot(for: found[0].id)
        XCTAssertNotNil(snapshot, "and keep their contents")
        try await store.insert(.text("after clear"))
        let afterClear = try await store.search("after clear")
        XCTAssertEqual(afterClear.count, 1)
        try await store.delete(afterClear[0].id)
        let deleted = try await store.search("after clear")
        XCTAssertTrue(deleted.isEmpty, "the delete trigger was recreated")
        try await store.clear(keepPinned: false)
        count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testSearchFindsOldEntriesUsedRecently() async throws {
        // More matches than the candidate cap: the oldest entry is only found because it was
        // used (moved to the top) recently.
        let store = try ClipboardStore(url: nil)
        let base = Date(timeIntervalSince1970: 1_000_000)
        var batch: [ImportedClip] = []
        batch.append(ImportedClip(draft: .text("needle zebra original", date: base), firstCopiedAt: base, copyCount: 1, pinned: false))
        for index in 1...(ClipboardStore.searchCandidateLimit + 200) {
            let date = base.addingTimeInterval(Double(index))
            batch.append(ImportedClip(draft: .text("needle \(index)", date: date), firstCopiedAt: date, copyCount: 1, pinned: false))
        }
        _ = try await store.importClips(batch)
        let oldest = try await store.search("zebra")
        XCTAssertEqual(oldest.count, 1)
        try await store.markUsed(oldest[0].id, at: base.addingTimeInterval(100_000))
        let results = try await store.search("needle")
        XCTAssertTrue(results.contains { $0.id == oldest[0].id })
    }

    func testReaderSeesNewWrites() async throws {
        let store = try await seeded(10)
        let reader = try store.makeReader()
        try await store.insert(.text("newest", date: Date(timeIntervalSince1970: 2_000_000)))
        let page = try reader.page(filter: .all, after: nil)
        XCTAssertEqual(page.items.first?.title, "newest")
        XCTAssertEqual(page.items.count, 11)
    }
}
