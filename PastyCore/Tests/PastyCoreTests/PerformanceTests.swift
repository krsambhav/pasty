import XCTest
@testable import PastyCore

/// Benchmarks against a 10,000-entry history. Numbers are printed with a `[benchmark]` prefix so
/// CI logs double as a performance record; assertions use generous ceilings to catch regressions
/// without flaking on slow shared runners.
final class PerformanceTests: XCTestCase {
    private static let words = """
    swift actor clipboard history panel search index pasteboard window shortcut keyboard image \
    preview thumbnail sqlite query render layout focus monitor privacy settings token release build \
    network design system palette motion contrast display screen memory latency cache archive
    """.split(separator: " ").map(String.init)

    private func populatedStore(count: Int) async throws -> (ClipboardStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PastyBench-\(UUID().uuidString)")
            .appendingPathComponent("history.sqlite")
        let store = try ClipboardStore(url: url)
        var generator = SystemRandomNumberGenerator()
        let start = Date()
        for index in 0..<count {
            let length = Int.random(in: 8...80, using: &generator)
            let text = (0..<length).map { _ in Self.words.randomElement(using: &generator)! }.joined(separator: " ")
            try await store.insert(.text("\(index) \(text)", date: Date(timeIntervalSince1970: Double(index))), duplicates: .keepAll, maxHistory: 100_000)
        }
        let elapsed = Date().timeIntervalSince(start)
        print("[benchmark] insert \(count) entries: \(Int(elapsed * 1_000)) ms (\(String(format: "%.2f", elapsed * 1_000 / Double(count))) ms/entry)")
        return (store, url)
    }

    private func time<T>(_ label: String, iterations: Int = 20, _ body: () async throws -> T) async rethrows -> Double {
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
        print("[benchmark] \(label): median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms")
        return median
    }

    func testTenThousandEntryHistory() async throws {
        let (store, url) = try await populatedStore(count: 10_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let listMedian = try await time("load full list (10k)") { try await store.items() }
        XCTAssertLessThan(listMedian, 250)

        var worst = 0.0
        for query in ["sw", "clip", "keyboard", "thumbnail sqlite", "zzzz-nothing", "9999"] {
            let median = try await time("search \"\(query)\"") { try await store.search(query) }
            worst = max(worst, median)
        }
        XCTAssertLessThan(worst, 150, "search should stay interactive even on slow CI machines")

        let pinnedMedian = try await time("pinned filter") { try await store.items(filter: .pinned) }
        XCTAssertLessThan(pinnedMedian, 50)
    }
}

/// Very large single entries: 10,000 lines of code, 10 MB of minified text.
final class LargeEntryPerformanceTests: XCTestCase {
    static func code(lines: Int) -> String {
        (0..<lines).map { index in
            switch index % 5 {
            case 0: "func handler\(index)(request: Request) async throws -> Response {"
            case 1: "    let value\(index) = try await service.fetch(id: \(index), retries: 3)"
            case 2: "    guard value\(index).isValid else { throw APIError.invalid(\"\(index)\") }"
            case 3: "    return Response(status: .ok, body: value\(index).encoded())"
            default: "}"
            }
        }.joined(separator: "\n") + "\n// final-marker-line"
    }

    private func ms(_ start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    func testTenThousandLinesOfCode() async throws {
        let code = Self.code(lines: 10_000)
        print("[benchmark] 10k-line code size: \(code.utf8.count / 1_024) KB")
        let snapshot = PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: PasteboardType.string, data: Data(code.utf8)),
        ])])

        var start = DispatchTime.now()
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot))
        let analyze = ms(start)
        print("[benchmark] analyze 10k-line code: \(String(format: "%.1f", analyze)) ms")
        XCTAssertTrue(draft.isCode)
        XCTAssertEqual(draft.lineCount, 10_001)
        XCTAssertEqual(draft.searchContent.utf16.count, code.utf16.count, "the whole file is searchable")
        XCTAssertLessThan(analyze, 250)

        let store = try ClipboardStore(url: nil)
        for index in 0..<200 { try await store.insert(.text("filler entry \(index)")) }
        start = .now()
        let id = try await store.insert(draft).itemID!
        let insert = ms(start)
        print("[benchmark] insert 10k-line code (with full-text index): \(String(format: "%.1f", insert)) ms")
        XCTAssertLessThan(insert, 1_500)

        start = .now()
        let hits = try await store.search("final-marker-line")
        let search = ms(start)
        print("[benchmark] search inside 10k-line code (last line): \(String(format: "%.1f", search)) ms")
        XCTAssertEqual(hits.first?.id, id)
        XCTAssertLessThan(search, 100)

        start = .now()
        let list = try await store.items()
        print("[benchmark] list load with a 10k-line entry: \(String(format: "%.1f", ms(start))) ms")
        XCTAssertEqual(list.first?.title.count ?? 0 <= ContentAnalyzer.titleLimit, true)

        start = .now()
        let restored = try await store.snapshot(for: id)
        print("[benchmark] load 10k-line code for paste: \(String(format: "%.1f", ms(start))) ms")
        XCTAssertEqual(restored?.plainText, code)
    }

    func testHugeSingleLineText() async throws {
        let line = String(repeating: "aZ9+/", count: 2_000_000) // 10 MB, no newlines (minified/base64)
        let snapshot = PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: PasteboardType.string, data: Data(line.utf8)),
        ])])
        let start = DispatchTime.now()
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot))
        print("[benchmark] analyze 10 MB single line: \(String(format: "%.1f", ms(start))) ms")
        XCTAssertEqual(draft.title.count, ContentAnalyzer.titleLimit)
        XCTAssertEqual(draft.lineCount, 1)
        let store = try ClipboardStore(url: nil)
        let insertStart = DispatchTime.now()
        try await store.insert(draft)
        print("[benchmark] insert 10 MB single line: \(String(format: "%.1f", ms(insertStart))) ms")
    }

    func testPastedWallOfTextAsQueryIsBounded() async throws {
        let store = try ClipboardStore(url: nil)
        try await store.insert(.text("func handler1(request: Request)"))
        let query = Self.code(lines: 2_000)
        let parsed = SearchQuery(query)
        XCTAssertLessThanOrEqual(parsed.tokens.count, SearchQuery.maxTokens)
        XCTAssertLessThanOrEqual(parsed.phrase.count, SearchQuery.maxPhraseLength)
        let start = DispatchTime.now()
        _ = try await store.search(query)
        print("[benchmark] search with a pasted 2,000-line query: \(String(format: "%.1f", ms(start))) ms")
        XCTAssertLessThan(ms(start), 200)
    }
}
