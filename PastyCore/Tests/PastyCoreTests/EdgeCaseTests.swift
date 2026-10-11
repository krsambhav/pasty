import AppKit
import XCTest
@testable import PastyCore

/// Boundary conditions and hostile inputs across analysis, storage, search and capture.
final class ContentEdgeCaseTests: XCTestCase {
    private func snapshot(_ reps: [(String, Data)]) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: reps.map { PasteboardRepresentation(type: $0.0, data: $0.1) })])
    }

    private func text(_ string: String) -> PasteboardSnapshot {
        snapshot([(PasteboardType.string, Data(string.utf8))])
    }

    func testEmptySnapshotIsIgnored() {
        XCTAssertNil(ContentAnalyzer.analyze(PasteboardSnapshot(items: [])))
        XCTAssertNil(ContentAnalyzer.analyze(PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [])])))
        XCTAssertNil(ContentAnalyzer.analyze(text("")))
    }

    func testEmojiCombiningAndRTLText() throws {
        for sample in ["👩‍👩‍👧‍👦 family", "e\u{301}cole", "مرحبا بالعالم", "日本語のテキスト", "🇮🇳🇯🇵"] {
            let draft = try XCTUnwrap(ContentAnalyzer.analyze(text(sample)), sample)
            XCTAssertEqual(draft.title, sample)
            XCTAssertEqual(draft.kind, .text)
        }
        XCTAssertEqual(try XCTUnwrap(ContentAnalyzer.analyze(text("👩‍👩‍👧‍👦"))).characterCount, 1)
    }

    func testWindowsLineEndingsAndLeadingBlankLines() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(text("\r\n\r\n   first line\r\nsecond")))
        XCTAssertEqual(draft.title, "first line")
    }

    func testTabsAndNonBreakingSpacesCollapse() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(text("a\t\tb\u{00A0}\u{00A0}c")))
        XCTAssertEqual(draft.title, "a b c")
    }

    func testNullBytesAreKept() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(text("before\u{0}after")))
        XCTAssertTrue(draft.preview.contains("after"))
    }

    func testInvalidUTF8WithoutOtherTypesIsKeptAsData() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, Data([0xFF, 0xFE, 0xFD]))])))
        XCTAssertEqual(draft.kind, .other)
    }

    func testRTFOnlyContentIsReadable() throws {
        let attributed = NSAttributedString(string: "Only rich", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.rtf, rtf)])))
        XCTAssertEqual(draft.kind, .richText)
        XCTAssertEqual(draft.title, "Only rich")
        XCTAssertEqual(draft.snapshot.plainTextOnly()?.plainText, "Only rich")
    }

    func testHTMLOnlyContentIsReadable() throws {
        let html = "<html><style>p{color:red}</style><body><p>Hello &amp; welcome</p><script>alert(1)</script><p>Line&nbsp;two</p></body></html>"
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.html, Data(html.utf8))])))
        XCTAssertEqual(draft.kind, .richText)
        XCTAssertEqual(draft.title, "Hello & welcome")
        XCTAssertFalse(draft.preview.contains("alert"))
        XCTAssertFalse(draft.preview.contains("color:red"))
        XCTAssertTrue(draft.preview.contains("Line two"))
    }

    func testPDFAndPrivateTypesAreKeptAsData() throws {
        let pdf = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.pdf, Data("%PDF-1.4".utf8))])))
        XCTAssertEqual(pdf.kind, .other)
        XCTAssertEqual(pdf.title, "PDF content")

        let custom = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([("com.figma.layers", Data([1, 2, 3]))])))
        XCTAssertEqual(custom.kind, .other)
        XCTAssertEqual(custom.subtitle, "com.figma.layers")

        let same = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([("com.figma.layers", Data([1, 2, 3]))])))
        let different = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([("com.figma.layers", Data([9]))])))
        XCTAssertEqual(custom.contentHash, same.contentHash)
        XCTAssertNotEqual(custom.contentHash, different.contentHash)
    }

    func testOnlyOpaqueDynTypesAreIgnored() {
        XCTAssertNil(ContentAnalyzer.analyze(snapshot([("dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu", Data([1]))])))
    }

    func testCorruptImageDataDoesNotCrash() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.png, Data("not an image".utf8))])))
        XCTAssertEqual(draft.kind, .image)
        XCTAssertEqual(draft.title, "Image")
        XCTAssertNil(draft.thumbnail)
        XCTAssertEqual(draft.imageWidth, 0)
    }

    func testTIFFOnlyImage() throws {
        let png = try TestImages.png(width: 64, height: 32)
        let tiff = try XCTUnwrap(NSBitmapImageRep(data: png)?.tiffRepresentation)
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.tiff, tiff)])))
        XCTAssertEqual(draft.kind, .image)
        XCTAssertEqual(draft.imageWidth, 64)
        XCTAssertNotNil(draft.thumbnail)
    }

    func testTinyImageThumbnailIsNotUpscaled() throws {
        let png = try TestImages.png(width: 4, height: 4)
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.png, png)])))
        let size = try XCTUnwrap(ImageTools.pixelSize(of: XCTUnwrap(draft.thumbnail)))
        XCTAssertLessThanOrEqual(size.width, 4)
    }

    func testTextWithImageIsText() throws {
        // Spreadsheet cells put text, rich text and an image on the pasteboard together.
        let png = try TestImages.png(width: 10, height: 10)
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([
            (PasteboardType.string, Data("A1\tB1".utf8)),
            (PasteboardType.html, Data("<table></table>".utf8)),
            (PasteboardType.png, png),
        ])))
        XCTAssertEqual(draft.kind, .richText)
    }

    func testURLEdgeCases() {
        XCTAssertNotNil(ContentAnalyzer.detectURL(in: "  https://example.com/a?b=c#d  "))
        XCTAssertNotNil(ContentAnalyzer.detectURL(in: "http://localhost:8080/path"))
        XCTAssertNotNil(ContentAnalyzer.detectURL(in: "https://例え.jp/パス"))
        XCTAssertNil(ContentAnalyzer.detectURL(in: "https://"))
        XCTAssertNil(ContentAnalyzer.detectURL(in: "javascript:alert(1)"))
        XCTAssertNil(ContentAnalyzer.detectURL(in: "https://a.com\nhttps://b.com"))
        XCTAssertNil(ContentAnalyzer.detectURL(in: String(repeating: "a", count: 5_000)))
    }

    func testFileURLWithSpacesAndUnicode() throws {
        let url = URL(fileURLWithPath: "/Users/me/Résumé Final (2).pdf")
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.fileURL, Data(url.absoluteString.utf8))])))
        XCTAssertEqual(draft.title, "Résumé Final (2).pdf")
        XCTAssertEqual(draft.filePath, "/Users/me/Résumé Final (2).pdf")
    }

    func testHexColors() {
        XCTAssertEqual(HexColor("#fff")?.red, 1)
        XCTAssertEqual(HexColor("#5B5BD6")?.cssDescription, "rgb(91, 91, 214)")
        XCTAssertEqual(HexColor("#00000080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertEqual(HexColor("  #ABC  ")?.blue, 1.0 * 0xCC / 255)
        XCTAssertNil(HexColor("fff"))
        XCTAssertNil(HexColor("#ggg"))
        XCTAssertNil(HexColor("#12345"))
        XCTAssertNil(HexColor("#１２３")) // full-width digits
    }

    func testRelativeTimeEdges() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(3_600), now: now, calendar: calendar), "now", "future dates (clock changes) read as now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-59), now: now, calendar: calendar), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-60), now: now, calendar: calendar), "1m")
        let lastYear = now.addingTimeInterval(-86_400 * 400)
        XCTAssertFalse(RelativeTime.short(lastYear, now: now, calendar: calendar).isEmpty)
    }

    func testHistorySections() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ id: Int64, _ ago: TimeInterval) -> ClipItem {
            ClipItem(id: id, kind: .text, title: "\(id)", createdAt: now, updatedAt: now.addingTimeInterval(-ago))
        }
        let sections = HistorySections.byDate([
            item(1, 60), item(2, 3_600), item(3, 86_400 * 1.2), item(4, 86_400 * 3), item(5, 86_400 * 30), item(6, -500),
        ], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Earlier"])
        XCTAssertEqual(sections[0].items.map(\.id), [1, 2, 6])
        XCTAssertTrue(HistorySections.byDate([], now: now).isEmpty)
    }

    func testKeyComboDisplay() {
        let all = KeyCombo(keyCode: 9, modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        XCTAssertEqual(all.modifierSymbols, "⌃⌥⇧⌘")
    }
}

