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
