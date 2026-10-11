import AppKit
import PastyCore
import SwiftUI

struct ClipListView: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    let query = SearchQuery(model.query)
                    let quickKeyIDs = model.showsQuickKeys ? model.items.prefix(9).map(\.id) : []
                    ForEach(model.items) { item in
                        ClipRow(
                            item: item,
                            isSelected: item.id == model.selectedID,
                            query: query,
                            now: model.now,
                            quickKey: quickKeyIDs.firstIndex(of: item.id).map { $0 + 1 },
                            thumbnails: model.thumbnails
                        )
                        .equatable()
                        .id(item.id)
                        .onTapGesture { send(.activate(item, model.primaryAction)) }
                        .contextMenu { ClipContextMenu(item: item, primary: model.primaryAction, send: send) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.automatic)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                // A nil anchor scrolls the minimum distance needed — no jumpy recentering.
                proxy.scrollTo(target.id, anchor: nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard history")
    }
}

struct ClipContextMenu: View {
    let item: ClipItem
    let primary: PasteAction
    let send: (PanelCommand) -> Void

    var body: some View {
        Button("Paste") { send(.activate(item, .paste)) }
        if item.kind == .text || item.kind == .richText || item.kind == .url {
            Button("Paste as Plain Text") { send(.activate(item, .pastePlainText)) }
        }
        Button("Copy") { send(.activate(item, .copy)) }
        Divider()
        if item.kind == .url {
            Button("Open Link") { send(.open(item)) }
        }
        if item.kind == .file {
            Button("Show in Finder") { send(.open(item)) }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { send(.togglePin(item)) }
        Divider()
        Button("Delete", role: .destructive) { send(.delete(item)) }
    }
}

struct ClipRow: View, Equatable {
    let item: ClipItem
    let isSelected: Bool
    let query: SearchQuery
    let now: Date
    let quickKey: Int?
    let thumbnails: ThumbnailCache

    @State private var hovering = false
    @Environment(\.colorSchemeContrast) private var contrast

    nonisolated static func == (lhs: ClipRow, rhs: ClipRow) -> Bool {
        lhs.item == rhs.item && lhs.isSelected == rhs.isSelected && lhs.query == rhs.query
            && lhs.now == rhs.now && lhs.quickKey == rhs.quickKey
    }

    var body: some View {
        HStack(spacing: 10) {
            ClipIcon(item: item, thumbnails: thumbnails)
            HighlightedText(text: item.title, query: query, monospaced: item.isCode)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8)
        .frame(height: Design.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Design.rowCornerRadius, style: .continuous)
                .fill(isSelected ? Design.selection(contrast) : hovering ? Design.hover(contrast) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipAccessibility.label(for: item, now: now))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(35))
            }
            if let quickKey {
                KeyCap("⌘\(quickKey)")
            } else {
                Text(RelativeTime.short(item.updatedAt, now: now))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let icon = IconCache.shared.appIcon(bundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .opacity(isSelected ? 1 : 0.85)
                    .help(item.sourceName ?? "")
            }
        }
    }
}

/// The leading 26pt glyph: a thumbnail, a file icon, a color swatch or a type symbol.
struct ClipIcon: View {
    let item: ClipItem
    let thumbnails: ThumbnailCache
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            switch item.kind {
            case .image:
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.primary.opacity(0.05))
                if let image = thumbnail ?? thumbnails.cached(item.id) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            case .file:
                Image(nsImage: IconCache.shared.fileIcon(path: item.filePath ?? "/"))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
            default:
                if let color = ColorParser.parse(item.title), item.lineCount == 1 {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: color))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                        .frame(width: 20, height: 20)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.05))
                    Image(systemName: symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 26, height: 26)
        .task(id: item.id) {
            guard item.kind == .image, thumbnail == nil else { return }
            thumbnail = await thumbnails.load(item.id)
        }
    }

    private var symbol: String {
        if item.isCode { return "chevron.left.forwardslash.chevron.right" }
        switch item.kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

/// Single-line text with search matches emphasized.
struct HighlightedText: View {
    let text: String
    let query: SearchQuery
    var monospaced = false

    var body: some View {
        Text(attributed)
            .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text.isEmpty ? " " : text)
        guard !query.isEmpty else { return string }
        for range in SearchRanker.highlightRanges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: string),
                  let upper = AttributedString.Index(range.upperBound, within: string) else { continue }
            string[lower..<upper].foregroundColor = .accentColor
            string[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return string
    }
}
