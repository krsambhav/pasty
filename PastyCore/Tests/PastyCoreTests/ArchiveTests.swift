import AppKit
import XCTest
@testable import PastyCore

/// `.clipbookarchive` import/export, using archives shaped exactly like ClipBook 1.36's
/// `exportHistoryArchive()` writes them (src/archive.tsx).
final class ArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipBook Export \(UUID().uuidString.prefix(6)).clipbookarchive")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets/images"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a ClipBook-style archive. Values mirror ClipBook's JSON exactly (pretty-printed,
    /// `undefined` fields omitted, ISO dates with milliseconds).
    private func writeClipBookArchive(items: [[String: Any]], tags: [[String: Any]] = []) throws {
        let manifest: [String: Any] = ["formatVersion": 1, "appName": "ClipBook", "exportedAt": "2026-10-11T12:00:00.000Z"]
        try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted).write(to: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: tags, options: .prettyPrinted).write(to: root.appendingPathComponent("tags.json"))
        try JSONSerialization.data(withJSONObject: items, options: .prettyPrinted).write(to: root.appendingPathComponent("history.json"))
    }

    private func item(_ id: Int, kind: String, _ extra: [String: Any]) -> [String: Any] {
        var base: [String: Any] = [
            "id": ClipBookArchive.archiveID(Int64(id)),
            "kind": kind,
            "filePaths": [],
            "sourceAppName": "Safari",
            "sourceAppPath": "/Applications/Safari.app",
            "copiedAt": "2026-10-0\(id % 9 + 1)T10:00:00.000Z",
            "firstCopiedAt": "2026-09-01T08:30:00.000Z",
            "byteSize": 10,
            "isFavorite": false,
            "tagIDs": [],
            "tagNames": [],
            "copyCount": 1,
        ]
        for (key, value) in extra { base[key] = value }
        return base
    }

    func testImportsEveryClipBookKind() async throws {
        let png = try TestImages.png(width: 300, height: 200)
        try png.write(to: root.appendingPathComponent("assets/images/image_abc.png"))
        let rtf = "{\\rtf1\\ansi {\\b Bold} rich text}"
        try writeClipBookArchive(items: [
            item(1, kind: "text", ["text": "plain words", "copyCount": 4, "isFavorite": true]),
            item(2, kind: "richText", ["text": "Bold rich text", "rtfBase64": Data(rtf.utf8).base64EncodedString(), "html": "<b>Bold</b> rich text"]),
            item(3, kind: "link", ["text": "https://example.com/page"]),
            item(4, kind: "email", ["text": "someone@example.com"]),
            item(5, kind: "color", ["text": "#FF8800"]),
            item(6, kind: "image", ["assetPath": "assets/images/image_abc.png", "imageWidth": 300, "imageHeight": 200, "imageText": "receipt total"]),
            item(7, kind: "file", ["filePaths": ["/Users/me/Documents/Report Final.pdf"], "fileFolder": false]),
        ], tags: [["id": "1", "name": "Work", "color": "blue"]])

        let store = try ClipboardStore(url: nil)
        let summary = try await ArchiveTransfer.importArchive(at: root, into: store)
        XCTAssertEqual(summary.total, 7)
        XCTAssertEqual(summary.inserted, 7)
        XCTAssertEqual(summary.sourceApp, "ClipBook")

        let items = try await store.items()
        func find(_ title: String) -> ClipItem? { items.first { $0.title == title } }

        let plain = try XCTUnwrap(find("plain words"))
        XCTAssertTrue(plain.isPinned, "favorites become pinned")
        XCTAssertEqual(plain.copyCount, 4)
        XCTAssertEqual(plain.sourceName, "Safari")
        XCTAssertEqual(plain.createdAt, ClipBookArchive.parseDate("2026-09-01T08:30:00.000Z"))
        XCTAssertEqual(plain.updatedAt, ClipBookArchive.parseDate("2026-10-02T10:00:00.000Z"))

        let rich = try XCTUnwrap(find("Bold rich text"))
        XCTAssertEqual(rich.kind, .richText)
        let richSnapshot = try await store.snapshot(for: rich.id)
        XCTAssertEqual(richSnapshot?.items.first?.data(for: PasteboardType.rtf), Data(rtf.utf8))
        XCTAssertNotNil(richSnapshot?.items.first?.data(for: PasteboardType.html))

        XCTAssertEqual(find("example.com/page")?.kind, .url)
        XCTAssertEqual(find("someone@example.com")?.kind, .text)
        XCTAssertEqual(find("#FF8800")?.kind, .text)

        let image = try XCTUnwrap(items.first { $0.kind == .image })
        XCTAssertEqual(image.imageWidth, 300)
        let thumbnail = try await store.thumbnail(for: image.id)
        XCTAssertNotNil(thumbnail)
        let imageSnapshot = try await store.snapshot(for: image.id)
        XCTAssertEqual(imageSnapshot?.items.first?.data(for: PasteboardType.png), png)
        let ocrHits = try await store.search("receipt")
        XCTAssertEqual(ocrHits.first?.id, image.id, "ClipBook's image text stays searchable")

        let file = try XCTUnwrap(items.first { $0.kind == .file })
        XCTAssertEqual(file.title, "Report Final.pdf")
    }

    func testMissingAssetsUnknownKindsAndPathTraversalAreSkipped() async throws {
        try "secret".write(to: root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).png"), atomically: true, encoding: .utf8)
        try writeClipBookArchive(items: [
            item(1, kind: "image", ["assetPath": "assets/images/missing.png"]),
            item(2, kind: "image", ["assetPath": "../outside.png"]),
            item(3, kind: "image", ["assetPath": "/etc/hosts"]),
            item(4, kind: "hologram", ["text": "future kind"]),
            item(5, kind: "text", [:]),
            item(6, kind: "file", ["filePaths": []]),
            item(7, kind: "text", ["text": "kept"]),
        ])
        let store = try ClipboardStore(url: nil)
        let summary = try await ArchiveTransfer.importArchive(at: root, into: store)
        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.missingAssets, 3)
        XCTAssertEqual(summary.skipped, 3)
        let titles = try await store.items().map(\.title)
        XCTAssertEqual(titles, ["kept"])
    }

    func testReimportDoesNotDuplicateAndMergesFavorites() async throws {
        try writeClipBookArchive(items: [item(1, kind: "text", ["text": "once"])])
        let store = try ClipboardStore(url: nil)
        try await store.insert(.text("once"))
        _ = try await ArchiveTransfer.importArchive(at: root, into: store)

        try writeClipBookArchive(items: [item(1, kind: "text", ["text": "once", "isFavorite": true])])
        let second = try await ArchiveTransfer.importArchive(at: root, into: store)
        XCTAssertEqual(second.inserted, 0)
        XCTAssertEqual(second.merged, 1)
        let items = try await store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].isPinned)
    }

    func testImagesCanBeLeftOut() async throws {
        try TestImages.png(width: 10, height: 10).write(to: root.appendingPathComponent("assets/images/a.png"))
        try writeClipBookArchive(items: [
            item(1, kind: "image", ["assetPath": "assets/images/a.png"]),
            item(2, kind: "text", ["text": "text only"]),
        ])
        let store = try ClipboardStore(url: nil)
        let summary = try await ArchiveTransfer.importArchive(at: root, into: store, includeImages: false)
        XCTAssertEqual(summary.total, 1)
        let kinds = try await store.items().map(\.kind)
        XCTAssertEqual(kinds, [.text])
    }

    func testRejectsNonArchivesAndNewerFormats() async throws {
        let store = try ClipboardStore(url: nil)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        do {
            _ = try await ArchiveTransfer.importArchive(at: empty, into: store)
            XCTFail("a folder without manifest.json must be rejected")
        } catch {
            XCTAssertEqual(error as? ClipBookArchive.ArchiveError, .notAnArchive("manifest.json"))
        }

        try JSONSerialization.data(withJSONObject: ["formatVersion": 99, "appName": "ClipBook", "exportedAt": "x"]).write(to: root.appendingPathComponent("manifest.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("history.json"))
        XCTAssertThrowsError(try ClipBookArchive.read(at: root)) { XCTAssertEqual($0 as? ClipBookArchive.ArchiveError, .unsupportedVersion(99)) }
    }

    func testLargeArchiveImportIsBatchedAndCancellable() async throws {
        let items = (1...1_500).map { item($0, kind: "text", ["text": "bulk item \($0)"]) }
        try writeClipBookArchive(items: items)
        let store = try ClipboardStore(url: nil)
        let progress = LockedBox<[Int]>([])
        let start = Date()
        let summary = try await ArchiveTransfer.importArchive(at: root, into: store) { progress.value.append($0.completed) }
        print("[benchmark] import 1,500 ClipBook items: \(Int(Date().timeIntervalSince(start) * 1_000)) ms")
        XCTAssertEqual(summary.inserted, 1_500)
        XCTAssertEqual(progress.value.first, 0)
        XCTAssertEqual(progress.value.last, 1_500)
        XCTAssertGreaterThan(progress.value.count, 5, "progress is reported per batch")

        let cancelled = try ClipboardStore(url: nil)
        let archive: URL = root
        let task = Task { try await ArchiveTransfer.importArchive(at: archive, into: cancelled) }
        task.cancel()
        _ = try? await task.value
        let partial = try await cancelled.count()
        XCTAssertLessThan(partial, 1_500)
    }

    // MARK: Export

    func testExportRoundTripsThroughTheArchive() async throws {
        let source = try ClipboardStore(url: nil)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try await source.insert(.text("hello export", source: SourceApp(bundleID: "com.apple.Safari", name: "Safari"), date: base))
        let pinned = try await source.insert(.text("#3B82F6", date: base.addingTimeInterval(1))).itemID!
        try await source.setPinned(true, for: pinned)
        try await source.insert(.text("https://example.com/x", date: base.addingTimeInterval(2)))
        try await source.insert(.text("a@b.co", date: base.addingTimeInterval(3)))
        let rtf = Data("{\\rtf1 Styled}".utf8)
        try await source.insert(XCTUnwrap(ContentAnalyzer.analyze(PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: PasteboardType.rtf, data: rtf),
            PasteboardRepresentation(type: PasteboardType.string, data: Data("Styled".utf8)),
        ])]))))
        let png = try TestImages.png(width: 64, height: 32)
        try await source.insert(XCTUnwrap(ContentAnalyzer.analyze(PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: PasteboardType.png, data: png),
        ])]))))
        try await source.insert(XCTUnwrap(ContentAnalyzer.analyze(PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: PasteboardType.fileURL, data: Data(URL(fileURLWithPath: "/tmp/a b.txt").absoluteString.utf8)),
        ])]))))
        try await source.insert(XCTUnwrap(ContentAnalyzer.analyze(PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: "com.example.private", data: Data([1, 2, 3])),
        ])]))))

        let destination = root.deletingLastPathComponent().appendingPathComponent("Pasty Export \(UUID().uuidString.prefix(6)).clipbookarchive")
        defer { try? FileManager.default.removeItem(at: destination) }
        let summary = try await ArchiveTransfer.exportArchive(from: source, to: destination, appVersion: "1.0.40")
        XCTAssertEqual(summary.exported, 7)
        XCTAssertEqual(summary.skipped, 1, "opaque app data can't be represented")

        // The JSON has every field ClipBook's importer dereferences unconditionally.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("history.json"))) as? [[String: Any]])
        for entry in raw {
            XCTAssertNotNil(entry["filePaths"] as? [String])
            XCTAssertNotNil(entry["tagIDs"] as? [String])
            XCTAssertNotNil(entry["copiedAt"] as? String)
            XCTAssertNotNil(entry["isFavorite"] as? Bool)
        }
        XCTAssertEqual(Set(raw.compactMap { $0["kind"] as? String }), ["text", "color", "link", "email", "richText", "image", "file"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as? [String: Any])
        XCTAssertEqual(manifest["formatVersion"] as? Int, 1)
        XCTAssertEqual(manifest["appName"] as? String, "Pasty")

        let restored = try ClipboardStore(url: nil)
        let imported = try await ArchiveTransfer.importArchive(at: destination, into: restored)
        XCTAssertEqual(imported.inserted, 7)
        let items = try await restored.items()
        let expectedTitles = try await source.items().filter { $0.kind != .other }.map(\.title)
        XCTAssertEqual(Set(items.map(\.title)), Set(expectedTitles))
        XCTAssertTrue(items.first { $0.title == "#3B82F6" }?.isPinned ?? false)
        XCTAssertEqual(items.first { $0.title == "hello export" }?.updatedAt, base)
        XCTAssertEqual(items.first { $0.title == "hello export" }?.sourceName, "Safari")
        let image = try XCTUnwrap(items.first { $0.kind == .image })
        let restoredImage = try await restored.snapshot(for: image.id)
        XCTAssertEqual(restoredImage?.items.first?.data(for: PasteboardType.png), png)
        let styled = try XCTUnwrap(items.first { $0.title == "Styled" })
        let restoredRTF = try await restored.snapshot(for: styled.id)
        XCTAssertEqual(restoredRTF?.items.first?.data(for: PasteboardType.rtf), rtf)
    }

    func testArchiveIDsMatchClipBook() {
        XCTAssertEqual(ClipBookArchive.archiveID(1), "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(ClipBookArchive.archiveID(0xABCDEF), "00000000-0000-4000-8000-000000abcdef")
    }
}
