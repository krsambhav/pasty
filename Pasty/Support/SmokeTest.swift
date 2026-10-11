import AppKit
import Darwin
import PastyCore

/// End-to-end check run by `Pasty --smoke-test <dir>` (used in CI).
///
/// Exercises the real app: the general pasteboard, the monitor, SQLite, the panel and the copy
/// path. It cannot exercise paste-into-another-app, which needs a human-granted Accessibility
/// permission; that remains a manual check (see README).
@MainActor
struct SmokeTest {
    let coordinator: AppCoordinator
    let output: URL

    private struct Results: Encodable {
        var passed = true
        var failures: [String] = []
        var notes: [String] = []
        var captureLatencyMs: Double?
        var panelOpenMs: Stats?
        var panelFirstOpenMs: Double?
        var searchFieldFocused = false
        var copyRestoredExactly = false
        var copyCreatedDuplicate = false
        var rapidCopiesRecorded: Int?
        var idleCPUPercent: Double?
        var residentMemoryMB: Double?
        var accessibilityTrusted = AccessibilityPermission.isGranted
        var pasteIntoTextEdit: String?
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

    func run() async {
        var results = Results()
        func fail(_ message: String) {
            results.passed = false
            results.failures.append(message)
        }

        let pasteboard = NSPasteboard.general
        let store = coordinator.store

        // 1. Capture: a copy made by another "app" appears in history.
        let marker = "pasty-smoke-\(UUID().uuidString)"
        let copiedAt = ContinuousClock.now
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        if await waitFor(seconds: 5, { (try? await store.search(marker).first?.title) == marker }) {
            results.captureLatencyMs = (ContinuousClock.now - copiedAt).milliseconds
        } else {
            fail("Copied text was not recorded within 5 s")
        }

        // 2. Rapid copies: the monitor sees the latest, never duplicates, never crashes.
        let before = (try? await store.count()) ?? 0
        for index in 0..<20 {
            pasteboard.clearContents()
            pasteboard.setString("rapid \(index) \(marker)", forType: .string)
        }
        if await waitFor(seconds: 5, { (try? await store.search("rapid 19 \(marker)").first) != nil }) {
            results.rapidCopiesRecorded = ((try? await store.count()) ?? 0) - before
        } else {
            fail("Last of 20 rapid copies was not recorded")
        }

        // 3. Panel: open/close cycles, timing, focus.
        await coordinator.model.reload()
        let panel = coordinator.panelController!
        var samples: [Double] = []
        for cycle in 0..<30 {
            let start = ContinuousClock.now
            panel.show()
            panel.panel.displayIfNeeded()
            let elapsed = (ContinuousClock.now - start).milliseconds
            if cycle == 0 {
                results.panelFirstOpenMs = elapsed
                results.searchFieldFocused = panel.panel.firstResponder === panel.searchBridge.field?.currentEditor()
                    || panel.panel.firstResponder === panel.searchBridge.field
                if !panel.isVisible { fail("Panel did not become visible") }
            }
            samples.append(elapsed)
            await nextTurn()
            panel.hide()
            await nextTurn()
        }
        results.panelOpenMs = Stats(samples)
        if !results.searchFieldFocused { fail("Search field was not first responder after opening") }

        // 4. Copy an older entry back: exact restore, and no new history entry.
        if let target = try? await store.search(marker).first(where: { $0.title == marker }) {
            let countBefore = (try? await store.count()) ?? 0
            pasteboard.clearContents()
            pasteboard.setString("something else \(marker)", forType: .string)
            _ = await waitFor(seconds: 5, { ((try? await store.count()) ?? 0) > countBefore })
            let countAfterOther = (try? await store.count()) ?? 0

            panel.show()
            await coordinator.pasteCoordinator.run(.copy, on: target)
            results.copyRestoredExactly = pasteboard.string(forType: .string) == marker
            coordinator.monitor.checkNow()
            try? await Task.sleep(for: .milliseconds(800))
            let countAfterCopy = (try? await store.count()) ?? 0
            results.copyCreatedDuplicate = countAfterCopy != countAfterOther
            if !results.copyRestoredExactly { fail("Copying an entry back did not restore its content") }
            if results.copyCreatedDuplicate { fail("Copying an entry back created a new history entry") }
            if panel.isVisible { fail("Panel stayed open after choosing an entry") }
        } else {
            fail("Could not find the captured entry for the copy-back check")
        }

        // 5. Idle cost: CPU time consumed over 10 s doing nothing, and resident memory.
        let cpuStart = Self.cpuSeconds()
        let wallStart = ContinuousClock.now
        try? await Task.sleep(for: .seconds(10))
        let wall = (ContinuousClock.now - wallStart).milliseconds / 1_000
        results.idleCPUPercent = ((Self.cpuSeconds() - cpuStart) / wall * 100 * 100).rounded() / 100
        results.residentMemoryMB = Self.residentMemoryMB()

        // 6. Real paste into another app (only possible when Accessibility is granted).
        if results.accessibilityTrusted {
            results.pasteIntoTextEdit = await pasteIntoTextEdit(marker: marker)
            if results.pasteIntoTextEdit != "verified" {
                results.notes.append("Paste into TextEdit: \(results.pasteIntoTextEdit ?? "not run")")
            }
        } else {
            results.notes.append("Accessibility not granted: paste-into-app (synthetic ⌘V) was not exercised.")
        }

        // 7. Screenshots of the panel with representative content, in both appearances.
        results.screenshots = await captureScreenshots()

        write(results)
        NSApp.terminate(nil)
        exit(results.passed ? 0 : 1)
    }

