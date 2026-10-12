import AppKit
import PastyCore
import SwiftUI

struct PreviewPane: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                PreviewHeader(item: item, canQuickLook: canQuickLook(item)) { send(.quickLook(item)) }
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Separator()
                MetadataView(item: item, now: model.now)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        if let detail = model.detail, detail.itemID == item.id {
            switch detail.content {
            case let .document(document, truncated):
                TextPreview(document: document, itemID: item.id)
                    .overlay(alignment: .bottomTrailing) {
                        if truncated {
                            Badge(text: "Preview shortened · full text pastes", variant: .outline)
                                .padding(10)
                        }
                    }
            case let .image(image, pixelSize):
                ImagePreview(image: image, pixelSize: pixelSize)
                    .onTapGesture { send(.quickLook(item)) }
            case let .files(urls):
                FilesPreview(urls: urls)
                    .onTapGesture { send(.quickLook(item)) }
            case let .link(url, display):
                LinkPreview(url: url, display: display) { send(.open(item)) }
            case let .color(color, hex):
                ColorPreview(color: color, hex: hex)
            case let .data(types):
                DataPreview(types: types)
            case .unavailable:
                PreviewMessage(symbol: "exclamationmark.triangle", text: "Preview unavailable")
            }
        } else {
            // Keeps layout stable during the few milliseconds a detail takes to load.
            Color.clear
        }
    }

    /// Everything but links and colors, which Quick Look has nothing more to show for.
    private func canQuickLook(_ item: ClipItem) -> Bool {
        switch model.detail?.itemID == item.id ? model.detail?.content : nil {
        case .link?, .color?, .data?, .unavailable?: false
        default: true
        }
    }
}

/// Type and status badges above the content, and the Quick Look button.
private struct PreviewHeader: View {
    let item: ClipItem
    let canQuickLook: Bool
    let quickLook: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Badge(text: item.isCode ? "Code" : item.kind.displayName, variant: .secondary, symbol: symbol)
            if item.isPinned {
                Badge(text: "Pinned", variant: .outline, symbol: "pin.fill")
            }
            Spacer()
            if canQuickLook {
                Button(action: quickLook) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye")
                        Text("Quick Look")
                        Kbd("⌘Y")
                    }
                }
                .buttonStyle(.shad(.ghost, size: .xs))
                .help("Open a large preview (⌘Y)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private var symbol: String { item.symbolName }
}

private struct PreviewMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
            Text(text).font(.shadSM)
        }
        .foregroundStyle(Theme.mutedForeground)
    }
}

/// For content with no visual form: what it is, and that it still pastes faithfully.
private struct DataPreview: View {
    let types: [String]

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.muted))
            Text("No preview available")
                .font(Typeface.font(14, .semibold))
                .foregroundStyle(Theme.foreground)
            Text("Pasty keeps this content exactly as copied, so it pastes back into apps that understand it.")
                .font(.shadXS)
                .foregroundStyle(Theme.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            FlowBadges(types: Array(Set(types)).sorted().prefix(6).map { $0 })
                .padding(.top, 4)
        }
        .padding(24)
    }
}

private struct FlowBadges: View {
    let types: [String]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(types, id: \.self) { type in
                Badge(text: type, variant: .outline)
            }
        }
    }
}

// MARK: - Text

/// A read-only, selectable TextKit 2 text view. TextKit 2 lays out only what is on screen, so
/// a 10,000-line document costs the same to show as a ten-line one. The attributed string arrives
/// fully prepared (see `DetailBuilder`); this view only swaps it in.
struct TextPreview: NSViewRepresentable {
    let document: NSAttributedString
    let itemID: ClipItem.ID

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: Theme.NS.accent]
        textView.setAccessibilityLabel("Preview")

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.itemID != itemID else { return }
        context.coordinator.itemID = itemID
        textView.textStorage?.setAttributedString(document)
        textView.scroll(.zero)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var itemID: ClipItem.ID?
    }
}

// MARK: - Image

private struct ImagePreview: View {
    let image: NSImage
    let pixelSize: CGSize

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            // Never upscale small images beyond their natural size (in points).
            .frame(maxWidth: max(1, pixelSize.width / 2), maxHeight: max(1, pixelSize.height / 2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Image, \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels")
    }
}

// MARK: - Files

private struct FilesPreview: View {
    let urls: [URL]

