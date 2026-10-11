import AppKit
import PastyCore
import SwiftUI

struct PreviewPane: View {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                content(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Design.hairline(contrast)).frame(height: 0.5)
                    .padding(.horizontal, 16)
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
            case let .text(text, isCode, truncated):
                TextPreview(content: .plain(text, monospaced: isCode), itemID: item.id)
                    .overlay(alignment: .bottomTrailing) {
                        if truncated {
                            Text("Preview truncated")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(8)
                        }
                    }
            case let .rich(attributed):
                TextPreview(content: .rich(attributed), itemID: item.id)
            case let .image(image, pixelSize):
                ImagePreview(image: image, pixelSize: pixelSize)
            case let .files(urls):
                FilesPreview(urls: urls)
            case let .link(url, display):
                LinkPreview(url: url, display: display) { send(.open(item)) }
            case let .color(color, hex):
                ColorPreview(color: color, hex: hex)
            case .unavailable:
                PreviewMessage(symbol: "exclamationmark.triangle", text: "Preview unavailable")
            }
        } else {
            // Keeps layout stable during the few milliseconds a detail takes to load.
            Color.clear
        }
    }
}

private struct PreviewMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Text

/// A read-only, selectable NSTextView: fast for very large text and faithful for rich text.
struct TextPreview: NSViewRepresentable {
    enum Content {
        case plain(String, monospaced: Bool)
        case rich(NSAttributedString)
    }

    let content: Content
    let itemID: ClipItem.ID

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 12, height: 14)
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isRichText = true
            textView.textContainer?.lineFragmentPadding = 4
            textView.setAccessibilityLabel("Preview")
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              context.coordinator.itemID != itemID else { return }
        context.coordinator.itemID = itemID
        switch content {
        case let .plain(text, monospaced):
            let font: NSFont = monospaced
                ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                : .systemFont(ofSize: 13)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = monospaced ? 2 : 3
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]))
        case let .rich(attributed):
            textView.textStorage?.setAttributedString(Self.adaptingDefaultColors(attributed))
        }
        textView.scrollToBeginningOfDocument(nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Rich text usually hard-codes black text; map default-looking colors to the dynamic label
    /// color so it stays legible in Dark Mode, while keeping intentional colors intact.
    static func adaptingDefaultColors(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
                return
            }
            if color.saturationComponent < 0.1, color.brightnessComponent < 0.2 {
                result.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        result.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB), color.saturationComponent < 0.1, color.brightnessComponent > 0.9 {
                result.removeAttribute(.backgroundColor, range: range)
            }
        }
        return result
    }

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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Image, \(Int(pixelSize.width)) by \(Int(pixelSize.height)) pixels")
    }
}

// MARK: - Files

private struct FilesPreview: View {
    let urls: [URL]

    var body: some View {
        if urls.count == 1, let url = urls.first {
            VStack(spacing: 10) {
                Image(nsImage: IconCache.shared.fileIcon(path: url.path))
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(url.deletingLastPathComponent().path(percentEncoded: false))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if !FileManager.default.fileExists(atPath: url.path) {
                    Label("No longer at this location", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.fileIcon(path: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(url.lastPathComponent)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .help(url.path)
                    }
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Link

private struct LinkPreview: View {
    let url: URL
    let display: String
    let open: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
            Text(display)
                .font(.system(size: 13.5, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .textSelection(.enabled)
            if let host = url.host(percentEncoded: false) {
                Text(host)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Button(action: open) {
                HStack(spacing: 6) {
                    Text("Open in Browser")
                    KeyCap("⌘O")
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.top, 2)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
                .frame(width: 120, height: 120)
            Text(hex.uppercased())
                .font(.system(size: 13, weight: .medium, design: .monospaced))
            Text(rgb)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var rgb: String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return "rgb(\(Int((c.redComponent * 255).rounded())), \(Int((c.greenComponent * 255).rounded())), \(Int((c.blueComponent * 255).rounded())))"
    }
}

// MARK: - Metadata

private struct MetadataView: View {
    let item: ClipItem
    let now: Date

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
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
        .font(.system(size: 11.5))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.trailing)
            value()
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
            return "Image · \(item.imageWidth) × \(item.imageHeight) · \(size)"
        case .file:
            return item.fileCount == 1 ? "File reference" : "\(item.fileCount) file references"
        case .url:
            return "Link · \(item.characterCount.formatted()) characters"
        case .text, .richText:
            let kind = item.isCode ? "Code" : item.kind.displayName
            let lines = item.lineCount == 1 ? "1 line" : "\(item.lineCount.formatted()) lines"
            return "\(kind) · \(item.characterCount.formatted()) characters · \(lines)"
        }
    }
}
