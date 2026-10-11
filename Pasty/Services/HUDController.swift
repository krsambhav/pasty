import AppKit
import SwiftUI

struct HUDMessage: Equatable {
    var symbol: String
    var title: String
    var detail: String?
}

/// A small, non-interactive confirmation bubble near the bottom of the active screen — the same
/// idiom macOS uses for volume and brightness.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideTask: Task<Void, Never>?

    var isShowing: Bool { panel?.isVisible == true }

    func dismissForTesting() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }
    var windowNumber: Int? { panel?.windowNumber }

    func show(_ message: HUDMessage, duration: TimeInterval = 2.2) {
        let panel = self.panel ?? makePanel()
        hosting?.rootView = HUDView(message: message)
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 260, height: 44)

        let screen = NSScreen.screenContainingMouse ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 96, width: size.width, height: size.height), display: true)
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
        }
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: [message.title, message.detail].compactMap { $0 }.joined(separator: ". "), .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.orderOutIfFaded() }
        })
    }

    private func orderOutIfFaded() {
        if let panel, panel.alphaValue == 0 { panel.orderOut(nil) }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: HUDView(message: HUDMessage(symbol: "", title: "")))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }
}

/// A Sonner-style toast: icon, title, optional description, on a bordered card.
struct HUDView: View {
    let message: HUDMessage

    var body: some View {
        HStack(alignment: message.detail == nil ? .center : .top, spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(message.title)
                    .font(.shadSMSemibold)
                    .foregroundStyle(Theme.foreground)
                if let detail = message.detail {
                    Text(detail)
                        .font(Typeface.font(12.5))
                        .foregroundStyle(Theme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(width: message.detail == nil ? nil : 356, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.popover))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .padding(1)
    }

    private var tint: Color {
        switch message.symbol {
        case let symbol where symbol.hasPrefix("checkmark"): Theme.success
        case let symbol where symbol.hasPrefix("exclamationmark"): Theme.destructive
        case "hand.raised": Theme.warning
        default: Theme.foreground
        }
    }
}

extension NSScreen {
    /// The display under the pointer — where the user's attention is.
    static var screenContainingMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
