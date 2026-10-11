import AppKit
import PastyCore

enum PasteAction: Sendable {
    /// Restore to the clipboard and paste into the previously focused app.
    case paste
    /// Paste with all formatting stripped.
    case pastePlainText
    /// Restore to the clipboard only.
    case copy
}

/// Turns "use this entry" into a single seamless action:
/// restore clipboard → dismiss panel → ensure the target app is frontmost → post ⌘V.
@MainActor
final class PasteCoordinator {
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let model: PanelModel
    private let hud: HUDController
    weak var panel: PanelController?
    private var hasPromptedForAccessibility = false
    /// Injectable for the smoke test, which exercises the permission-denied path.
    var isAccessibilityTrusted: () -> Bool = { AccessibilityPermission.isGranted }
    /// Whether to show the system permission prompt when trust is missing.
    var promptsForAccessibility = true
    private var isPerforming = false

    init(store: ClipboardStore, monitor: ClipboardMonitor, model: PanelModel, hud: HUDController) {
        self.store = store
        self.monitor = monitor
        self.model = model
        self.hud = hud
    }

    func perform(_ action: PasteAction, on item: ClipItem) {
        guard !isPerforming else { return }
        isPerforming = true
        Task {
            defer { isPerforming = false }
            await run(action, on: item)
        }
    }

    @discardableResult
    func run(_ action: PasteAction, on item: ClipItem) async -> Bool {
        let stored: PasteboardSnapshot?
        do {
            stored = try await store.snapshot(for: item.id)
        } catch {
            stored = nil
        }
        guard var snapshot = stored else {
            panel?.hide()
            hud.show(.init(symbol: "exclamationmark.triangle", title: "Couldn’t restore this item", detail: "Its stored contents are missing or unreadable."))
            return false
        }
        // Dismiss first: the panel disappears the instant the user chooses, whatever the size.
        let target = panel?.previousApp
        panel?.hide()

        if action == .pastePlainText {
            let original = snapshot
            snapshot = await Task.detached(priority: .userInitiated) { original.plainTextOnly() ?? original }.value
        }
        // Written on the monitor's queue (never blocking the main thread) so the change is never
        // recorded as a new entry.
        await monitor.write(snapshot)

        Task {
            try? await store.markUsed(item.id)
            await model.reload()
        }

        guard action != .copy else {
            hud.show(.init(symbol: "checkmark.circle", title: "Copied", detail: nil), duration: 0.9)
            return true
        }
        guard isAccessibilityTrusted() else {
            explainMissingPermission()
            return false
        }

        if let target, !target.isTerminated {
            _ = await ActivationWaiter.activate(target)
        }
        // Let the window server finish removing our panel before the keystroke is routed.
        await nextRunLoopTurn()
        guard KeystrokeSender.pasteCommand() else {
            hud.show(.init(symbol: "exclamationmark.triangle", title: "Copied — press ⌘V to paste", detail: "Pasty couldn’t send the paste keystroke."))
            return false
        }
        return true
    }

    /// Opens a link in the browser or reveals a file in Finder.
    func open(_ item: ClipItem) {
        switch item.kind {
        case .file:
            guard let path = item.filePath else { return }
            panel?.hide()
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .url:
            Task {
                guard let text = try? await store.preview(for: item.id),
                      let url = ContentAnalyzer.detectURL(in: text) else { return }
                panel?.hide()
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    private func explainMissingPermission() {
        hud.show(
            .init(
                symbol: "hand.raised",
                title: "Copied — press ⌘V to paste",
                detail: "To paste automatically, allow Pasty in System Settings › Privacy & Security › Accessibility."
            ),
            duration: 3.5
        )
        if !hasPromptedForAccessibility, promptsForAccessibility {
            hasPromptedForAccessibility = true
            AccessibilityPermission.requestWithPrompt()
        }
    }

    private func nextRunLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