final class StoreEdgeCaseTests: XCTestCase {
    func testOperationsOnMissingIDsAreHarmless() async throws {
        let store = try ClipboardStore(url: nil)
        try await store.delete(999)
        try await store.setPinned(true, for: 999)
        try await store.markUsed(999)
        let snapshot = try await store.snapshot(for: 999)
        let preview = try await store.preview(for: 999)
        let thumbnail = try await store.thumbnail(for: 999)
        let item = try await store.item(999)
        XCTAssertNil(snapshot)
        XCTAssertNil(preview)
        XCTAssertNil(thumbnail)
        XCTAssertNil(item)
        try await store.clear(keepPinned: true)
        let count = try await store.count()
        XCTAssertEqual(count, 0)
    }

    func testZeroLimitKeepsOnlyPinned() async throws {
        let store = try ClipboardStore(url: nil)
        let pinned = try await store.insert(.text("pinned")).itemID!
        try await store.setPinned(true, for: pinned)
        try await store.insert(.text("loose"))
        try await store.enforceLimit(maxHistory: 0)
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["pinned"])
    }

    func testMorePinnedThanLimitAreAllKept() async throws {
        let store = try ClipboardStore(url: nil)
        for index in 0..<5 {
            let id = try await store.insert(.text("pin \(index)"), maxHistory: 2).itemID!
            try await store.setPinned(true, for: id)
        }
        try await store.insert(.text("new"), maxHistory: 2)
        let count = try await store.count()
        let pinned = try await store.count(filter: .pinned)
        XCTAssertEqual(pinned, 5)
        XCTAssertEqual(count, 6)
    }

    func testDuplicateOfPinnedItemBumpsItAndKeepsPin() async throws {
        let store = try ClipboardStore(url: nil)
        let id = try await store.insert(.text("keep", date: Date(timeIntervalSince1970: 0))).itemID!
        try await store.setPinned(true, for: id)
        try await store.insert(.text("other", date: Date(timeIntervalSince1970: 1)))
        let outcome = try await store.insert(.text("keep", date: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(outcome, .updated(id))
        let first = try await store.items().first
        XCTAssertEqual(first?.id, id)
        XCTAssertEqual(first?.isPinned, true)
    }

    func testIgnoreConsecutiveOnEmptyHistoryInserts() async throws {
        let store = try ClipboardStore(url: nil)
        let outcome = try await store.insert(.text("first"), duplicates: .ignoreConsecutive)
        XCTAssertNotNil(outcome.itemID)
    }

    func testConcurrentInsertsAreAllRecorded() async throws {
        let store = try ClipboardStore(url: nil)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { _ = try? await store.insert(.text("concurrent \(index)"), duplicates: .keepAll, maxHistory: 1_000) }
            }
        }
        let count = try await store.count()
        XCTAssertEqual(count, 200)
    }

    func testConcurrentReadsDuringWrites() async throws {
        let store = try ClipboardStore(url: nil)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<200 { try await store.insert(.text("w \(index)"), duplicates: .keepAll) }
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<50 { _ = try await store.search("w 1") }
                }
            }
            try await group.waitForAll()
        }
        let count = try await store.count()
        XCTAssertEqual(count, 200)
    }

    func testHugeBinaryRoundTrip() async throws {
        let store = try ClipboardStore(url: nil)
        let blob = Data((0..<8_000_000).map { UInt8($0 & 0xFF) })
        let snapshot = PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: "com.example.blob", data: blob),
            PasteboardRepresentation(type: "com.example.empty", data: Data()),
        ])])
        let id = try await store.insert(XCTUnwrap(ContentAnalyzer.analyze(snapshot))).itemID!
        let restored = try await store.snapshot(for: id)
        XCTAssertEqual(restored, snapshot)
    }

    func testReopenAfterClearAndVacuum() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PastyEdge-\(UUID().uuidString)/h.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try ClipboardStore(url: url)
            for index in 0..<50 { try await store.insert(.text(String(repeating: "x", count: 10_000) + "\(index)")) }
            try await store.clear(keepPinned: false)
        }
        let reopened = try ClipboardStore(url: url)
        try await reopened.insert(.text("after"))
        let titles = try await reopened.items().map(\.title)
        XCTAssertEqual(titles, ["after"])
    }
}