    var body: some View {
        if urls.count == 1, let url = urls.first {
            SingleFilePreview(url: url)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        if index > 0 { Separator() }
                        HStack(spacing: 10) {
                            Image(nsImage: IconCache.shared.fileIcon(path: url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.shadSMMedium)
                                    .foregroundStyle(Theme.foreground)
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                                    .font(Typeface.font(11))
                                    .foregroundStyle(Theme.mutedForeground)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .help(url.path)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// One copied file: a real QuickLook preview (screenshots, photos, PDFs, video…) when one exists,
/// otherwise the Finder icon, with its name, location and image size.
private struct SingleFilePreview: View {
    let url: URL
    @State private var preview: NSImage?
    @State private var pixelSize: CGSize?
    @State private var loaded = false

    private var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMedium, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Preview of \(url.lastPathComponent)")
                } else if loaded || !FileThumbnails.hasContentPreview(url.path) {
                    Image(nsImage: IconCache.shared.fileIcon(path: url.path))
                        .resizable()
                        .frame(width: 64, height: 64)
                        .frame(maxHeight: .infinity)
                } else {
                    // Reserve the space while QuickLook renders, so nothing jumps.
                    Color.clear.frame(maxHeight: .infinity)
                }
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(Typeface.font(14, .semibold))
                    .foregroundStyle(Theme.foreground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let pixelSize {
                        Badge(text: "\(Int(pixelSize.width)) × \(Int(pixelSize.height))", variant: .outline)
                    }
                    Text(url.deletingLastPathComponent().path(percentEncoded: false))
                        .font(.shadXS)
                        .foregroundStyle(Theme.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if !exists {
                    Badge(text: "No longer at this location", variant: .destructive, symbol: "exclamationmark.triangle.fill")
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .task(id: url) {
            preview = FileThumbnails.shared.cached(path: url.path, size: 640)
            pixelSize = nil
            loaded = false
            guard exists, FileThumbnails.hasContentPreview(url.path) else { loaded = true; return }
            let loadedImage = await FileThumbnails.shared.thumbnail(path: url.path, size: 640)
            let loadedSize = await FileThumbnails.shared.pixelSize(path: url.path)
            guard !Task.isCancelled else { return }
            preview = loadedImage
            pixelSize = loadedSize
            loaded = true
        }
    }
}

// MARK: - Link

private struct LinkPreview: View {
    let url: URL
    let display: String
    let open: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.foreground)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.muted))
                .padding(.bottom, 4)
            Text(display)
                .font(Typeface.font(14, .semibold))
                .foregroundStyle(Theme.foreground)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
            if let host = url.host(percentEncoded: false) {
                Text(host)
                    .font(.shadXS)
                    .foregroundStyle(Theme.mutedForeground)
            }
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open in Browser")
                    Kbd("⌘O")
                }
            }
            .buttonStyle(.shad(.outline, size: .sm))
            .padding(.top, 8)
        }
        .padding(24)
    }
}

// MARK: - Color

private struct ColorPreview: View {
    let color: NSColor
    let hex: String

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            Text(hex.trimmingCharacters(in: .whitespaces).uppercased())
                .font(Typeface.mono(13, .medium))
                .foregroundStyle(Theme.foreground)
            Text(HexColor(hex)?.cssDescription ?? "")
                .font(Typeface.mono(11.5))
                .foregroundStyle(Theme.mutedForeground)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Metadata

private struct MetadataView: View {
    let item: ClipItem
    let now: Date

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            if let source = item.sourceName {
                row("Source") {
                    HStack(spacing: 5) {
                        if let icon = IconCache.shared.appIcon(bundleID: item.sourceBundleID) {
                            Image(nsImage: icon).resizable().frame(width: 13, height: 13)
                        }
                        Text(source)
                    }
                }
            }
            row("Copied") { Text(copiedText) }
            row("Content") { Text(contentDescription) }
        }
        .font(.shadXS)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.mutedForeground)
                .gridColumnAlignment(.leading)
            value()
                .foregroundStyle(Theme.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var copiedText: String {
        let date = item.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return item.copyCount > 1 ? "\(date) · \(item.copyCount) times" : date
    }

    private var contentDescription: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file)
        switch item.kind {
        case .image:
            return "\(item.imageWidth) × \(item.imageHeight) px · \(size)"
        case .file:
            return item.fileCount == 1 ? "1 file" : "\(item.fileCount) files"
        case .url:
            return "\(item.characterCount.formatted()) characters"
        case .other:
            return "\(item.subtitle ?? "Data") · \(size)"
        case .text, .richText:
            let lines = item.lineCount == 1 ? "1 line" : "\(item.lineCount.formatted()) lines"
            let characters = item.characterCount == 1 ? "1 character" : "\(item.characterCount.formatted()) characters"
            return "\(characters) · \(lines)"
        }
    }
}
