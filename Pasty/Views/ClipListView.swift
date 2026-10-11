import AppKit
import PastyCore
import SwiftUI

struct ClipListView: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    let query = SearchQuery(model.query)
                    let quickKeyIDs = model.showsQuickKeys ? model.items.prefix(9).map(\.id) : []
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
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
                                .contextMenu { ClipContextMenu(item: item, send: send) }
                            }
                        } header: {
                            SectionHeader(title: section.title)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else { return }
                if target.id == model.items.first?.id, let header = model.sections.first?.id {
                    // Reveal the first group's heading along with the first row.
                    proxy.scrollTo(header, anchor: .top)
                } else {
                    // A nil anchor scrolls the minimum distance — no jumpy recentering.
                    proxy.scrollTo(target.id, anchor: nil)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clipboard history")
    }
}

/// cmdk's CommandGroup heading.
private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.shadXSMedium)
            .foregroundStyle(Theme.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 5)
            .background(Theme.popover)
            .id(title)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ClipContextMenu: View {
    let item: ClipItem
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

/// cmdk's CommandItem: icon, label, and a right-aligned shortcut slot.
struct ClipRow: View, Equatable {
    let item: ClipItem
    let isSelected: Bool
    let query: SearchQuery
    let now: Date
    let quickKey: Int?
    let thumbnails: ThumbnailCache

    @State private var hovering = false

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
            RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous)
                .fill(isSelected ? Theme.accent : hovering ? Theme.accent.opacity(0.5) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ClipAccessibility.label(for: item, now: now))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 7) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.mutedForeground)
                    .rotationEffect(.degrees(40))
                    .accessibilityHidden(true)
            }
            if let quickKey {
                Kbd("⌘\(quickKey)")
            } else {
                Text(RelativeTime.short(item.updatedAt, now: now))
                    .font(Typeface.font(11.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let icon = IconCache.shared.appIcon(bundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 15, height: 15)
                    .help(item.sourceName ?? "")
            }
        }
    }
}

/// The leading 24pt glyph: a thumbnail, a file icon, a color swatch or a type symbol.
struct ClipIcon: View {
    let item: ClipItem
    let thumbnails: ThumbnailCache
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            switch item.kind {
            case .image:
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.muted)
                if let image = thumbnail ?? thumbnails.cached(item.id) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedForeground)
                }
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 0.5)
            case .file:
                Image(nsImage: IconCache.shared.fileIcon(path: item.filePath ?? "/"))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)
            default:
                if item.lineCount == 1, let color = ColorParser.parse(item.title) {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                        .fill(Color(nsColor: color))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.mutedForeground)
                }
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: item.id) {
            guard item.kind == .image, thumbnail == nil else { return }
            thumbnail = await thumbnails.load(item.id)
        }
    }

    private var symbol: String { item.symbolName }
}

/// Single-line text with search matches emphasized.
struct HighlightedText: View {
    let text: String
    let query: SearchQuery
    var monospaced = false

    var body: some View {
        Text(attributed)
            .font(monospaced ? Typeface.mono(12.5) : .shadSM)
            .foregroundStyle(Theme.foreground)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributed: AttributedString {
        var string = AttributedString(text.isEmpty ? " " : text)
        guard !query.isEmpty else { return string }
        for range in SearchRanker.highlightRanges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: string),
                  let upper = AttributedString.Index(range.upperBound, within: string) else { continue }
            string[lower..<upper].backgroundColor = Theme.highlight
            string[lower..<upper].font = monospaced ? Typeface.mono(12.5, .semibold) : .shadSMSemibold
        }
        return string
    }
}