final class SearchEdgeCaseTests: XCTestCase {
    private func store(_ texts: [String]) async throws -> ClipboardStore {
        let store = try ClipboardStore(url: nil)
        for (offset, text) in texts.enumerated() {
            try await store.insert(.text(text, date: Date(timeIntervalSince1970: Double(offset))), duplicates: .keepAll)
        }
        return store
    }

    func testHostileQueriesNeverThrow() async throws {
        let store = try await store(["normal text", "table items"])
        let hostile = [
            "'; DROP TABLE items; --", "\"", "\"\"\"", "*", "^", "NEAR(a b)", "content:foo", "(", ")", "-", "a OR b",
            "%", "_", "\\", "\u{0}", "🙂", String(repeating: "x", count: 10_000), "   \n\t  ",
        ]
        for query in hostile {
            _ = try await store.search(query)
        }
        let count = try await store.count()
        XCTAssertEqual(count, 2, "nothing was dropped")
        let stillWorks = try await store.search("table").map(\.title)
        XCTAssertEqual(stillWorks, ["table items"])
    }

    func testUnicodeCaseFolding() async throws {
        let store = try await store(["Crème brûlée recipe", "ÉCOLE NORMALE", "plain"])
        let long = try await store.search("crème").map(\.title)
        XCTAssertEqual(long, ["Crème brûlée recipe"])
        let upper = try await store.search("école").map(\.title)
        XCTAssertEqual(upper, ["ÉCOLE NORMALE"])
        let short = try await store.search("é").map(\.title)
        XCTAssertEqual(Set(short), ["Crème brûlée recipe", "ÉCOLE NORMALE"])
    }

