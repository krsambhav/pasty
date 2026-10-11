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

struct HUDView: View {
    let message: HUDMessage

    var body: some View {
        HStack(alignment: message.detail == nil ? .center : .top, spacing: 10) {
            Image(systemName: message.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail = message.detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: message.detail == nil ? nil : 340, alignment: .leading)
        .background {
            VisualEffectBackground(material: .hudWindow)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .padding(1)
    }
}

extension NSScreen {
    /// The display under the pointer — where the user's attention is.
    static var screenContainingMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}

/// `NSVisualEffectView` for SwiftUI backgrounds.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
