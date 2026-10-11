import XCTest
@testable import PastyCore

final class ClipboardStoreTests: XCTestCase {
    private func makeStore() throws -> ClipboardStore {
        try ClipboardStore(url: nil)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PastyTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    func testInsertAndFetchNewestFirst() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try await store.insert(.text("first", date: base))
        try await store.insert(.text("second", date: base.addingTimeInterval(1)))
        try await store.insert(.text("third", date: base.addingTimeInterval(2)))

        let items = try await store.items()
        XCTAssertEqual(items.map(\.title), ["third", "second", "first"])
        XCTAssertEqual(items.first?.kind, .text)
    }

    func testUsesTrigramIndexWhenAvailable() throws {
        let store = try makeStore()
        // macOS's system SQLite ships FTS5 with the trigram tokenizer (3.34+).
        XCTAssertEqual(store.searchIndexMode, .trigram)
    }

    // MARK: Duplicates

    func testMoveToTopDeduplicatesAndBumps() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let first = try await store.insert(.text("hello", date: base), duplicates: .moveToTop)
        try await store.insert(.text("other", date: base.addingTimeInterval(1)), duplicates: .moveToTop)
        let again = try await store.insert(.text("hello", date: base.addingTimeInterval(2)), duplicates: .moveToTop)

        XCTAssertEqual(again, .updated(first.itemID!))
        let items = try await store.items()
        XCTAssertEqual(items.map(\.title), ["hello", "other"])
        XCTAssertEqual(items.first?.copyCount, 2)
    }

    func testIgnoreConsecutiveOnlySkipsImmediateRepeat() async throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        try await store.insert(.text("a", date: base), duplicates: .ignoreConsecutive)
        let repeatOutcome = try await store.insert(.text("a", date: base.addingTimeInterval(1)), duplicates: .ignoreConsecutive)
        try await store.insert(.text("b", date: base.addingTimeInterval(2)), duplicates: .ignoreConsecutive)
        try await store.insert(.text("a", date: base.addingTimeInterval(3)), duplicates: .ignoreConsecutive)

        XCTAssertEqual(repeatOutcome, .skipped)
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["a", "b", "a"])
    }

    func testKeepAllRecordsEveryCopy() async throws {
        let store = try makeStore()
        for offset in 0..<3 {
            try await store.insert(.text("same", date: Date(timeIntervalSince1970: Double(offset))), duplicates: .keepAll)
        }
        let count = try await store.count()
        XCTAssertEqual(count, 3)
    }

    // MARK: Retention & pinning

    func testRetentionDeletesOldestUnpinnedButKeepsPinned() async throws {
        let store = try makeStore()
        let pinned = try await store.insert(.text("keep me", date: Date(timeIntervalSince1970: 0)), maxHistory: 3)
        try await store.setPinned(true, for: pinned.itemID!)
        for index in 1...10 {
            try await store.insert(.text("item \(index)", date: Date(timeIntervalSince1970: Double(index))), maxHistory: 3)
        }
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["item 10", "item 9", "item 8", "keep me"])
    }

    func testPinAndUnpin() async throws {
        let store = try makeStore()
        let id = try await store.insert(.text("pin")).itemID!
        try await store.insert(.text("not pinned"))

        try await store.setPinned(true, for: id)
        var pinned = try await store.items(filter: .pinned)
        XCTAssertEqual(pinned.map(\.id), [id])
        XCTAssertTrue(pinned[0].isPinned)

        try await store.setPinned(false, for: id)
        pinned = try await store.items(filter: .pinned)
        XCTAssertTrue(pinned.isEmpty)
    }

    func testClearKeepsPinnedWhenAsked() async throws {
        let store = try makeStore()
        let id = try await store.insert(.text("pinned")).itemID!
        try await store.setPinned(true, for: id)
        try await store.insert(.text("loose"))

        try await store.clear(keepPinned: true)
        var titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["pinned"])

        try await store.clear(keepPinned: false)
        titles = try await store.items().map(\.title)
        XCTAssertTrue(titles.isEmpty)
    }

    func testDeleteRemovesItemRepresentationsAndIndex() async throws {
        let store = try makeStore()
        let id = try await store.insert(.text("delete me please")).itemID!
        try await store.delete(id)
        let snapshot = try await store.snapshot(for: id)
        let results = try await store.search("delete")
        XCTAssertNil(snapshot)
        XCTAssertTrue(results.isEmpty)
    }

    func testMarkUsedMovesToTop() async throws {
        let store = try makeStore()
        let old = try await store.insert(.text("old", date: Date(timeIntervalSince1970: 0))).itemID!
        try await store.insert(.text("new", date: Date(timeIntervalSince1970: 10)))
        try await store.markUsed(old, at: Date(timeIntervalSince1970: 20))
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["old", "new"])
    }

    // MARK: Persistence

    func testHistorySurvivesReopen() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            let store = try ClipboardStore(url: url)
            let id = try await store.insert(.text("persisted")).itemID!
            try await store.setPinned(true, for: id)
        }
        let reopened = try ClipboardStore(url: url)
        let items = try await reopened.items()
        XCTAssertEqual(items.map(\.title), ["persisted"])
        XCTAssertTrue(items[0].isPinned)
        let found = try await reopened.search("persist")
        XCTAssertEqual(found.count, 1)
    }

    func testDatabaseUsesWAL() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try ClipboardStore(url: url)
        try await store.insert(.text("wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
    }

    func testCorruptDatabaseIsMovedAsideAndRecreated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 8_192).write(to: url)

        let store = try ClipboardStore.openRecovering(at: url)
        try await store.insert(.text("fresh start"))
        let count = try await store.count()
        XCTAssertEqual(count, 1)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.contains(".corrupt-") })
    }

    // MARK: Serialization

    func testRepresentationsRoundTripExactly() async throws {
        let store = try makeStore()
        let rtf = Data("{\\rtf1\\ansi {\\b bold} text}".utf8)
        let custom = Data([0, 1, 2, 3, 255])
        let snapshot = PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardType.rtf, data: rtf),
                PasteboardRepresentation(type: PasteboardType.string, data: Data("bold text".utf8)),
                PasteboardRepresentation(type: "com.example.custom", data: custom),
            ]),
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardType.string, data: Data("second item".utf8)),
            ]),
        ])
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot))
        XCTAssertEqual(draft.kind, .richText)
        let id = try await store.insert(draft).itemID!
        let restored = try await store.snapshot(for: id)
        XCTAssertEqual(restored, snapshot)
    }

    func testVeryLargeTextIsStoredAndSearchable() async throws {
        let store = try makeStore()
        let large = String(repeating: "lorem ipsum dolor sit amet ", count: 200_000) + "needle-at-the-end"
        let draft = ClipDraft.text(large)
        XCTAssertEqual(draft.preview.count, ContentAnalyzer.previewLimit)
        let id = try await store.insert(draft).itemID!
        let restored = try await store.snapshot(for: id)
        XCTAssertEqual(restored?.plainText?.utf8.count, large.utf8.count)
        // Content beyond the index cap is intentionally not searchable; early content is.
        let found = try await store.search("ipsum dolor")
        XCTAssertEqual(found.map(\.id), [id])
    }
}
