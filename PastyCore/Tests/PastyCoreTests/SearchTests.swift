import XCTest
@testable import PastyCore

final class SearchTests: XCTestCase {
    private func store(with texts: [String]) async throws -> ClipboardStore {
        let store = try ClipboardStore(url: nil)
        for (offset, text) in texts.enumerated() {
            try await store.insert(.text(text, date: Date(timeIntervalSince1970: Double(offset))), duplicates: .keepAll)
        }
        return store
    }

    func testCaseInsensitiveSubstringMatch() async throws {
        let store = try await store(with: ["Hello World", "goodbye", "WORLDWIDE web"])
        let results = try await store.search("world").map(\.title)
        XCTAssertEqual(Set(results), ["Hello World", "WORLDWIDE web"])
    }

    func testPartialMatchInsideWord() async throws {
        let store = try await store(with: ["configuration.yaml", "readme"])
        let results = try await store.search("figur").map(\.title)
        XCTAssertEqual(results, ["configuration.yaml"])
    }

    func testShortQueriesUseFallbackMatching() async throws {
        let store = try await store(with: ["ab cd", "xyz", "abc"])
        let one = try await store.search("x").map(\.title)
        XCTAssertEqual(one, ["xyz"])
        let two = try await store.search("ab").map(\.title)
        XCTAssertEqual(Set(two), ["ab cd", "abc"])
    }

    func testMultipleTermsMustAllMatch() async throws {
        let store = try await store(with: ["swift concurrency actors", "swift ui", "rust actors"])
        let results = try await store.search("actors swift").map(\.title)
        XCTAssertEqual(results, ["swift concurrency actors"])
    }

    func testExactBeatsPrefixBeatsWordBeatsSubstring() async throws {
        // Inserted oldest → newest; recency alone would reverse this order.
        let store = try await store(with: [
            "token",
            "token refresh flow",
            "the token is here",
            "mytokenizer",
        ])
        let results = try await store.search("token").map(\.title)
        XCTAssertEqual(results, ["token", "token refresh flow", "the token is here", "mytokenizer"])
    }

    func testRecencyBreaksTies() async throws {
        let store = try await store(with: ["note alpha", "note beta"])
        let results = try await store.search("note").map(\.title)
        XCTAssertEqual(results, ["note beta", "note alpha"])
    }

    func testSearchesSourceAppMetadata() async throws {
        let store = try ClipboardStore(url: nil)
        try await store.insert(.text("unrelated words", source: SourceApp(bundleID: "com.apple.Safari", name: "Safari")))
        try await store.insert(.text("other words"))
        let results = try await store.search("safari").map(\.title)
        XCTAssertEqual(results, ["unrelated words"])
    }

    func testSearchesFileNames() async throws {
        let store = try ClipboardStore(url: nil)
        let snapshot = PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardType.fileURL, data: Data("file:///Users/me/Documents/Quarterly%20Report.pdf".utf8)),
            ]),
        ])
        try await store.insert(XCTUnwrap(ContentAnalyzer.analyze(snapshot)))
        let results = try await store.search("quarterly")
        XCTAssertEqual(results.first?.kind, .file)
        XCTAssertEqual(results.first?.title, "Quarterly Report.pdf")
    }

    func testPinnedFilterAppliesToSearch() async throws {
        let store = try await store(with: ["apple pie", "apple tart"])
        let tart = try await store.search("tart")[0]
        try await store.setPinned(true, for: tart.id)
        let results = try await store.search("apple", filter: .pinned).map(\.title)
        XCTAssertEqual(results, ["apple tart"])
    }

    func testSpecialCharactersAreSafe() async throws {
        let store = try await store(with: ["100% done", "a_b", "say \"hi\"", "path\\to"])
        let percent = try await store.search("%").map(\.title)
        XCTAssertEqual(percent, ["100% done"])
        let underscore = try await store.search("_").map(\.title)
        XCTAssertEqual(underscore, ["a_b"])
        let quotes = try await store.search("\"hi\"").map(\.title)
        XCTAssertEqual(quotes, ["say \"hi\""])
        let operators = try await store.search("AND OR NOT").map(\.title)
        XCTAssertTrue(operators.isEmpty)
    }

    func testEmptyQueryReturnsEverything() async throws {
        let store = try await store(with: ["one", "two"])
        let results = try await store.search("   ")
        XCTAssertEqual(results.count, 2)
    }

    func testHighlightRangesMergeAndIgnoreCase() {
        let text = "Hello hello HELLO world"
        let ranges = SearchRanker.highlightRanges(in: text, query: SearchQuery("hello"))
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Hello", "hello", "HELLO"])

        let overlapping = SearchRanker.highlightRanges(in: "abcdef", query: SearchQuery("abc bcd"))
        XCTAssertEqual(overlapping.count, 1)
        XCTAssertEqual(String("abcdef"[overlapping[0]]), "abcd")
    }

    func testQueryNormalization() {
        let query = SearchQuery("  Foo   BAR foo ")
        XCTAssertEqual(query.phrase, "foo   bar foo")
        XCTAssertEqual(query.tokens, ["foo", "bar"])
    }
}
