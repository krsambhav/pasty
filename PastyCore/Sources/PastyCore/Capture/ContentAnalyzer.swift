import AppKit
import CryptoKit
import Foundation
import ImageIO

/// Everything needed to persist a new clipboard entry.
public struct ClipDraft: Sendable {
    public var kind: ClipKind
    public var title: String
    public var subtitle: String?
    public var filePath: String?
    /// Up to `ContentAnalyzer.previewLimit` characters of plain text, used for ranking and previews.
    public var preview: String
    /// Text indexed for full-text search (capped).
    public var searchContent: String
    public var isCode: Bool
    /// Stable identity of the *content* (not the exact bytes), used for duplicate handling.
    public var contentHash: Data
    public var byteSize: Int
    public var characterCount: Int
    public var lineCount: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var fileCount: Int
    public var thumbnail: Data?
    public var source: SourceApp?
    public var snapshot: PasteboardSnapshot
    public var date: Date

    public init(
        kind: ClipKind,
        title: String,
        subtitle: String? = nil,
        filePath: String? = nil,
        preview: String,
        searchContent: String,
        isCode: Bool = false,
        contentHash: Data,
        byteSize: Int,
        characterCount: Int = 0,
        lineCount: Int = 0,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        fileCount: Int = 0,
        thumbnail: Data? = nil,
        source: SourceApp? = nil,
        snapshot: PasteboardSnapshot,
        date: Date = Date()
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.filePath = filePath
        self.preview = preview
        self.searchContent = searchContent
        self.isCode = isCode
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.characterCount = characterCount
        self.lineCount = lineCount
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileCount = fileCount
        self.thumbnail = thumbnail
        self.source = source
        self.snapshot = snapshot
        self.date = date
    }

    /// Convenience for tests and programmatic inserts.
    public static func text(_ string: String, source: SourceApp? = nil, date: Date = Date()) -> ClipDraft {
        let snapshot = PasteboardSnapshot(items: [
            PasteboardItemSnapshot(representations: [
                PasteboardRepresentation(type: PasteboardType.string, data: Data(string.utf8)),
            ]),
        ])
        var draft = ContentAnalyzer.analyze(snapshot)!
        draft.source = source
        draft.date = date
        return draft
    }
}

/// Turns a raw pasteboard snapshot into a classified, searchable draft.
///
/// Pure and synchronous; callers run it off the main thread.
public enum ContentAnalyzer {
    public static let previewLimit = 2_000
    public static let titleLimit = 240
    public static let searchLimit = 200_000
    public static let thumbnailPixelSize = 160

    public static func analyze(_ snapshot: PasteboardSnapshot, generateThumbnail: Bool = true) -> ClipDraft? {
        guard let first = snapshot.items.first, !snapshot.isEmpty else { return nil }
        let byteSize = snapshot.byteSize

        // Files win: a Finder copy also carries icons and names we don't want to treat as content.
        let fileURLs = snapshot.fileURLs
        if !fileURLs.isEmpty {
            return analyzeFiles(fileURLs, snapshot: snapshot, byteSize: byteSize)
        }

        let text = snapshot.plainText ?? derivedText(from: first)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let image = first.data(forAnyOf: PasteboardType.images)

        // Browsers put the image URL alongside "Copy Image" — that is still an image.
        if let image, trimmed.isEmpty || detectURL(in: trimmed) != nil && !hasRichText(first) {
            return analyzeImage(image.data, snapshot: snapshot, byteSize: byteSize, generateThumbnail: generateThumbnail)
        }

        guard let text, !trimmed.isEmpty else {
            return analyzeOther(snapshot, byteSize: byteSize)
        }

        if let url = detectURL(in: trimmed) {
            return analyzeURL(url, text: trimmed, snapshot: snapshot, byteSize: byteSize)
        }

        let kind: ClipKind = hasRichText(first) ? .richText : .text
        return analyzeText(text, kind: kind, snapshot: snapshot, byteSize: byteSize)
    }

    // MARK: - Kinds

