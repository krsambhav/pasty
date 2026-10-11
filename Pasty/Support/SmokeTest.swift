import AppKit
import Carbon.HIToolbox
import Darwin
import PastyCore

/// End-to-end edge-case suite run by `Pasty --smoke-test <dir>` (used in CI).
///
/// It drives the real app: the general pasteboard, the monitor, SQLite, the panel, real
/// keystrokes (via CGEvent, when Accessibility is granted), pasting into TextEdit, Settings,
/// and screenshots of every surface. Results are written to `<dir>/results.json`.
@MainActor
final class SmokeTest {
    private let coordinator: AppCoordinator
    private let output: URL
    private var results = Results()
    private let pasteboard = NSPasteboard.general

    init(coordinator: AppCoordinator, output: URL) {
        self.coordinator = coordinator
        self.output = output
    }

    private struct Results: Encodable {
        var passed = true
        var checks: [String: String] = [:]
        var notes: [String] = []
        var captureLatencyMs: Double?
        var panelOpenMs: Stats?
        var panelFirstOpenMs: Double?
        var pasteLatencyMs: [Double] = []
        var largeContent: [String: Double] = [:]
        var mainThreadMaxStallMs: Double?
        var scroll: [String: Double] = [:]
        var stressCycles = 0
        var stressMemoryGrowthMB: Double?
        var idleCPUPercent: Double?
        var residentMemoryMB: Double?
        var accessibilityTrusted = AccessibilityPermission.isGranted
        var screenshots: [String] = []
    }