    // MARK: Paste into TextEdit

    private func pasteIntoTextEdit(marker: String) async -> String {
        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            return "TextEdit not found"
        }
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("pasty-smoke-\(UUID().uuidString).txt")
        try? Data().write(to: document)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.open([document], withApplicationAt: textEdit, configuration: configuration) else {
            return "Could not open TextEdit"
        }
        defer { app.terminate() }
        let frontmost = await waitFor(seconds: 10) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
                && Self.focusedValue(pid: app.processIdentifier) != nil
        }
        guard frontmost else { return "TextEdit never became frontmost with a focused text view" }
        guard let item = try? await coordinator.store.search(marker).first(where: { $0.title == marker }) else {
            return "Marker item missing"
        }

        coordinator.panelController.show()
        await nextTurn()
        let sent = await coordinator.pasteCoordinator.run(.paste, on: item)
        guard sent else { return "Paste keystroke was not sent" }
        let landed = await waitFor(seconds: 5) {
            Self.focusedValue(pid: app.processIdentifier)?.contains(marker) == true
        }
        return landed ? "verified" : "Keystroke sent but text did not appear (value: \(Self.focusedValue(pid: app.processIdentifier) ?? "nil"))"
    }

    /// Reads the focused element's text through the Accessibility API.
    private static func focusedValue(pid: pid_t) -> String? {
        let application = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXFocusedUIElement" as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, "AXValue" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Screenshots

    private func captureScreenshots() async -> [String] {
        await seedDemoContent()
        let panel = coordinator.panelController!
        var files: [String] = []
        let shots: [(String, NSAppearance.Name, String, Int)] = [
            ("panel-light", .aqua, "", 1),
            ("panel-dark", .darkAqua, "", 1),
            ("panel-search-dark", .darkAqua, "swift", 0),
            ("panel-image-light", .aqua, "", 3),
        ]
        for (name, appearance, query, selection) in shots {
            NSApp.appearance = NSAppearance(named: appearance)
            panel.show()
            coordinator.model.query = query
            try? await Task.sleep(for: .milliseconds(250))
            if coordinator.model.items.indices.contains(selection) {
                coordinator.model.select(coordinator.model.items[selection])
            }
            try? await Task.sleep(for: .milliseconds(600))
            panel.panel.displayIfNeeded()
            let path = output.appendingPathComponent("\(name).png").path
            if Self.screencapture(windowNumber: panel.panel.windowNumber, to: path) {
                files.append("\(name).png")
            }
            panel.hide()
            await nextTurn()
        }
        NSApp.appearance = nil
        return files
    }

    private static func screencapture(windowNumber: Int, to path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(windowNumber)", path]
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
    }

    /// Representative entries so screenshots show every row style.
    private func seedDemoContent() async {
        let store = coordinator.store
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
        let entries: [(PasteboardSnapshot, String, String, TimeInterval, Bool)] = [
            (snapshot([(PasteboardType.string, Data("Ship the release notes before Friday's sync".utf8))]), "com.apple.Notes", "Notes", 60 * 60 * 26, false),
            (snapshot([(PasteboardType.fileURL, Data(URL(fileURLWithPath: "/Applications/Safari.app").absoluteString.utf8))]), "com.apple.finder", "Finder", 60 * 60 * 5, false),
            (snapshot([(PasteboardType.string, Data("#5B5BD6".utf8))]), "com.apple.Safari", "Safari", 60 * 50, false),
            (snapshot([(PasteboardType.png, Self.demoImage())]), "com.apple.Preview", "Preview", 60 * 31, false),
            (snapshot([(PasteboardType.string, Data("https://developer.apple.com/documentation/swiftui".utf8))]), "com.apple.Safari", "Safari", 60 * 12, true),
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
        await coordinator.model.reload()
    }

    private static func demoImage() -> Data {
        let width = 1_200, height = 760
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        let colors = [CGColor(red: 0.36, green: 0.36, blue: 0.84, alpha: 1), CGColor(red: 1, green: 0.48, blue: 0.35, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fill(CGRect(x: 160, y: 160, width: 520, height: 300))
        guard let image = context.makeImage() else { return Data() }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
    }

    private func write(_ results: Results) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: output.appendingPathComponent("results.json"))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private func waitFor(seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
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
    private static func residentMemoryMB() -> Double? {
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

extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
