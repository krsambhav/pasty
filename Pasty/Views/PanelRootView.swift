import AppKit
import PastyCore
import SwiftUI

/// Panel layout constants.
enum Design {
    static let cornerRadius: CGFloat = Theme.radiusLarge
    static let rowHeight: CGFloat = 38
    static let listWidth: CGFloat = 322
    static let searchHeight: CGFloat = 52
    static let footerHeight: CGFloat = 40
}

/// The panel: shadcn's Command (cmdk) pattern — input, grouped list, preview, footer.
struct PanelRootView: View {
    let model: PanelModel
    let searchBridge: SearchFieldBridge
    let send: (PanelCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(model: model, bridge: searchBridge)
            Separator()
            ContentArea(model: model, send: send)
            Separator()
            FooterBar(model: model, send: send)
        }
        .frame(width: PanelController.panelSize.width, height: PanelController.panelSize.height)
        .background(Theme.popover)
        .clipShape(RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.cornerRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        }
        .environment(\.font, .shadSM)
    }
}

private struct ContentArea: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        if model.items.isEmpty {
            EmptyStateView(state: emptyState, send: send)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                ClipListView(model: model, send: send)
                    .frame(width: Design.listWidth)
                Separator(vertical: true)
                PreviewPane(model: model, send: send)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: EmptyStateView.Kind {
        if !model.hasLoaded { return .loading }
        if !SearchQuery(model.query).isEmpty { return .noResults(model.query) }
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.mutedForeground)
                .accessibilityHidden(true)
            SearchField(text: $model.query, bridge: bridge)
                .frame(maxWidth: .infinity)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    bridge.focus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.shad(.ghost, size: .icon))
                .frame(width: 24, height: 24)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
            ShadTabs(
                selection: $model.filter,
                options: ClipFilter.allCases.map { ($0, $0.title) },
                compact: true
            )
            .help("Switch between All and Pinned (Tab)")
            .accessibilityLabel("Filter")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
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
        field.font = Typeface.nsFont(15)
        field.textColor = Theme.NS.foreground
        field.placeholderAttributedString = NSAttributedString(
            string: "Search clipboard history…",
            attributes: [.foregroundColor: Theme.NS.mutedForeground, .font: Typeface.nsFont(15)]
        )
        field.cell?.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
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
            // Pasting multi-line text into a search box should search its first line's words.
            let value = field.stringValue
            if value.contains(where: \.isNewline) {
                let flattened = value.split(whereSeparator: \.isNewline).joined(separator: " ")
                field.stringValue = flattened
                text.wrappedValue = flattened
            } else {
                text.wrappedValue = value
            }
        }
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        HStack(spacing: 4) {
            leading
            Spacer(minLength: 8)
            if let item = model.selectedItem {
                let primary = model.primaryAction
                FooterAction(title: primary == .paste ? "Paste" : "Copy", keys: ["↩"]) {
                    send(.activate(item, primary))
                }
                FooterAction(title: primary == .paste ? "Copy" : "Paste", keys: ["⌘", "↩"]) {
                    send(.activate(item, primary == .paste ? .copy : .paste))
                }
                FooterAction(title: item.isPinned ? "Unpin" : "Pin", keys: ["⌘", "P"]) {
                    send(.togglePin(item))
                }
                FooterAction(title: "Delete", keys: ["⌘", "⌫"]) {
                    send(.delete(item))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Design.footerHeight)
        .background(Theme.muted.opacity(0.35))
    }

    @ViewBuilder
    private var leading: some View {
        if model.isPaused {
            Button {
                send(.resumeMonitoring)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.warning).frame(width: 6, height: 6)
                    Text("Recording paused")
                        .foregroundStyle(Theme.mutedForeground)
                    Text("Resume")
                        .foregroundStyle(Theme.foreground)
                        .underline()
                }
                .font(.shadXSMedium)
            }
            .buttonStyle(.shad(.ghost, size: .xs))
            .help("Pasty isn’t recording new copies")
        } else {
            HStack(spacing: 6) {
                Image(nsImage: MenuBarIcon.image(paused: false))
                    .renderingMode(.template)
                    .foregroundStyle(Theme.mutedForeground)
                Text(countLabel)
                    .font(.shadXS)
                    .foregroundStyle(Theme.mutedForeground)
                    .monospacedDigit()
            }
            .padding(.leading, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var countLabel: String {
        let count = model.items.count
        if count == 0 { return model.query.isEmpty ? "Clipboard history" : "No matches" }
        if !model.query.isEmpty { return count == 1 ? "1 match" : "\(count.formatted()) matches" }
        return count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}

private struct FooterAction: View {
    let title: String
    let keys: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.shadXSMedium)
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { Kbd($0) }
                }
            }
        }
        .buttonStyle(.shad(.ghost, size: .xs))
        .accessibilityLabel(title)
    }
}

// MARK: - Empty states (shadcn "Empty")

struct EmptyStateView: View {
    enum Kind: Equatable {
        case loading, noHistory, noResults(String), noPinned, paused
    }

    let state: Kind
    let send: (PanelCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state != .loading {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.foreground)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.muted))
                    .padding(.bottom, 14)
                Text(title)
                    .font(Typeface.font(15, .semibold))
                    .foregroundStyle(Theme.foreground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.bottom, 6)
                Text(message)
                    .font(.shadSM)
                    .foregroundStyle(Theme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                if state == .paused {
                    Button("Resume Recording") { send(.resumeMonitoring) }
                        .buttonStyle(.shad(.outline, size: .sm))
                        .padding(.top, 16)
                }
            }
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .loading, .noHistory: "doc.on.clipboard"
        case .noResults: "magnifyingglass"
        case .noPinned: "pin"
        case .paused: "pause"
        }
    }

    private var title: String {
        switch state {
        case .loading: ""
        case .noHistory: "No clipboard history yet"
        case let .noResults(query): "No results for “\(query.trimmingCharacters(in: .whitespaces).prefix(60))”"
        case .noPinned: "No pinned items"
        case .paused: "Recording is paused"
        }
    }

    private var message: String {
        switch state {
        case .loading: ""
        case .noHistory: "Copy something and it will appear here."
        case .noResults: "Try a shorter or different search."
        case .noPinned: "Select an item and press ⌘P to keep it here permanently."
        case .paused: "New copies aren’t being saved."
        }
    }
}