    func testCJKAndEmojiSearch() async throws {
        let store = try await store(["日本語のテキスト", "東京タワー", "launch 🚀 day"])
        let two = try await store.search("日本").map(\.title)
        XCTAssertEqual(two, ["日本語のテキスト"])
        let three = try await store.search("テキスト").map(\.title)
        XCTAssertEqual(three, ["日本語のテキスト"])
        let emoji = try await store.search("🚀").map(\.title)
        XCTAssertEqual(emoji, ["launch 🚀 day"])
    }

    func testRepeatedTokensAndMixedCase() async throws {
        let store = try await store(["Mixed CASE Words"])
        let results = try await store.search("mixed MIXED mIxEd").map(\.title)
        XCTAssertEqual(results, ["Mixed CASE Words"])
    }

    func testMatchesBeyondPreviewStillFound() async throws {
        let long = String(repeating: "filler ", count: 1_000) + "deep-needle"
        let store = try await store([long, "short deep-needle"])
        let results = try await store.search("deep-needle").map(\.title)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first, "short deep-needle", "a visible match outranks one buried deep in content")
    }

    func testHighlightRangesWithEmojiAndCombining() {
        let text = "🙂 café CAFÉ cafe\u{301}"
        let ranges = SearchRanker.highlightRanges(in: text, query: SearchQuery("café"))
        XCTAssertEqual(ranges.count, 3)
        XCTAssertTrue(SearchRanker.highlightRanges(in: "", query: SearchQuery("x")).isEmpty)
        XCTAssertTrue(SearchRanker.highlightRanges(in: "abc", query: SearchQuery("")).isEmpty)
    }
}

