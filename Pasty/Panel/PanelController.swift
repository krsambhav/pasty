import AppKit
import Carbon.HIToolbox
import PastyCore
import Quartz
import SwiftUI

/// A borderless, non-activating panel. It takes keyboard focus *without* activating Pasty, so
/// the app the user was working in stays frontmost — which is what makes paste-back seamless.
final class PastyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Holds a reference to the AppKit search field created inside SwiftUI, so focus can be set
/// synchronously the moment the panel appears.
@MainActor
final class SearchFieldBridge {
    weak var field: NSTextField?

    func focus() {
        guard let field, let window = field.window else { return }
        window.makeFirstResponder(field)
        // Place the caret at the end rather than selecting everything.
        field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let panelSize = NSSize(width: 760, height: 476)

    let panel: PastyPanel
    let searchBridge = SearchFieldBridge()
    let quickLook: QuickLookController
    private let model: PanelModel
    private let preferences: Preferences
    private var keyMonitor: Any?
    /// The app that was frontmost when the panel opened — the paste target.
    private(set) var previousApp: NSRunningApplication?

    var onWillShow: (() -> Void)?
    var onCommand: ((PanelCommand) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(model: PanelModel, preferences: Preferences) {
        self.model = model
        self.preferences = preferences
        panel = PastyPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        quickLook = QuickLookController(store: model.store, host: panel)
        super.init()
        model.onSelectionChange = { [weak self] item in self?.quickLook.follow(item) }
        configurePanel()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        // Follow the user to whichever Space is active, including over full-screen apps.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.setAccessibilityLabel("Pasty clipboard history")

        let root = PanelRootView(model: model, searchBridge: searchBridge) { [weak self] command in
            self?.onCommand?(command)
        }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }

    /// Renders the panel once off-screen at launch so the first real opening is as fast as the rest.
    func prewarm() {
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: Showing & hiding

    func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func show() {
        // The paste target. When Pasty itself is frontmost (e.g. Settings is open) there is no
        // other app to paste into, and an older target must not be reused.
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        onWillShow?()
        model.prepareForPresentation()
        position()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if let field = searchBridge.field {
            panel.makeFirstResponder(field)
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.09
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        panel.invalidateShadow()
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        quickLook.close()
        model.showsQuickKeys = false
        panel.orderOut(nil)
        // If Pasty became the frontmost app (e.g. opened from the menu bar), hand focus back.
        // (`NSApp.isActive` can't be used: it reads true whenever the non-activating panel is key.)
        let pastyIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if pastyIsFrontmost, !NSApp.windows.contains(where: { $0.isVisible && $0 !== panel && $0.level == .normal }) {
            previousApp?.activate()
        }
    }

    /// Centered horizontally, slightly above center, on the display under the pointer.
    private func position() {
        guard let screen = NSScreen.screenContainingMouse ?? NSScreen.main else { return }
        panel.setFrame(Self.frame(in: screen.visibleFrame), display: false)
    }

    /// Where the panel goes within a screen's visible frame: centered horizontally, a little above
    /// center, and always fully on screen — even on displays smaller than the panel's margins allow.
    static func frame(in visible: NSRect, size: NSSize = panelSize) -> NSRect {
        let margin: CGFloat = 12
        var x = (visible.midX - size.width / 2).rounded()
        var y = (visible.minY + visible.height * 0.56 - size.height / 2).rounded()
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        y = min(max(y, visible.minY + margin), visible.maxY - size.height - margin)
        // A display narrower or shorter than the panel: pin to the top-left of the visible area.
        if size.width + margin * 2 > visible.width { x = visible.minX }
        if size.height + margin * 2 > visible.height { y = visible.maxY - size.height }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere outside dismisses — but not while a context menu is tracking.
        guard panel.isVisible else { return }
        // Quick Look can't hold focus while Pasty isn't the active app, but it still takes it
        // from the panel as it appears or is clicked. Unless the user clicked elsewhere, take it back.
        let reclaim = quickLook.isVisible && quickLook.tookFocus
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isKeyWindow else { return }
                if reclaim {
                    self.panel.makeKey()
                    return
                }
                self.hide()
            }
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.panel || (event.window is QLPreviewPanel && self.quickLook.isVisible) else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            model.showsQuickKeys = flags == .command
            return false
        }
        let command = flags.contains(.command)
        let selected = model.selectedItem

        switch Int(event.keyCode) {
        case kVK_Escape:
            if quickLook.isVisible { quickLook.close() } else { hide() }
        case kVK_ANSI_Y where command:
            quickLook.toggle(selected)
        case kVK_UpArrow:
            command ? model.moveToEdge(top: true) : model.moveSelection(by: -1)
        case kVK_DownArrow:
            command ? model.moveToEdge(top: false) : model.moveSelection(by: 1)
        case kVK_PageUp:
            model.moveSelection(by: -9)
        case kVK_PageDown:
            model.moveSelection(by: 9)
        case kVK_Home where !command:
            model.moveToEdge(top: true)
        case kVK_End where !command:
            model.moveToEdge(top: false)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let selected else { return true }
            let action: PasteAction
            if flags.contains(.shift) {
                action = .pastePlainText
            } else if command {
                action = model.primaryAction == .paste ? .copy : .paste
            } else {
                action = model.primaryAction
            }
            onCommand?(.activate(selected, action))
        case kVK_Tab:
            model.filter = model.filter == .all ? .pinned : .all
        case kVK_ANSI_P where command:
            if let selected { onCommand?(.togglePin(selected)) }
        case kVK_Delete where command, kVK_ForwardDelete where command:
            if let selected { onCommand?(.delete(selected)) }
        case kVK_ANSI_O where command:
            if let selected { onCommand?(.open(selected)) }
        case kVK_ANSI_C where command:
            // ⌘C copies the entry unless the user is copying text out of the search field.
            let editorSelection = (searchBridge.field?.currentEditor() as? NSTextView)?.selectedRange().length ?? 0
            guard editorSelection == 0, let selected else { return false }
            onCommand?(.activate(selected, .copy))
        case kVK_ANSI_Comma where command:
            onCommand?(.showSettings)
        case kVK_ANSI_W where command:
            hide()
        default:
            if command, let index = Self.quickKeyIndex(event.keyCode), flags == .command {
                guard index < model.items.count else { return true }
                onCommand?(.activate(model.items[index], model.primaryAction))
                return true
            }
            return false
        }
        return true
    }

    private static func quickKeyIndex(_ keyCode: UInt16) -> Int? {
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        return digits.firstIndex(of: Int(keyCode))
    }
}