    private static func analyzeText(_ text: String, kind: ClipKind, snapshot: PasteboardSnapshot, byteSize: Int) -> ClipDraft {
        let preview = String(text.prefix(previewLimit))
        let utf8Count = text.utf8.count
        // Grapheme counting is O(n) and slow for huge strings; fall back to UTF-16 length.
        let characterCount = utf8Count < 1_000_000 ? text.count : text.utf16.count
        let lineCount = text.utf8.reduce(into: 1) { if $1 == UInt8(ascii: "\n") { $0 += 1 } }
        return ClipDraft(
            kind: kind,
            title: makeTitle(from: preview),
            preview: preview,
            searchContent: String(text.prefix(searchLimit)),
            isCode: CodeDetector.looksLikeCode(preview),
            contentHash: hash(prefix: "t", Data(text.utf8)),
            byteSize: byteSize,
            characterCount: characterCount,
            lineCount: lineCount,
            snapshot: snapshot
        )
    }

    private static func analyzeURL(_ url: URL, text: String, snapshot: PasteboardSnapshot, byteSize: Int) -> ClipDraft {
        let display = readableURL(url)
        return ClipDraft(
            kind: .url,
            title: String(display.prefix(titleLimit)),
            subtitle: url.host(percentEncoded: false) ?? url.scheme,
            preview: text,
            searchContent: text,
            contentHash: hash(prefix: "u", Data(url.absoluteString.utf8)),
            byteSize: byteSize,
            characterCount: text.count,
            lineCount: 1,
            snapshot: snapshot
        )
    }

    private static func analyzeImage(_ data: Data, snapshot: PasteboardSnapshot, byteSize: Int, generateThumbnail: Bool) -> ClipDraft {
        let size = ImageTools.pixelSize(of: data)
        let dimensions = size.map { "\($0.width) × \($0.height)" }
        return ClipDraft(
            kind: .image,
            title: dimensions.map { "Image \($0)" } ?? "Image",
            subtitle: dimensions,
            preview: "",
            searchContent: "image picture screenshot",
            contentHash: hash(prefix: "i", data),
            byteSize: byteSize,
            imageWidth: size?.width ?? 0,
            imageHeight: size?.height ?? 0,
            thumbnail: generateThumbnail ? ImageTools.thumbnail(from: data, maxPixelSize: thumbnailPixelSize) : nil,
            snapshot: snapshot
        )
    }

    /// Content with no text, link, image or file form — kept so it can be pasted back verbatim.
    private static func analyzeOther(_ snapshot: PasteboardSnapshot, byteSize: Int) -> ClipDraft? {
        let types = snapshot.allTypes.filter { !$0.hasPrefix("dyn.") }
        guard !types.isEmpty else { return nil }
        let title: String
        let subtitle: String
        if types.contains(PasteboardType.pdf) {
            title = "PDF content"
            subtitle = "PDF"
        } else {
            let primary = snapshot.items.first?.types.first { !$0.hasPrefix("dyn.") } ?? types.sorted()[0]
            title = "Data (\(primary))"
            subtitle = primary
        }
        var hasher = SHA256()
        for item in snapshot.items {
            for rep in item.representations.sorted(by: { $0.type < $1.type }) {
                hasher.update(data: Data(rep.type.utf8))
                hasher.update(data: rep.data)
            }
        }
        return ClipDraft(
            kind: .other,
            title: String(title.prefix(titleLimit)),
            subtitle: subtitle,
            preview: "",
            searchContent: types.sorted().joined(separator: " "),
            contentHash: Data("o".utf8) + Data(hasher.finalize()),
            byteSize: byteSize,
            snapshot: snapshot
        )
    }

    /// Plain text recovered from rich-text-only or HTML-only content.
    static func derivedText(from item: PasteboardItemSnapshot) -> String? {
        if let data = item.data(for: PasteboardType.rtfd),
           let string = NSAttributedString(rtfd: data, documentAttributes: nil)?.string {
            return string
        }
        if let data = item.data(for: PasteboardType.rtf),
           let string = NSAttributedString(rtf: data, documentAttributes: nil)?.string {
            return string
        }
        if let data = item.data(for: PasteboardType.html), let html = String(data: data, encoding: .utf8) {
            return stripHTML(html)
        }
        return nil
    }

