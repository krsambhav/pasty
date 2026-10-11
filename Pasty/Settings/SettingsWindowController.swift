import AppKit
import Observation
import PastyCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, clipboard, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .clipboard: "Clipboard"
        case .privacy: "Privacy"
        case .about: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Shortcut, startup and appearance."
        case .clipboard: "What Pasty keeps, and for how long."
        case .privacy: "What Pasty never records."
        case .about: "Version and acknowledgements."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clipboard: "doc.on.clipboard"
        case .privacy: "lock"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsState {
    var pane: SettingsPane = .general
}

/// The Settings window: shadcn's settings layout — a sidebar nav and a content column of
/// bordered sections — in a transparent-titlebar window.
@MainActor
final class SettingsWindowController: NSWindowController {
    let state = SettingsState()

    init(coordinator: AppCoordinator) {
        let root = SettingsRootView(coordinator: coordinator, state: state)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Pasty Settings"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 780, height: 560))
        window.backgroundColor = Theme.NS.background
        window.setFrameAutosaveName("PastySettingsWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(pane: SettingsPane? = nil) {
        guard let window else { return }
        if let pane { state.pane = pane }
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsRootView: View {
    let coordinator: AppCoordinator
    @Bindable var state: SettingsState

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Separator(vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.pane.title)
                            .font(Typeface.font(20, .semibold))
                            .foregroundStyle(Theme.foreground)
                        Text(state.pane.subtitle)
                            .font(.shadSM)
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    .padding(.bottom, 18)
                    Separator().padding(.bottom, 22)
                    switch state.pane {
                    case .general: GeneralSettingsView(coordinator: coordinator)
                    case .clipboard: ClipboardSettingsView(coordinator: coordinator)
                    case .privacy: PrivacySettingsView(coordinator: coordinator)
                    case .about: AboutSettingsView()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Theme.background)
        .environment(\.font, .shadSM)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pasty").font(Typeface.font(14, .bold)).foregroundStyle(Theme.foreground)
                    Text("Settings").font(.shadXS).foregroundStyle(Theme.mutedForeground)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 44)
            .padding(.bottom, 18)

            ForEach(SettingsPane.allCases) { pane in
                SidebarItem(pane: pane, isSelected: state.pane == pane) { state.pane = pane }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(width: 200)
        .background(Theme.muted.opacity(0.4))
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 16)
                Text(pane.title).font(Typeface.font(13.5, .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Theme.foreground : Theme.mutedForeground)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                    .fill(isSelected ? Theme.accent : hovering ? Theme.accent.opacity(0.5) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