    struct Stats: Encodable {
        let median: Double
        let p95: Double
        let max: Double
        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            median = sorted[sorted.count / 2]
            p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            max = sorted.last ?? 0
        }
    }

    private var store: ClipboardStore { coordinator.store }
    private var model: PanelModel { coordinator.model }
    private var panel: PanelController { coordinator.panelController }

    // MARK: - Runner

    func run() async {
        coordinator.pasteCoordinator.promptsForAccessibility = false

        check("fonts registered", Typeface.isAvailable)
        check("search field uses Plus Jakarta Sans", panel.searchBridge.field?.font?.fontName.hasPrefix("PlusJakartaSans") == true)
        checkPanelFrames()

        let marker = "pasty-smoke-\(UUID().uuidString)"
        await testCapture(marker: marker)
        await testRapidCopies(marker: marker)
        await testPanelTiming()
        await testChangesWhilePanelOpen()
        await testSelectionAfterDeleteAndPin()
        await testSearchStates()
        await testCopyBack(marker: marker)
        await testPauseAndResume()
        await testSleepWake()
        await testPermissionDenied(marker: marker)
        if results.accessibilityTrusted {
            await testKeyboard()
            await testGlobalHotKey()
            await testMouse()
            await testPasteIntoTextEdit(marker: marker)
            await testPlainTextPaste()
        } else {
            results.notes.append("Accessibility not granted: keystroke, hotkey and paste-into-app checks skipped.")
        }
        await testLargeContent()
        await testUpdater()
        await testFilePreview()
        await testScrollPerformance()
        await testStress()
        await captureScreenshots()
        await measureIdle()

        finish()
    }

    private func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
        if passed {
            results.checks[name] = "pass"
        } else {
            let detail = detail()
            results.checks[name] = "FAIL" + (detail.isEmpty ? "" : ": \(detail)")
            results.passed = false
        }
    }

    private func finish() {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: output.appendingPathComponent("results.json"))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        exit(results.passed ? 0 : 1)
    }

    // MARK: - Capture

    private func copy(_ string: String) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func isRecorded(_ text: String) async -> Bool {
        (try? await store.search(text).contains { $0.title == text }) ?? false
    }

    private func testCapture(marker: String) async {
        let copiedAt = ContinuousClock.now
        copy(marker)
        let recorded = await waitFor(seconds: 5) { await self.isRecorded(marker) }
        check("copy is recorded", recorded)
        if recorded { results.captureLatencyMs = (ContinuousClock.now - copiedAt).milliseconds }
    }

    private func testRapidCopies(marker: String) async {
        for index in 0..<20 { copy("rapid \(index) \(marker)") }
        check("last of 20 rapid copies recorded", await waitFor(seconds: 5) { await self.isRecorded("rapid 19 \(marker)") })
        let duplicates = (try? await store.search("rapid 19 \(marker)").filter { $0.title == "rapid 19 \(marker)" }.count) ?? 0
        check("rapid copies create no duplicates", duplicates == 1, "\(duplicates) entries")
    }

    // MARK: - Panel

    private func checkPanelFrames() {
        let size = PanelController.panelSize
        let layouts: [(String, NSRect)] = [
            ("main 1512×945", NSRect(x: 0, y: 0, width: 1512, height: 945)),
            ("left external, negative x", NSRect(x: -2560, y: 0, width: 2560, height: 1415)),
            ("above, positive y", NSRect(x: 200, y: 1117, width: 1920, height: 1055)),
            ("portrait", NSRect(x: 1512, y: -800, width: 1080, height: 1895)),
            ("tiny 800×500", NSRect(x: 0, y: 0, width: 800, height: 500)),
            ("smaller than panel 640×400", NSRect(x: 100, y: 100, width: 640, height: 400)),
        ]
        for (name, visible) in layouts {
            let frame = PanelController.frame(in: visible)
            let fitsHorizontally = size.width > visible.width || (frame.minX >= visible.minX && frame.maxX <= visible.maxX)
            let fitsVertically = size.height > visible.height || (frame.minY >= visible.minY && frame.maxY <= visible.maxY)
            let topVisible = frame.maxY <= visible.maxY
            check("panel placement: \(name)", fitsHorizontally && fitsVertically && topVisible, "\(frame) in \(visible)")
        }
    }

    private func testPanelTiming() async {
        await model.reload()
        var samples: [Double] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let wasFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
        for cycle in 0..<30 {
            let start = ContinuousClock.now
            panel.show()
            panel.panel.displayIfNeeded()
            let elapsed = (ContinuousClock.now - start).milliseconds
            if cycle == 0 {
                results.panelFirstOpenMs = elapsed
                check("panel becomes visible", panel.isVisible)
                check("panel becomes key window", panel.panel.isKeyWindow)
                check("showing the panel never makes Pasty the frontmost app",
                      wasFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier != ownPID)
                check("search field focused on open", isSearchFieldFocused)
                check("panel is on the screen under the pointer", NSScreen.screenContainingMouse.map { $0.frame.intersects(panel.panel.frame) } ?? true)
            }
            samples.append(elapsed)
            await nextTurn()
            panel.hide()
            await nextTurn()
        }
        results.panelOpenMs = Stats(samples)
        check("panel hides", !panel.isVisible)
    }

    private var isSearchFieldFocused: Bool {
        guard let field = panel.searchBridge.field else { return false }
        return panel.panel.firstResponder === field || panel.panel.firstResponder === field.currentEditor()
    }

    private func testChangesWhilePanelOpen() async {
        panel.show()
        await settle()
        let selectedBefore = model.selectedID
        let text = "copied while open \(UUID().uuidString)"
        copy(text)
        let appeared = await waitFor(seconds: 5) { self.model.items.first?.title == text }
        check("list updates while the panel is open", appeared)
        check("selection stays put when new items arrive", model.selectedID == selectedBefore)
        panel.hide()
    }

    private func testSelectionAfterDeleteAndPin() async {
        for index in 0..<4 {
            let fixture = "selection fixture \(index) \(UUID().uuidString)"
            copy(fixture)
            _ = await waitFor(seconds: 3) { await self.isRecorded(fixture) }
        }
        panel.show()
        await settle()
        guard model.items.count >= 4 else { return check("selection fixtures", false, "only \(model.items.count) items") }
        model.select(model.items[1])
        let expectedNext = model.items[2].id
        coordinator.perform(.delete(model.items[1]))
        check("delete selects the next item", await waitFor(seconds: 3) { self.model.selectedID == expectedNext })

        let toPin = model.items[0]
        coordinator.perform(.togglePin(toPin))
        _ = await waitFor(seconds: 3) { self.model.items.first { $0.id == toPin.id }?.isPinned == true }
        model.filter = .pinned
        check("pinned filter shows only pinned items", await waitFor(seconds: 3) {
            !self.model.items.isEmpty && self.model.items.allSatisfy(\.isPinned) && self.model.sections.first?.title == "Pinned"
        })
        coordinator.perform(.togglePin(toPin))
        check("unpinning the last pinned item shows the empty state", await waitFor(seconds: 3) {
            self.model.items.allSatisfy { $0.id != toPin.id }
        })
        model.filter = .all
        check("history is grouped by date", await waitFor(seconds: 3) { self.model.sections.first?.title == "Today" }, model.sections.map(\.title).joined(separator: ","))
        panel.hide()
    }

    private func testSearchStates() async {
        panel.show()
        model.query = "zz-no-such-thing-\(UUID().uuidString)"
        check("no-result search shows empty list", await waitFor(seconds: 3) { self.model.items.isEmpty && self.model.hasLoaded })
        model.query = "    "
        check("whitespace-only search shows everything", await waitFor(seconds: 3) { !self.model.items.isEmpty && self.model.sections.first?.title == "Today" })
        model.query = "SELECTION FIXTURE"
        check("search is case-insensitive and grouped as results", await waitFor(seconds: 3) {
            self.model.items.count >= 2 && self.model.sections.first?.title.hasSuffix("Results") == true
        })
        model.moveSelection(by: -50)
        check("selection clamps at the top", model.selectedIndex == 0)
        model.moveSelection(by: 500)
        check("selection clamps at the bottom", model.selectedIndex == model.items.count - 1)
        panel.hide()
        panel.show()
        check("reopening clears the query", model.query.isEmpty)
        panel.hide()
    }

    // MARK: - Copy & paste

    private func testCopyBack(marker: String) async {
        guard let target = try? await store.search(marker).first(where: { $0.title == marker }) else {
            return check("copy-back fixture", false)
        }
        copy("something else \(marker)")
        _ = await waitFor(seconds: 5) { await self.isRecorded("something else \(marker)") }
        let countBefore = (try? await store.count()) ?? 0

        panel.show()
        await coordinator.pasteCoordinator.run(.copy, on: target)
        check("copy-back restores exact content", pasteboard.string(forType: .string) == marker)
        check("panel closes after choosing an item", !panel.isVisible)
        coordinator.monitor.checkNow()
        try? await Task.sleep(for: .milliseconds(700))
        let countAfter = (try? await store.count()) ?? 0
        check("copy-back creates no duplicate entry", countAfter == countBefore, "\(countBefore) → \(countAfter)")
        check("copy-back moves the item to the top", await waitFor(seconds: 2) { self.model.items.first?.id == target.id })
    }

    private func testPermissionDenied(marker: String) async {
        guard let target = try? await store.search(marker).first(where: { $0.title == marker }) else { return }
        let paste: PasteCoordinator = coordinator.pasteCoordinator
        paste.isAccessibilityTrusted = { false }
        copy("before denied paste")
        _ = await waitFor(seconds: 3) { await self.isRecorded("before denied paste") }
        panel.show()
        let pasted = await paste.run(.paste, on: target)
        check("denied paste reports failure", !pasted)
        check("denied paste still copies the item", pasteboard.string(forType: .string) == marker)
        check("denied paste explains itself (toast shown)", coordinator.hud.isShowing)
        paste.isAccessibilityTrusted = { AccessibilityPermission.isGranted }
    }

    private func testPauseAndResume() async {
        coordinator.setPaused(true)
        await nextTurn()
        let secret = "while paused \(UUID().uuidString)"
        copy(secret)
        coordinator.monitor.checkNow()
        try? await Task.sleep(for: .milliseconds(800))
        check("copies while paused are not recorded", !(await isRecorded(secret)))
        coordinator.setPaused(false)
        try? await Task.sleep(for: .milliseconds(400))
        check("paused copy is not recorded after resuming", !(await isRecorded(secret)))
        let after = "after resume \(UUID().uuidString)"
        copy(after)
        check("recording resumes", await waitFor(seconds: 5) { await self.isRecorded(after) })
    }

    private func testSleepWake() async {
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        await nextTurn()
        let duringSleep = "during sleep \(UUID().uuidString)"
        copy(duringSleep)
        try? await Task.sleep(for: .milliseconds(900))
        check("monitor is idle while asleep", !(await isRecorded(duringSleep)))
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        check("change made during sleep is picked up on wake", await waitFor(seconds: 5) { await self.isRecorded(duringSleep) })
    }

    // MARK: - Real input

    private func post(keyCode: Int, flags: CGEventFlags = [], text: String? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
            event.flags = flags
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: .cghidEventTap)
        }
    }

    private func typeText(_ text: String) {
        for character in text { post(keyCode: kVK_ANSI_A, text: String(character)) }
    }

    private func testKeyboard() async {
        panel.show()
        await settle()
        typeText("selection")
        check("typing goes straight into the search field", await waitFor(seconds: 3) { self.model.query == "selection" }, "query: \(model.query)")
        _ = await waitFor(seconds: 2) { self.model.items.count >= 2 }
        await settle()
        let first = model.selectedIndex
        post(keyCode: kVK_DownArrow)
        check("↓ moves the selection", await waitFor(seconds: 2) { self.model.selectedIndex == (first ?? 0) + 1 })
        post(keyCode: kVK_UpArrow)
        check("↑ moves the selection", await waitFor(seconds: 2) { self.model.selectedIndex == first })
        post(keyCode: kVK_ANSI_A, flags: .maskCommand)
        let selectedAll = await waitFor(seconds: 2) {
            let range = (self.panel.searchBridge.field?.currentEditor() as? NSTextView)?.selectedRange()
            return range == NSRange(location: 0, length: self.model.query.utf16.count) && !self.model.query.isEmpty
        }
        check("⌘A selects all text in the search field", selectedAll)
        typeText("fix")
        check("typing after ⌘A replaces the selection", await waitFor(seconds: 2) { self.model.query == "fix" }, "query: \(model.query)")
        post(keyCode: kVK_ANSI_A, flags: .maskCommand)
        post(keyCode: kVK_ANSI_X, flags: .maskCommand)
        check("⌘X cuts the search text", await waitFor(seconds: 2) { self.model.query.isEmpty }, "query: \(model.query)")
        post(keyCode: kVK_ANSI_Z, flags: .maskCommand)
        check("⌘Z undoes in the search field", await waitFor(seconds: 2) { self.model.query == "fix" }, "query: \(model.query)")
        model.query = "selection"
        _ = await waitFor(seconds: 2) { self.model.items.count >= 2 }
        await settle()
        post(keyCode: kVK_Tab)
        check("Tab switches to Pinned", await waitFor(seconds: 2) { self.model.filter == .pinned })
        post(keyCode: kVK_Tab)
        _ = await waitFor(seconds: 2) { self.model.filter == .all }
        post(keyCode: kVK_Escape)
        check("Esc closes the panel", await waitFor(seconds: 2) { !self.panel.isVisible })
    }

    private func testGlobalHotKey() async {
        let combo = coordinator.preferences.hotKey
        var flags: CGEventFlags = []
        if combo.modifiers & KeyCombo.command != 0 { flags.insert(.maskCommand) }
        if combo.modifiers & KeyCombo.shift != 0 { flags.insert(.maskShift) }
        if combo.modifiers & KeyCombo.option != 0 { flags.insert(.maskAlternate) }
        if combo.modifiers & KeyCombo.control != 0 { flags.insert(.maskControl) }
        post(keyCode: Int(combo.keyCode), flags: flags)
        check("global shortcut opens the panel", await waitFor(seconds: 3) { self.panel.isVisible })
        check("search field focused after shortcut", isSearchFieldFocused)
        post(keyCode: Int(combo.keyCode), flags: flags)
        check("global shortcut closes the panel", await waitFor(seconds: 3) { !self.panel.isVisible })
    }

    /// Opens a fresh TextEdit document, pastes `item` into it, and reads the result back via AX.
    private func paste(_ item: ClipItem, action: PasteAction, expecting expected: String, documentExtension: String = "txt") async -> String {
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return "TextEdit not found"
        }
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("pasty-smoke-\(UUID().uuidString).\(documentExtension)")
        // An empty .rtf isn't a valid document; give TextEdit a minimal one.
        try? Data((documentExtension == "rtf" ? "{\\rtf1\\ansi }" : "").utf8).write(to: document)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.open([document], withApplicationAt: textEdit, configuration: configuration) else {
            return "Could not open TextEdit"
        }
        defer { app.forceTerminate() }
        let ready = await waitFor(seconds: 10) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                && Self.focusedValue(pid: app.processIdentifier) != nil
        }
        guard ready else { return "TextEdit never became frontmost with a focused text view" }

        panel.show()
        await nextTurn()
        check("paste target is the previously active app", panel.previousApp?.processIdentifier == app.processIdentifier)
        check("opening the panel keeps the other app frontmost (no focus stealing)",
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              "frontmost: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        check("panel is key over another app", panel.panel.isKeyWindow)
        let started = ContinuousClock.now
        guard await coordinator.pasteCoordinator.run(action, on: item) else { return "Paste keystroke was not sent" }
        let latency = (ContinuousClock.now - started).milliseconds
        results.pasteLatencyMs.append((latency * 10).rounded() / 10)
        check("paste keystroke is sent promptly (< 250 ms)", latency < 250, "\(latency) ms")
        let landed = await waitFor(seconds: 5) { Self.focusedValue(pid: app.processIdentifier)?.contains(expected) == true }
        return landed ? "verified" : "text did not appear (value: \(Self.focusedValue(pid: app.processIdentifier) ?? "nil"))"
    }

    private func testPasteIntoTextEdit(marker: String) async {
        guard let item = try? await store.search(marker).first(where: { $0.title == marker }) else {
            return check("paste fixture", false)
        }
        let result = await paste(item, action: .paste, expecting: marker)
        check("paste into TextEdit", result == "verified", result)
    }

    private func testPlainTextPaste() async {
        let attributed = NSAttributedString(string: "Rich paste \(UUID().uuidString.prefix(8))", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        guard let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return }
        pasteboard.clearContents()
        let entry = NSPasteboardItem()
        entry.setData(rtf, forType: .rtf)
        entry.setString(attributed.string, forType: .string)
        pasteboard.writeObjects([entry])
        _ = await waitFor(seconds: 5) { await self.isRecorded(attributed.string) }
        guard let item = try? await store.search(attributed.string).first(where: { $0.title == attributed.string }) else {
            return check("rich text fixture", false)
        }
        check("rich text is classified as rich text", item.kind == .richText)
        let result = await paste(item, action: .pastePlainText, expecting: attributed.string, documentExtension: "rtf")
        check("paste as plain text into a rich document", result == "verified", result)
        check("plain-text paste leaves only plain text on the clipboard", pasteboard.types?.map(\.rawValue).contains(PasteboardType.rtf) == false)
    }

    private static func focusedValue(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXFocusedUIElement" as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXValue" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Large content (10,000-line code, 10 MB single line)

    nonisolated static func code(lines: Int) -> String {
        (0..<lines).map { index in
            switch index % 5 {
            case 0: "func handler\(index)(request: Request) async throws -> Response {"
            case 1: "    let value\(index) = try await service.fetch(id: \(index), retries: 3)"
            case 2: "    guard value\(index).isValid else { throw APIError.invalid(\"\(index)\") }"
            case 3: "    return Response(status: .ok, body: value\(index).encoded())"
            default: "}"
            }
        }.joined(separator: "\n")
    }

    /// Syntax-colored RTF, like Xcode puts on the pasteboard.
    nonisolated static func coloredRTF(_ code: String) -> Data? {
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.black,
        ])
        let keywords = try? NSRegularExpression(pattern: "\\b(func|let|guard|return|throw|try|await|async|throws)\\b")
        let nsCode = code as NSString
        keywords?.enumerateMatches(in: code, range: NSRange(location: 0, length: nsCode.length)) { match, _, _ in
            if let range = match?.range { result.addAttribute(.foregroundColor, value: NSColor.systemPink, range: range) }
        }
        return try? result.data(from: NSRange(location: 0, length: result.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private func testLargeContent() async {
        // Fixtures are built off the main thread: they stand in for other apps' work.
        let marker = "final-marker-\(UUID().uuidString.prefix(8))"
        let fixtures = await Task.detached(priority: .userInitiated) { () -> (String, String, String, Data?) in
            let plain = SmokeTest.code(lines: 10_000) + "\n// \(marker)-plain"
            let rich = SmokeTest.code(lines: 10_000) + "\n// \(marker)-rich"
            let minified = String(repeating: "aZ9+/", count: 2_000_000) + "\(marker)-min"
            return (plain, rich, minified, SmokeTest.coloredRTF(rich))
        }.value
        let (plain, rich, minified, rtfData) = fixtures
        guard let rtf = rtfData else { return check("colored RTF fixture", false) }
        results.largeContent["10k-line code KB"] = Double(plain.utf8.count / 1_024)
        results.largeContent["10k-line colored RTF KB"] = Double(rtf.count / 1_024)

        let watchdog = MainThreadWatchdog()
        watchdog.start()
        defer { _ = watchdog.stop() }
        func phase(_ name: String) {
            let stats = watchdog.snapshot()
            results.largeContent["main-thread max stall during \(name) ms"] = stats.max
            results.mainThreadMaxStallMs = max(results.mainThreadMaxStallMs ?? 0, stats.max)
            watchdog.reset()
        }

        /// Another app copies: the write happens off our main thread, as it would in reality.
        func externalCopy(_ items: [(String, Data)]) async {
            let payload = UncheckedSendable(value: items)
            await Task.detached {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                let entry = NSPasteboardItem()
                for (type, data) in payload.value { entry.setData(data, forType: NSPasteboard.PasteboardType(type)) }
                pasteboard.writeObjects([entry])
            }.value
        }

        func record(_ name: String, _ items: [(String, Data)], title: String) async -> ClipItem? {
            let existing = Set(model.items.filter { $0.title == title }.map(\.id))
            let started = ContinuousClock.now
            await externalCopy(items)
            let recorded = await waitFor(seconds: 10) { self.model.items.contains { $0.title == title && !existing.contains($0.id) } }
            check("large content recorded: \(name)", recorded)
            results.largeContent["capture \(name) ms"] = ((ContinuousClock.now - started).milliseconds * 10).rounded() / 10
            return model.items.first { $0.title == title && !existing.contains($0.id) }
        }

        let firstLine = ContentAnalyzer.makeTitle(from: plain)
        guard let plainItem = await record("10k-line code", [(PasteboardType.string, Data(plain.utf8))], title: firstLine) else { return }
        let richItem = await record("10k-line colored RTF", [(PasteboardType.rtf, rtf), (PasteboardType.string, Data(rich.utf8))], title: firstLine)
        let minifiedItem = await record("10 MB single line", [(PasteboardType.string, Data(minified.utf8))], title: ContentAnalyzer.makeTitle(from: String(minified.prefix(1_000))))
        phase("capture")

        panel.show()
        await settle()
        phase("panel open")
        for (name, item) in [("10k-line code", plainItem), ("10k-line colored RTF", richItem), ("10 MB single line", minifiedItem)] {
            guard let item, model.items.contains(where: { $0.id == item.id }) else { continue }
            let started = ContinuousClock.now
            model.select(item)
            let shown = await waitFor(seconds: 5) { self.model.detail?.itemID == item.id }
            panel.panel.displayIfNeeded()
            check("preview appears: \(name)", shown)
            results.largeContent["preview \(name) ms"] = ((ContinuousClock.now - started).milliseconds * 10).rounded() / 10
            try? await Task.sleep(for: .milliseconds(150))
        }
        check("10k-line code previews as code", plainItem.isCode)
        phase("previews")

        // Holding ↓ across large entries.
        model.select(model.items[0])
        let flickStart = ContinuousClock.now
        for _ in 0..<min(12, model.items.count - 1) {
            model.moveSelection(by: 1)
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(300))
        results.largeContent["12 rapid ↓ across large entries ms"] = ((ContinuousClock.now - flickStart).milliseconds * 10).rounded() / 10
        phase("rapid navigation")

        let searchStart = ContinuousClock.now
        model.query = "\(marker)-plain"
        let found = await waitFor(seconds: 5) { self.model.items.first?.id == plainItem.id }
        check("search finds text on the last of 10,000 lines", found)
        results.largeContent["search last line ms"] = ((ContinuousClock.now - searchStart).milliseconds * 10).rounded() / 10
        let hugeQuery = String(plain.prefix(5_000))
        model.query = hugeQuery
        check("pasting a huge query into search stays responsive", await waitFor(seconds: 3) { self.model.hasLoaded })
        phase("search")

        // The paste itself: from choosing the item to ⌘V being sent.
        model.query = ""
        _ = await waitFor(seconds: 2) { self.model.items.first != nil }
        await coordinator.pasteCoordinator.run(.copy, on: plainItem)
        try? await Task.sleep(for: .milliseconds(200))
        phase("copy back")
        check("10k-line code is restored exactly", pasteboard.string(forType: .string) == plain)
        panel.hide()

        let worst = results.largeContent.filter { $0.key.hasPrefix("main-thread") }.values.max() ?? 0
        check("main thread never stalls > 100 ms with large content", worst < 100, "worst \(worst) ms")
        _ = watchdog.stop()

        if results.accessibilityTrusted {
            let result = await paste(plainItem, action: .paste, expecting: "\(marker)-plain")
            check("paste 10k-line code into TextEdit (last line arrives)", result == "verified", result)
        }
    }

    // MARK: - Updates

    /// Builds a fake newer release from this very app, then checks the updater accepts it, rejects
    /// a bad checksum and an older build, and that the install script swaps and rolls back bundles.
    private func testUpdater() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pasty-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 1
        let newBuild = currentBuild + 1

        func shell(_ tool: String, _ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }

        // A copy of this app, re-versioned and re-signed ad hoc, zipped like CI does.
        let fake = root.appendingPathComponent("fake/Pasty.app", isDirectory: true)
        try? fm.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard shell("/usr/bin/ditto", [Bundle.main.bundlePath, fake.path]),
              shell("/usr/bin/plutil", ["-replace", "CFBundleVersion", "-string", "\(newBuild)", fake.appendingPathComponent("Contents/Info.plist").path]),
              shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", fake.path]) else {
            return check("updater fixture", false)
        }
        let zip = root.appendingPathComponent("Pasty.zip")
        guard shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", fake.path, zip.path]),
              let digest = try? UpdateFeed.sha256Hex(ofFileAt: zip) else { return check("updater archive", false) }
        let goodSum = root.appendingPathComponent("good.sha256")
        let badSum = root.appendingPathComponent("bad.sha256")
        try? "\(digest)  Pasty.zip\n".write(to: goodSum, atomically: true, encoding: .utf8)
        try? (String(repeating: "0", count: 64) + "  Pasty.zip\n").write(to: badSum, atomically: true, encoding: .utf8)

        func feed(build: Int, checksum: URL) -> URL {
            let json = """
            {"tag_name":"v1.0.\(build)","body":"Smoke","draft":false,"prerelease":false,"assets":[
              {"name":"Pasty.zip","browser_download_url":"\(zip.absoluteString)","size":1},
              {"name":"Pasty.zip.sha256","browser_download_url":"\(checksum.absoluteString)","size":1}]}
            """
            let url = root.appendingPathComponent("feed-\(build)-\(checksum.lastPathComponent).json")
            try? json.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        let older = Updater(feedOverride: feed(build: max(1, currentBuild - 1), checksum: goodSum))
        await older.check(userInitiated: true)
        check("updater: an older or equal release is ignored", older.phase == .upToDate, "\(older.phase)")

        let tampered = Updater(feedOverride: feed(build: newBuild, checksum: badSum))
        await tampered.check(userInitiated: true)
        check("updater: a download with a wrong checksum is rejected", {
            if case let .failed(message) = tampered.phase { return message.contains("checksum") }
            return false
        }(), "\(tampered.phase)")

        let good = Updater(feedOverride: feed(build: newBuild, checksum: goodSum))
        let started = ContinuousClock.now
        await good.check(userInitiated: true)
        results.largeContent["update download + verify ms"] = ((ContinuousClock.now - started).milliseconds * 10).rounded() / 10
        if CodeSignature.isCertificateSigned {
            // This copy is certificate-signed: an ad-hoc build must not be accepted as an update.
            check("updater: builds from another signer are rejected", {
                if case let .failed(message) = good.phase { return message.contains("same developer") }
                return false
            }(), "\(good.phase)")
        } else {
            check("updater: a valid newer release is downloaded, verified and staged", good.phase == .ready("1.0.\(newBuild)"), "\(good.phase)")
        }

        // The install script: swap, and roll back when the new bundle is missing.
        let script = root.appendingPathComponent("install.sh")
        try? Updater.installScript.write(to: script, atomically: true, encoding: .utf8)
        let target = root.appendingPathComponent("Installed/Pasty.app", isDirectory: true)
        let staged = root.appendingPathComponent("Staged/Pasty.app", isDirectory: true)
        for (dir, marker) in [(target, "old"), (staged, "new")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? marker.write(to: dir.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        waiter.arguments = ["0.3"]
        try? waiter.run()
        let swapped = shell("/bin/sh", [script.path, "\(waiter.processIdentifier)", target.path, staged.path, "no"])
        let marker = try? String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
        check("install script replaces the app after Pasty quits", swapped && marker == "new" && !fm.fileExists(atPath: target.path + ".pasty-previous"), "marker: \(marker ?? "nil")")
        _ = shell("/bin/sh", [script.path, "999999", target.path, root.appendingPathComponent("missing.app").path, "no"])
        let afterFailure = try? String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
        check("install script rolls back when the new app is missing", afterFailure == "new")
    }

    // MARK: - File previews

    /// A copied screenshot file (as CleanShot copies it) gets a real image thumbnail.
    private func testFilePreview() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CleanShot smoke \(UUID().uuidString.prefix(6))@2x.png")
        try? Self.demoImage().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let started = ContinuousClock.now
        let thumbnail = await FileThumbnails.shared.thumbnail(path: url.path, size: 640)
        results.largeContent["file thumbnail (QuickLook) ms"] = ((ContinuousClock.now - started).milliseconds * 10).rounded() / 10
        check("copied image file gets a real preview", thumbnail != nil)
        let size = await FileThumbnails.shared.pixelSize(path: url.path)
        check("copied image file reports its pixel size", size == CGSize(width: 1_200, height: 760), "\(String(describing: size))")
        check("image files are recognised for content previews", FileThumbnails.hasContentPreview(url.path))
        check("apps keep their icon", !FileThumbnails.hasContentPreview("/Applications/Safari.app"))

        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        check("copied file is recorded", await waitFor(seconds: 5) { self.model.items.first?.filePath == url.path })
    }

    // MARK: - Mouse

    private func clickRow(_ row: Int, in table: NSTableView, count: Int) {
        guard let window = table.window else { return }
        let rect = table.convert(table.rect(ofRow: row), to: nil)
        let screenPoint = window.convertPoint(toScreen: NSPoint(x: rect.midX, y: rect.midY))
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        let source = CGEventSource(stateID: .combinedSessionState)
        for click in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func testMouse() async {
        panel.show()
        await settle()
        guard let table = Self.find(ClipTableView.self, in: panel.panel.contentView), model.items.count >= 3 else {
            return check("history table found", false)
        }
        let target = model.items[2]
        // Table rows are each section's heading followed by its items.
        var row = 0
        var found: Int?
        for section in model.sections {
            row += 1
            if let index = section.items.firstIndex(where: { $0.id == target.id }) { found = row + index; break }
            row += section.items.count
        }
        guard let row = found else { return check("row for click found", false) }
        table.scrollRowToVisible(row)
        await nextTurn()

        let clipboardBefore = pasteboard.changeCount
        clickRow(row, in: table, count: 1)
        check("single click selects the item", await waitFor(seconds: 2) { self.model.selectedID == target.id })
        check("single click shows its preview", await waitFor(seconds: 3) { self.model.detail?.itemID == target.id })
        try? await Task.sleep(for: .milliseconds(300))
        check("single click doesn't paste or close the panel", panel.isVisible && pasteboard.changeCount == clipboardBefore)
        check("search field keeps focus after a click", isSearchFieldFocused)

        coordinator.pasteCoordinator.isAccessibilityTrusted = { false } // copy only: don't paste into the runner
        clickRow(row, in: table, count: 2)
        check("double click uses the item", await waitFor(seconds: 3) { !self.panel.isVisible && self.pasteboard.changeCount != clipboardBefore })
        coordinator.pasteCoordinator.isAccessibilityTrusted = { AccessibilityPermission.isGranted }
        coordinator.hud.dismissForTesting()
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        var stack = [view]
        while let current = stack.popLast() {
            if let match = current as? T { return match }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }

    // MARK: - Scrolling

    /// Fills history with 2,000 mixed entries, then scrolls the list in 40 pt steps, timing the
    /// synchronous layout + draw of each step. At 120 Hz a frame has 8.3 ms.
    private func testScrollPerformance() async {
        let kinds: [(String, Data)] = [
            (PasteboardType.string, Data("let value = try await service.fetch(id: 42, retries: 3)\nreturn value".utf8)),
            (PasteboardType.string, Data("https://example.com/articles/scrolling-at-120-hz".utf8)),
            (PasteboardType.string, Data("#3B82F6".utf8)),
            (PasteboardType.string, Data("Meeting notes: ship the release on Friday after QA signs off".utf8)),
            (PasteboardType.fileURL, Data(URL(fileURLWithPath: "/System/Applications/TextEdit.app").absoluteString.utf8)),
            (PasteboardType.png, Self.demoImage()),
        ]
        let sources = [("com.apple.Safari", "Safari"), ("com.apple.dt.Xcode", "Xcode"), ("com.apple.Notes", "Notes"), ("com.apple.finder", "Finder"), ("com.apple.Terminal", "Terminal")]
        for index in 0..<2_000 {
            let (type, base) = kinds[index % kinds.count]
            var data = base
            if type == PasteboardType.string { data.append(Data(" #\(index)".utf8)) }
            if type == PasteboardType.png, index > 6 { continue } // a few images are enough
            let snapshot = PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: [PasteboardRepresentation(type: type, data: data)])])
            guard var draft = ContentAnalyzer.analyze(snapshot) else { continue }
            draft.source = SourceApp(bundleID: sources[index % sources.count].0, name: sources[index % sources.count].1)
            draft.date = Date().addingTimeInterval(-Double(index) * 97)
            _ = try? await store.insert(draft, duplicates: .keepAll, maxHistory: 50_000)
        }
        await model.reload()
        panel.show()
        await settle()

        guard let scrollView = Self.largestScrollView(in: panel.panel.contentView) else {
            return check("list scroll view found", false)
        }
        let clip = scrollView.contentView
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        results.scroll["rows"] = Double(model.items.count)
        results.scroll["document height pt"] = (maxY).rounded()

        var samples: [Double] = []
        var y: CGFloat = 0
        // Scroll down 400 steps (or to the end), then back up — like a long trackpad fling.
        for step in 0..<800 {
            y = step < 400 ? min(maxY, y + 40) : max(0, y - 40)
            let start = DispatchTime.now().uptimeNanoseconds
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
            panel.panel.displayIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            if step % 20 == 0 { await nextTurn() } // let async thumbnail loads land, like real frames
        }
        samples.sort()
        func pct(_ p: Double) -> Double { (samples[min(samples.count - 1, Int(Double(samples.count) * p))] * 100).rounded() / 100 }
        results.scroll["frame median ms"] = pct(0.5)
        results.scroll["frame p95 ms"] = pct(0.95)
        results.scroll["frame p99 ms"] = pct(0.99)
        results.scroll["frame max ms"] = (samples.last! * 100).rounded() / 100
        results.scroll["frames over 8.3 ms (120 Hz budget)"] = Double(samples.filter { $0 > 8.33 }.count)
        panel.hide()
        check("list scrolls within the 120 Hz frame budget (p95 < 8.3 ms)", pct(0.95) < 8.33, "p95 \(pct(0.95)) ms")
    }

    private static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        var stack = [view]
        while let current = stack.popLast() {
            if let scroll = current as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) {
                best = scroll
            }
            stack.append(contentsOf: current.subviews)
        }
        return best
    }

    // MARK: - Stress & idle

    private func testStress() async {
        let before = Self.memoryMB() ?? 0
        for _ in 0..<100 {
            panel.show()
            panel.panel.displayIfNeeded()
            panel.hide()
        }
        await settle()
        results.stressCycles = 100
        let growth = (Self.memoryMB() ?? 0) - before
        results.stressMemoryGrowthMB = (growth * 10).rounded() / 10
        check("100 rapid open/close cycles leave the panel closed", !panel.isVisible)
        check("open/close cycles don’t leak (< 25 MB growth)", growth < 25, "\(growth) MB")
    }

    private func measureIdle() async {
        panel.hide()
        try? await Task.sleep(for: .seconds(2))
        let cpuStart = Self.cpuSeconds()
        let wallStart = ContinuousClock.now
        try? await Task.sleep(for: .seconds(10))
        let wall = (ContinuousClock.now - wallStart).milliseconds / 1_000
        results.idleCPUPercent = ((Self.cpuSeconds() - cpuStart) / wall * 100 * 100).rounded() / 100
        results.residentMemoryMB = Self.memoryMB()
        check("idle CPU under 1%", (results.idleCPUPercent ?? 100) < 1, "\(results.idleCPUPercent ?? -1)%")
    }

    // MARK: - Screenshots

    private func captureScreenshots() async {
        try? await store.clear(keepPinned: false)
        await model.reload()

        // Empty states first.
        for (name, appearance) in [("empty-light", NSAppearance.Name.aqua), ("empty-dark", .darkAqua)] {
            await screenshotPanel(name, appearance: appearance) { _ in false }
        }
        coordinator.setPaused(true)
        await screenshotPanel("paused-dark", appearance: .darkAqua) { _ in false }
        coordinator.setPaused(false)

        await seedDemoContent()
        await screenshotPanel("panel-light", appearance: .aqua) { $0.isCode }
        await screenshotPanel("panel-dark", appearance: .darkAqua) { $0.kind == .url }
        await screenshotPanel("panel-search-light", appearance: .aqua, query: "swift") { _ in true }
        await screenshotPanel("panel-image-dark", appearance: .darkAqua) { $0.kind == .image }
        await screenshotPanel("panel-color-light", appearance: .aqua) { $0.title.hasPrefix("#") }
        await screenshotPanel("panel-files-dark", appearance: .darkAqua) { $0.kind == .file && $0.fileCount > 1 }
        await screenshotPanel("panel-imagefile-light", appearance: .aqua) { $0.title.hasPrefix("CleanShot") }
        await screenshotPanel("panel-imagefile-dark", appearance: .darkAqua) { $0.title.hasPrefix("CleanShot") }
        await screenshotPanel("panel-nomatch-light", appearance: .aqua, query: "nothing matches this") { _ in false }

        // Toast.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        coordinator.hud.show(.init(symbol: "hand.raised", title: "Copied — press ⌘V to paste", detail: "To paste automatically, allow Pasty in System Settings › Privacy & Security › Accessibility."), duration: 5)
        try? await Task.sleep(for: .milliseconds(400))
        if let number = coordinator.hud.windowNumber { shoot("toast-dark", windowNumber: number) }

        // Settings, every pane, both appearances.
        coordinator.showSettings()
        try? await Task.sleep(for: .milliseconds(500))
        if let controller = coordinator.settingsController, let window = controller.window {
            check("settings window opens", window.isVisible)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                for pane in SettingsPane.allCases {
                    controller.state.pane = pane
                    try? await Task.sleep(for: .milliseconds(450))
                    window.displayIfNeeded()
                    shoot("settings-\(pane.rawValue)-\(appearance == .aqua ? "light" : "dark")", windowNumber: window.windowNumber)
                }
            }
            window.close()
        }
        NSApp.appearance = nil
        check("screenshots captured", results.screenshots.count >= 17, "\(results.screenshots.count)")
    }

    private func screenshotPanel(_ name: String, appearance: NSAppearance.Name, query: String = "", select: (ClipItem) -> Bool) async {
        NSApp.appearance = NSAppearance(named: appearance)
        panel.show()
        model.query = query
        try? await Task.sleep(for: .milliseconds(300))
        if let item = model.items.first(where: select) { model.select(item) }
        try? await Task.sleep(for: .milliseconds(600))
        panel.panel.displayIfNeeded()
        shoot(name, windowNumber: panel.panel.windowNumber)
        panel.hide()
        await nextTurn()
    }

    private func shoot(_ name: String, windowNumber: Int) {
        let path = output.appendingPathComponent("\(name).png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(windowNumber)", path]
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
            results.screenshots.append("\(name).png")
        }
    }

    /// Representative entries so screenshots show every row style.
    private func seedDemoContent() async {
        func snapshot(_ reps: [(String, Data)]) -> PasteboardSnapshot {
            PasteboardSnapshot(items: [PasteboardItemSnapshot(representations: reps.map { PasteboardRepresentation(type: $0.0, data: $0.1) })])
        }
        let code = """
        func makePanel() -> NSPanel {
            let panel = PastyPanel(contentRect: frame, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            return panel
        }
        """
        let screenshotDir = FileManager.default.temporaryDirectory.appendingPathComponent("PastyDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)
        let screenshot = screenshotDir.appendingPathComponent("CleanShot 2026-10-11 at 4.33.04 PM@2x.png")
        try? Self.demoImage().write(to: screenshot)
        let files = [URL(fileURLWithPath: "/Applications/Safari.app"), URL(fileURLWithPath: "/System/Applications/TextEdit.app"), URL(fileURLWithPath: "/System/Applications/Notes.app")]
        let entries: [(PasteboardSnapshot, String, String, TimeInterval, Bool)] = [
            (snapshot([(PasteboardType.string, Data("Quarterly planning notes — draft 3".utf8))]), "com.apple.Notes", "Notes", 60 * 60 * 24 * 9, false),
            (snapshot([(PasteboardType.string, Data("Ship the release notes before Friday's sync".utf8))]), "com.apple.Notes", "Notes", 60 * 60 * 26, false),
            (PasteboardSnapshot(items: files.map { PasteboardItemSnapshot(representations: [PasteboardRepresentation(type: PasteboardType.fileURL, data: Data($0.absoluteString.utf8))]) }), "com.apple.finder", "Finder", 60 * 60 * 5, false),
            (snapshot([(PasteboardType.string, Data("#5B5BD6".utf8))]), "com.apple.Safari", "Safari", 60 * 50, false),
            (snapshot([(PasteboardType.fileURL, Data(screenshot.absoluteString.utf8))]), "com.apple.finder", "Finder", 60 * 2, false),
            (snapshot([(PasteboardType.png, Self.demoImage())]), "com.apple.Preview", "Preview", 60 * 31, false),
            (snapshot([(PasteboardType.string, Data("https://ui.shadcn.com/docs/components/command".utf8))]), "com.apple.Safari", "Safari", 60 * 12, true),
            (snapshot([(PasteboardType.string, Data("swift test --package-path PastyCore".utf8))]), "com.apple.Terminal", "Terminal", 60 * 4, false),
            (snapshot([(PasteboardType.string, Data(code.utf8))]), "com.apple.dt.Xcode", "Xcode", 40, false),
        ]
        for entry in entries {
            guard var draft = ContentAnalyzer.analyze(entry.0) else { continue }
            draft.source = SourceApp(bundleID: entry.1, name: entry.2)
            draft.date = Date().addingTimeInterval(-entry.3)
            if let outcome = try? await store.insert(draft, duplicates: .keepAll), entry.4, let id = outcome.itemID {
                try? await store.setPinned(true, for: id)
            }
        }
        await model.reload()
    }

    private static func demoImage() -> Data {
        let width = 1_200, height = 760
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let colors = [CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1), CGColor(red: 0.32, green: 0.32, blue: 0.36, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1))
        let card = CGPath(roundedRect: CGRect(x: 200, y: 200, width: 800, height: 360), cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.addPath(card)
        context.fillPath()
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: - Helpers

    private func waitFor(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(250))
    }

    private func nextTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    /// Physical footprint — the figure Activity Monitor shows as "Memory".
    private static func memoryMB() -> Double? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        return (Double(info.ri_phys_footprint) / 1_048_576 * 10).rounded() / 10
    }
}

/// Measures main-thread responsiveness: a background timer posts to the main queue every 5 ms
/// and records how late each post runs. Any UI work blocking the main thread shows up as a stall.
final class MainThreadWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.pasty.watchdog", qos: .userInteractive)
    private let lock = NSLock()
    private var samples: [Double] = []
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let watchdog = self else { return }
            let posted = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                watchdog.record(Double(DispatchTime.now().uptimeNanoseconds - posted) / 1_000_000)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func reset() {
        lock.withLock { samples.removeAll() }
    }

    private func record(_ delay: Double) {
        lock.withLock { samples.append(delay) }
    }

    func snapshot() -> (max: Double, p99: Double) {
        let sorted = lock.withLock { samples.sorted() }
        guard !sorted.isEmpty else { return (0, 0) }
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        return ((sorted.last! * 10).rounded() / 10, (p99 * 10).rounded() / 10)
    }

    func stop() -> (max: Double, p99: Double) {
        timer?.cancel()
        timer = nil
        return snapshot()
    }
}

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
