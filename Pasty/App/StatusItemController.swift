import AppKit
import PastyCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let coordinator: AppCoordinator
    private let menu = NSMenu()
    private let openItem = NSMenuItem(title: "Open Pasty", action: #selector(openPasty), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Clipboard Monitoring", action: #selector(togglePause), keyEquivalent: "")

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = "PastyStatusItem"
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(paused: coordinator.preferences.isPaused)
            button.setAccessibilityLabel("Pasty")
            button.toolTip = "Pasty"
        }

        for item in [openItem, pauseItem] { item.target = self }
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        let quitItem = NSMenuItem(title: "Quit Pasty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.addItem(openItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    func refresh() {
        let paused = coordinator.preferences.isPaused
        pauseItem.title = paused ? "Resume Clipboard Monitoring" : "Pause Clipboard Monitoring"
        statusItem.button?.image = MenuBarIcon.image(paused: paused)
        statusItem.button?.appearsDisabled = false

        // Shown for discoverability only; the global hotkey does the real work.
        let combo = coordinator.preferences.hotKey
        if let character = KeyboardLayout.character(for: UInt16(combo.keyCode))?.lowercased(), character.count == 1 {
            openItem.keyEquivalent = character
            var mask: NSEvent.ModifierFlags = []
            if combo.modifiers & KeyCombo.command != 0 { mask.insert(.command) }
            if combo.modifiers & KeyCombo.shift != 0 { mask.insert(.shift) }
            if combo.modifiers & KeyCombo.option != 0 { mask.insert(.option) }
            if combo.modifiers & KeyCombo.control != 0 { mask.insert(.control) }
            openItem.keyEquivalentModifierMask = mask
        } else {
            openItem.keyEquivalent = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    @objc private func openPasty() {
        // Let the menu finish closing before the panel takes focus.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.coordinator.showPanel() }
        }
    }

    @objc private func togglePause() {
        coordinator.setPaused(!coordinator.preferences.isPaused)
    }

    @objc private func openSettings() {
        coordinator.showSettings()
    }
}

/// The menu bar glyph: two offset rounded sheets, echoing the app icon. Drawn as a template image
/// so macOS tints it correctly in every menu bar appearance.
enum MenuBarIcon {
    static func image(paused: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let back = NSBezierPath(roundedRect: NSRect(x: 5.75, y: 5.75, width: 9.5, height: 10.5), xRadius: 2.4, yRadius: 2.4)
            back.lineWidth = 1.4
            back.stroke()

            let frontRect = NSRect(x: 2.75, y: 1.75, width: 9.5, height: 10.5)
            // Knock out the back sheet behind the front one so the overlap reads cleanly.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: frontRect.insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let front = NSBezierPath(roundedRect: frontRect, xRadius: 2.4, yRadius: 2.4)
            front.lineWidth = 1.4
            if paused {
                front.stroke()
                let bar = NSBezierPath()
                bar.lineWidth = 1.4
                bar.lineCapStyle = .round
                bar.move(to: NSPoint(x: 6.1, y: 4.8)); bar.line(to: NSPoint(x: 6.1, y: 9.2))
                bar.move(to: NSPoint(x: 8.9, y: 4.8)); bar.line(to: NSPoint(x: 8.9, y: 9.2))
                bar.stroke()
            } else {
                front.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Pasty (paused)" : "Pasty"
        return image
    }
}
