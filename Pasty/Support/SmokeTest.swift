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

        if !results.accessibilityTrusted {
            results.notes.append("Accessibility not granted: paste-into-app (synthetic ⌘V) was not exercised.")
        }

        write(results)
        NSApp.terminate(nil)
        exit(results.passed ? 0 : 1)
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
