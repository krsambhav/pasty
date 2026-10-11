import AppKit
import PastyCore
import SwiftUI

/// A native toolbar-style Settings window built from an `NSTabViewController`, hosting one
/// SwiftUI form per pane.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true

        let panes: [(String, String, AnyView)] = [
            ("General", "gearshape", AnyView(GeneralSettingsView(coordinator: coordinator))),
            ("Clipboard", "doc.on.clipboard", AnyView(ClipboardSettingsView(coordinator: coordinator))),
            ("Privacy", "hand.raised", AnyView(PrivacySettingsView(coordinator: coordinator))),
        ]
        for (title, symbol, view) in panes {
            let hosting = NSHostingController(rootView: view.frame(width: 500).fixedSize(horizontal: false, vertical: true))
            hosting.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.title = "General"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PastySettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
