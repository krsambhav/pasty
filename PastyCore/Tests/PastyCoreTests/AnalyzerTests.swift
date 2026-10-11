import XCTest
@testable import PastyCore

final class AnalyzerTests: XCTestCase {
    private func snapshot(_ reps: [(String, String)]) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: reps.map { PasteboardRepresentation(type: $0.0, data: Data($0.1.utf8)) }),
        ])
    }

    func testPlainText() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, "\n\n  Hello   there\nsecond line")])))
        XCTAssertEqual(draft.kind, .text)
        XCTAssertEqual(draft.title, "Hello there")
        XCTAssertEqual(draft.lineCount, 4)
        XCTAssertFalse(draft.isCode)
    }

    func testURLDetection() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, "https://www.example.com/path?q=1")])))
        XCTAssertEqual(draft.kind, .url)
        XCTAssertEqual(draft.title, "example.com/path?q=1")
        XCTAssertEqual(draft.subtitle, "www.example.com")

        XCTAssertNil(ContentAnalyzer.detectURL(in: "see https://example.com for details"))
        XCTAssertNil(ContentAnalyzer.detectURL(in: "notes.txt"))
        XCTAssertNotNil(ContentAnalyzer.detectURL(in: "mailto:hi@example.com"))
    }

    func testRichTextKeepsKind() throws {
        let draft = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([
            (PasteboardType.html, "<b>Hi</b>"),
            (PasteboardType.string, "Hi"),
        ])))
        XCTAssertEqual(draft.kind, .richText)
    }

    func testCodeDetection() throws {
        let code = """
        func greet(name: String) -> String {
            let message = "Hello, \\(name)"
            return message
        }
        """
        XCTAssertTrue(CodeDetector.looksLikeCode(code))
        XCTAssertFalse(CodeDetector.looksLikeCode("Dear team,\nThanks for the update.\nBest, Sam"))
        XCTAssertTrue(try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, code)]))).isCode)
    }

    func testContentHashIgnoresRepresentationDifferences() throws {
        let plain = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, "same")])))
        let rich = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.rtf, "{\\rtf1 same}"), (PasteboardType.string, "same")])))
        let different = try XCTUnwrap(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, "Same")])))
        XCTAssertEqual(plain.contentHash, rich.contentHash)
        XCTAssertNotEqual(plain.contentHash, different.contentHash)
    }

    func testWhitespaceOnlyIsIgnored() {
        XCTAssertNil(ContentAnalyzer.analyze(snapshot([(PasteboardType.string, "   \n\t ")])))
    }

    func testBrowserImageCopyIsAnImage() throws {
        let png = try TestImages.png(width: 10, height: 10)
        let snapshot = PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardType.tiff, data: png),
                PasteboardRepresentation(type: PasteboardType.string, data: Data("https://example.com/cat.png".utf8)),
            ]),
        ])
        XCTAssertEqual(ContentAnalyzer.analyze(snapshot)?.kind, .image)
    }

    func testTitleTruncation() {
        let long = String(repeating: "x", count: 1_000)
        XCTAssertEqual(ContentAnalyzer.makeTitle(from: long).count, ContentAnalyzer.titleLimit)
    }

    func testRelativeTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-10), now: now, calendar: calendar), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-300), now: now, calendar: calendar), "5m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-7_200), now: now, calendar: calendar), "2h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_400 * 3), now: now, calendar: calendar), "3d")
    }
}

final class PrivacyTests: XCTestCase {
    func testSecretHeuristics() {
        XCTAssertTrue(SecretDetector.looksLikeSecret("sk-proj-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("Tr0ub4dor&3x!"))
        XCTAssertTrue(SecretDetector.looksLikeSecret("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"))

        XCTAssertFalse(SecretDetector.looksLikeSecret("hello world"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("https://Example.com/Path?a=1"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("someone@example.com"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertFalse(SecretDetector.looksLikeSecret("README.md"))
    }

    func testPolicyOrder() {
        let source = SourceApp(bundleID: "com.example.app", name: "App")
        XCTAssertEqual(PrivacyPolicy.evaluate(types: [PasteboardType.string], source: source, rules: CaptureRules(isPaused: true)), .paused)
        XCTAssertEqual(PrivacyPolicy.evaluate(types: [], source: source, rules: CaptureRules()), .empty)
        XCTAssertNil(PrivacyPolicy.evaluate(types: [PasteboardType.string], source: source, rules: CaptureRules()))
        XCTAssertNil(PrivacyPolicy.evaluate(types: [PasteboardType.png, PasteboardType.string], source: source, rules: CaptureRules(captureImages: false)))
    }

    func testDefaultExclusionsCoverPasswordManagers() {
        let ids = Set(DefaultExclusions.apps.map(\.bundleID))
        XCTAssertTrue(ids.contains("com.apple.keychainaccess"))
        XCTAssertTrue(ids.contains("com.1password.1password"))
    }
}

@MainActor
final class PreferencesTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "app.pasty.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.hotKey, .default)
        XCTAssertEqual(preferences.hotKey.modifierSymbols, "⇧⌘")
        XCTAssertEqual(preferences.maxHistory, 1_000)
        XCTAssertEqual(preferences.duplicateHandling, .moveToTop)
        XCTAssertTrue(preferences.captureImages)
        XCTAssertTrue(preferences.keepPinnedOnClear)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertFalse(preferences.isPaused)
        XCTAssertEqual(preferences.excludedApps, DefaultExclusions.apps)
    }

    func testValuesPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        var changes = 0
        preferences.onChange = { changes += 1 }
        preferences.hotKey = KeyCombo(keyCode: 49, modifiers: KeyCombo.option)
        preferences.maxHistory = 5_000
        preferences.duplicateHandling = .keepAll
        preferences.appearance = .dark
        preferences.isPaused = true
        preferences.captureImages = false
        preferences.excludedApps = [ExcludedApp(bundleID: "com.example", name: "Example")]
        XCTAssertEqual(changes, 7)

        let reloaded = Preferences(defaults: defaults)
        XCTAssertEqual(reloaded.hotKey, KeyCombo(keyCode: 49, modifiers: KeyCombo.option))
        XCTAssertEqual(reloaded.maxHistory, 5_000)
        XCTAssertEqual(reloaded.duplicateHandling, .keepAll)
        XCTAssertEqual(reloaded.appearance, .dark)
        XCTAssertTrue(reloaded.isPaused)
        XCTAssertFalse(reloaded.captureImages)
        XCTAssertEqual(reloaded.excludedApps.map(\.bundleID), ["com.example"])
        XCTAssertEqual(reloaded.captureRules.excludedBundleIDs, ["com.example"])
        XCTAssertTrue(reloaded.captureRules.isPaused)
    }

    func testShortcutValidation() {
        XCTAssertTrue(KeyCombo.default.isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 9, modifiers: KeyCombo.shift).isValidGlobalShortcut)
        XCTAssertFalse(KeyCombo(keyCode: 9, modifiers: 0).isValidGlobalShortcut)
    }
}