final class CaptureEdgeCaseTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.pasty.edge.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private func monitor(
        rules: CaptureRules = CaptureRules(),
        source: SourceApp? = nil,
        handler: @escaping ClipboardMonitor.Handler = { _ in }
    ) -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, rules: rules, ownBundleID: "app.pasty.tests", sourceProvider: { _ in source }, handler: handler)
    }

    func testClearedPasteboardIsSkipped() {
        let monitor = self.monitor()
        pasteboard.clearContents()
        guard case .skipped(.empty) = monitor.pollSynchronously() else { return XCTFail("expected empty skip") }
    }

    func testOwnSourceMarkerIsSkippedEvenFromAnotherProcess() {
        let monitor = self.monitor()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("written by an earlier Pasty session", forType: .string)
        item.setString("app.pasty.tests", forType: NSPasteboard.PasteboardType(PasteboardType.source))
        pasteboard.writeObjects([item])
        guard case .skipped = monitor.pollSynchronously() else { return XCTFail("own content recorded") }
    }

    func testUnknownSourceIsNotExcluded() {
        let monitor = self.monitor(rules: CaptureRules(excludedBundleIDs: ["com.example.vault"]), source: SourceApp(bundleID: nil, name: nil))
        pasteboard.clearContents()
        pasteboard.setString("anonymous", forType: .string)
        guard case .captured = monitor.pollSynchronously() else { return XCTFail("expected capture") }
    }

    func testRulesCanChangeAtRuntime() {
        let monitor = self.monitor()
        monitor.updateRules(CaptureRules(captureImages: false))
        pasteboard.clearContents()
        pasteboard.setData(try! TestImages.png(width: 8, height: 8), forType: .png)
        guard case .skipped(.imagesDisabled) = monitor.pollSynchronously() else { return XCTFail("rule not applied") }
        monitor.updateRules(CaptureRules(captureImages: true))
        pasteboard.clearContents()
        pasteboard.setData(try! TestImages.png(width: 8, height: 8), forType: .png)
        guard case .captured = monitor.pollSynchronously() else { return XCTFail("rule not restored") }
    }

    func testUnreplayableAndMarkerTypesAreNotStored() throws {
        let monitor = self.monitor()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("keep", forType: .string)
        item.setString("x", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        item.setString("com.example.app", forType: NSPasteboard.PasteboardType(PasteboardType.source))
        pasteboard.writeObjects([item])
        guard case let .captured(draft) = monitor.pollSynchronously() else { return XCTFail("expected capture") }
        XCTAssertEqual(draft.snapshot.allTypes, [PasteboardType.string])
    }

    func testTenMegabyteTextCapture() throws {
        let monitor = self.monitor()
        let large = String(repeating: "0123456789", count: 1_000_000)
        pasteboard.clearContents()
        pasteboard.setString(large, forType: .string)
        let start = Date()
        guard case let .captured(draft) = monitor.pollSynchronously() else { return XCTFail("expected capture") }
        print("[benchmark] 10 MB text capture: \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
        XCTAssertEqual(draft.byteSize, large.utf8.count)
        XCTAssertEqual(draft.searchContent.count, ContentAnalyzer.searchLimit)
    }

    func testEntryLargerThanBudgetIsSkipped() {
        let monitor = self.monitor(rules: CaptureRules(maxEntryBytes: 100))
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "x", count: 1_000), forType: .string)
        guard case .skipped(.tooLarge) = monitor.pollSynchronously() else { return XCTFail("expected too large") }
    }

    func testTimerDrivenCaptureAndStop() {
        let captured = expectation(description: "captured by the timer")
        let box = LockedBox<[String]>([])
        let monitor = self.monitor { draft in
            box.value.append(draft.title)
            if draft.title == "timer" { captured.fulfill() }
        }
        monitor.start()
        monitor.start() // starting twice must not double-fire
        pasteboard.clearContents()
        pasteboard.setString("timer", forType: .string)
        wait(for: [captured], timeout: 3)

        monitor.stop()
        let afterStop = expectation(description: "nothing after stop")
        afterStop.isInverted = true
        pasteboard.clearContents()
        pasteboard.setString("after stop", forType: .string)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if box.value.contains("after stop") { afterStop.fulfill() }
        }
        wait(for: [afterStop], timeout: 1.5)
        XCTAssertEqual(box.value, ["timer"])

        // Restarting (as after wake) picks up the change made while stopped.
        monitor.start()
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in box.value.contains("after stop") }, object: nil)
        wait(for: [resumed], timeout: 3)
        monitor.stop()
    }

    func testWriteEmptySnapshotClearsPasteboard() {
        let monitor = self.monitor()
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        monitor.write(PasteboardSnapshot(items: []))
        XCTAssertNil(pasteboard.string(forType: .string))
    }
}

@MainActor
final class PreferencesEdgeCaseTests: XCTestCase {
    func testCorruptStoredValuesFallBackToDefaults() {
        let suite = "app.pasty.edge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("garbage".utf8), forKey: "hotKey")
        defaults.set("not a number", forKey: "maxHistory")
        defaults.set("sideways", forKey: "appearance")
        defaults.set("maybe", forKey: "duplicateHandling")
        defaults.set(Data([0, 1]), forKey: "excludedApps")

        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.hotKey, .default)
        XCTAssertEqual(preferences.maxHistory, 10_000)
        XCTAssertEqual(preferences.appearance, .system)
        XCTAssertEqual(preferences.duplicateHandling, .moveToTop)
        XCTAssertEqual(preferences.excludedApps, DefaultExclusions.apps)
    }

    func testHistoryLimitIsClamped() {
        let suite = "app.pasty.edge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-5, forKey: "maxHistory")
        XCTAssertEqual(Preferences(defaults: defaults).maxHistory, 10)
        defaults.set(10_000_000, forKey: "maxHistory")
        XCTAssertEqual(Preferences(defaults: defaults).maxHistory, 1_000_000)
    }

    func testEmptyExclusionListPersists() {
        let suite = "app.pasty.edge.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        Preferences(defaults: defaults).excludedApps = []
        XCTAssertTrue(Preferences(defaults: defaults).excludedApps.isEmpty, "an emptied list must not reset to defaults")
    }
}
