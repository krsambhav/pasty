import AppKit
import PastyCore
import SwiftUI

/// Shared visual constants, so spacing and tone stay consistent across every surface.
enum Design {
    static let cornerRadius: CGFloat = 16
    static let rowHeight: CGFloat = 40
    static let rowCornerRadius: CGFloat = 8
    static let listWidth: CGFloat = 318
    static let searchHeight: CGFloat = 54
    static let footerHeight: CGFloat = 36

    static func hairline(_ contrast: ColorSchemeContrast) -> Color {
        .primary.opacity(contrast == .increased ? 0.28 : 0.09)
    }

    static func selection(_ contrast: ColorSchemeContrast) -> Color {
        .primary.opacity(contrast == .increased ? 0.2 : 0.085)
    }

    static func hover(_ contrast: ColorSchemeContrast) -> Color {
        .primary.opacity(contrast == .increased ? 0.1 : 0.04)
    }
}

struct PanelRootView: View {
    let model: PanelModel
    let searchBridge: SearchFieldBridge
    let send: (PanelCommand) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, bridge: searchBridge)
            Rectangle().fill(Design.hairline(contrast)).frame(height: 0.5)
            ContentArea(model: model, send: send)
            Rectangle().fill(Design.hairline(contrast)).frame(height: 0.5)
            FooterBar(model: model, send: send)
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
        .background {
            VisualEffectBackground(material: .popover)
        }
        .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                .strokeBorder(Design.hairline(contrast), lineWidth: 0.5)
        }
    }
}

private struct ContentArea: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if model.items.isEmpty {
            EmptyStateView(state: emptyState, send: send)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ClipListView(model: model, send: send)
                    .frame(width: Design.listWidth)
                Rectangle().fill(Design.hairline(contrast)).frame(width: 0.5)
                PreviewPane(model: model, send: send)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: EmptyStateView.Kind {
        if !model.hasLoaded { return .loading }
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty { return .noResults(model.query) }
        if model.filter == .pinned { return .noPinned }
        if model.isPaused { return .paused }
        return .noHistory
    }
}

// MARK: - Search

private struct SearchBar: View {
    @Bindable var model: PanelModel
    let bridge: SearchFieldBridge

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            SearchField(text: $model.query, bridge: bridge)
                .frame(maxWidth: .infinity)
            FilterControl(filter: $model.filter)
        }
        .padding(.horizontal, 18)
        .frame(height: Design.searchHeight)
    }
}

/// An AppKit text field: it can be made first responder synchronously when the panel opens,
/// so the very first keystroke is never lost.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let bridge: SearchFieldBridge

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search clipboard history",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 18, weight: .regular)]
        )
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search clipboard history")
        bridge.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

private struct FilterControl: View {
    @Binding var filter: ClipFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ClipFilter.allCases, id: \.self) { option in
                Button {
                    filter = option
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: filter == option ? .semibold : .regular))
                        .foregroundStyle(filter == option ? .primary : .secondary)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background {
                            if filter == option {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.primary.opacity(0.09))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.04)))
        .help("Switch between All and Pinned (Tab)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter")
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer(minLength: 8)
            if let item = model.selectedItem {
                let primary = model.primaryAction
                HintButton(title: primary == .paste ? "Paste" : "Copy", keys: "↩") {
                    send(.activate(item, primary))
                }
                HintButton(title: primary == .paste ? "Copy" : "Paste", keys: "⌘↩") {
                    send(.activate(item, primary == .paste ? .copy : .paste))
                }
                HintButton(title: item.isPinned ? "Unpin" : "Pin", keys: "⌘P") {
                    send(.togglePin(item))
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Design.footerHeight)
    }

    @ViewBuilder
    private var leading: some View {
        if model.isPaused {
            Button {
                send(.resumeMonitoring)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Recording paused")
                        .foregroundStyle(.secondary)
                    Text("Resume")
                        .foregroundStyle(Color.accentColor)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Pasty isn’t recording new copies")
        } else {
            Text(countLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    private var countLabel: String {
        let count = model.items.count
        if !model.query.isEmpty { return count == 1 ? "1 match" : "\(count.formatted()) matches" }
        return count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}

private struct HintButton: View {
    let title: String
    let keys: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(hovering ? .primary : .secondary)
                KeyCap(keys)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}

struct KeyCap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

// MARK: - Empty states

struct EmptyStateView: View {
    enum Kind: Equatable {
        case loading, noHistory, noResults(String), noPinned, paused
    }

    let state: Kind
    let send: (PanelCommand) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if state != .loading {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                if state == .paused {
                    Button("Resume Recording") { send(.resumeMonitoring) }
                        .controlSize(.small)
                        .padding(.top, 6)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .loading, .noHistory: "doc.on.clipboard"
        case .noResults: "magnifyingglass"
        case .noPinned: "pin"
        case .paused: "pause.circle"
        }
    }

    private var title: String {
        switch state {
        case .loading: ""
        case .noHistory: "Nothing copied yet"
        case let .noResults(query): "No results for “\(query.trimmingCharacters(in: .whitespaces))”"
        case .noPinned: "No pinned items"
        case .paused: "Recording is paused"
        }
    }

    private var message: String {
        switch state {
        case .loading: ""
        case .noHistory: "Copy something and it will appear here."
        case .noResults: "Try a shorter or different search."
        case .noPinned: "Press ⌘P on any item to keep it here permanently."
        case .paused: "New copies aren’t being saved."
        }
    }
}