    /// Crude but safe tag stripping (HTML import via WebKit is main-thread-only and slow).
    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["(?is)<(script|style)[^>]*>.*?</\\1>", "(?i)<br\\s*/?>", "(?i)</(p|div|li|h[1-6]|tr)>", "<[^>]+>"] {
            let replacement = pattern.contains("br") || pattern.contains("</(p") ? "\n" : ""
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func analyzeFiles(_ urls: [URL], snapshot: PasteboardSnapshot, byteSize: Int) -> ClipDraft {
        let names = urls.map(\.lastPathComponent)
        let title: String
        if urls.count == 1 {
            title = names[0]
        } else {
            title = "\(names[0]) and \(urls.count - 1) more"
        }
        let parent = urls[0].deletingLastPathComponent().path
        let subtitle = urls.count == 1 ? abbreviateHome(parent) : "\(urls.count) items · \(abbreviateHome(parent))"
        let paths = urls.map(\.path).joined(separator: "\n")
        return ClipDraft(
            kind: .file,
            title: String(title.prefix(titleLimit)),
            subtitle: subtitle,
            filePath: urls[0].path,
            preview: paths,
            searchContent: (names + urls.map(\.path)).joined(separator: "\n"),
            contentHash: hash(prefix: "f", Data(paths.utf8)),
            byteSize: byteSize,
            lineCount: urls.count,
            fileCount: urls.count,
            snapshot: snapshot
        )
    }

    // MARK: - Helpers

    static func hasRichText(_ item: PasteboardItemSnapshot) -> Bool {
        PasteboardType.richText.contains { item.data(for: $0) != nil }
    }

    /// Returns a URL when the whole string is a single web/mail/file link.
    public static func detectURL(in string: String) -> URL? {
        let candidate = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count < 4_096,
              !candidate.contains(where: { $0.isWhitespace }) else { return nil }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return url.host() != nil ? url : nil
        case "mailto", "ftp", "sftp", "ssh", "file", "tel", "facetime", "maps", "x-apple.systempreferences":
            return url
        default:
            return nil
        }
    }

    /// `https://www.example.com/a/b?x=1` → `example.com/a/b?x=1`
    public static func readableURL(_ url: URL) -> String {
        var string = url.absoluteString
        for prefix in ["https://", "http://"] where string.lowercased().hasPrefix(prefix) {
            string.removeFirst(prefix.count)
        }
        if string.lowercased().hasPrefix("www.") { string.removeFirst(4) }
        if string.hasSuffix("/") { string.removeLast() }
        return string.removingPercentEncoding ?? string
    }

    /// First non-empty line, whitespace collapsed, truncated.
    public static func makeTitle(from text: String) -> String {
        var result = ""
        result.reserveCapacity(titleLimit)
        var pendingSpace = false
        var started = false
        for character in text {
            if character.isNewline {
                if started { break } else { continue }
            }
            if character.isWhitespace {
                pendingSpace = started
                continue
            }
            if pendingSpace { result.append(" "); pendingSpace = false }
            result.append(character)
            started = true
            if result.count >= titleLimit { break }
        }
        return result
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func hash(prefix: String, _ data: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(prefix.utf8))
        hasher.update(data: data)
        return Data(hasher.finalize())
    }
}

/// Fast, conservative heuristic for "this text is source code".
public enum CodeDetector {
    private static let markers = [
        "func ", "let ", "var ", "const ", "import ", "return ", "class ", "struct ", "def ",
        "#include", "public ", "private ", "=> ", "->", "fn ", "SELECT ", "if (", "for (", "</",
    ]

    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(60)
        guard lines.count >= 2 else { return false }
        var signals = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(";") || trimmed.hasSuffix("{") || trimmed.hasSuffix("}") || trimmed == "}" || trimmed.hasSuffix(":") && line.hasPrefix(" ") {
                signals += 1
            } else if markers.contains(where: { trimmed.hasPrefix($0) || trimmed.contains($0) && $0.count > 3 }) {
                signals += 1
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                signals += 1
            }
        }
        return Double(signals) / Double(lines.count) >= 0.5
    }
}

/// ImageIO helpers that never fully decode large images.
public enum ImageTools {
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// A downsampled CGImage, decoded directly at the target size.
    public static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }

    /// PNG-encoded thumbnail, or nil if the data is not a decodable image.
    public static func thumbnail(from data: Data, maxPixelSize: Int) -> Data? {
        guard let image = downsample(data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
