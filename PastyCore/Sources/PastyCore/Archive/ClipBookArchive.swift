import AppKit
import Foundation
import UniformTypeIdentifiers

/// An entry to import with the history metadata another app recorded for it.
public struct ImportedClip: Sendable {
    public var draft: ClipDraft
    public var firstCopiedAt: Date
    public var copyCount: Int
    public var pinned: Bool

    public init(draft: ClipDraft, firstCopiedAt: Date, copyCount: Int, pinned: Bool) {
        self.draft = draft
        self.firstCopiedAt = firstCopiedAt
        self.copyCount = copyCount
        self.pinned = pinned
    }
}

/// The `.clipbookarchive` format written by ClipBook (Settings › Import/Export › Export History and
/// Tags…): a folder with `manifest.json`, `tags.json`, `history.json` and `assets/`.
///
/// Pasty reads it to import ClipBook history, and writes it to export Pasty's history — so the same
/// archive can move between Pasty, ClipBook and other installs of either.
public enum ClipBookArchive {
    public static let fileExtension = "clipbookarchive"
    public static let supportedFormatVersion = 1

    public struct Manifest: Codable, Sendable {
        public var formatVersion: Int
        public var appName: String
        public var appVersion: String?
        public var exportedAt: String
    }

    public struct Tag: Codable, Sendable {
        public var id: String
        public var name: String
        public var color: String
    }

    public struct LinkPreview: Codable, Sendable {
        public var url: String
        public var title: String?
        public var description: String?
        public var imagePath: String?
        public var faviconPath: String?
        public var fetchedAt: String?
    }

    /// One history entry, field-for-field as ClipBook writes it.
    public struct Item: Codable, Sendable {
        public var id: String
        public var kind: String
        public var title: String?
        public var text: String?
        public var rtfBase64: String?
        public var html: String?
        public var assetPath: String?
        public var filePaths: [String]?
        public var sourceAppName: String?
        public var sourceBundleIdentifier: String?
        public var sourceAppPath: String?
        public var copiedAt: String
        public var firstCopiedAt: String?
        public var byteSize: Int?
        public var isFavorite: Bool?
        public var tagIDs: [String]?
        public var tagNames: [String]?
        public var copyCount: Int?
        public var linkPreviewDetails: LinkPreview?
        public var copySequenceID: String?
        public var copySequenceOrder: Int?
        public var imageWidth: Int?
        public var imageHeight: Int?
        public var imageText: String?
        public var fileFolder: Bool?

        public init(id: String, kind: String, copiedAt: String) {
            self.id = id
            self.kind = kind
            self.copiedAt = copiedAt
        }
    }

    public enum ArchiveError: Error, CustomStringConvertible, Equatable {
        case notAnArchive(String)
        case unsupportedVersion(Int)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .notAnArchive(missing): "This isn’t a ClipBook archive (\(missing) is missing)."
            case let .unsupportedVersion(version): "Archive format \(version) is newer than Pasty supports."
            case let .unreadable(detail): "The archive couldn’t be read: \(detail)"
            }
        }
    }

    public struct Contents: Sendable {
        public var manifest: Manifest
        public var items: [Item]
        public var tagCount: Int
    }

    // MARK: - Reading

    public static func read(at root: URL) throws -> Contents {
        let fm = FileManager.default
        for name in ["manifest.json", "history.json"] where !fm.fileExists(atPath: root.appendingPathComponent(name).path) {
            throw ArchiveError.notAnArchive(name)
        }
        let decoder = JSONDecoder()
        let manifest: Manifest
        let items: [Item]
        do {
            manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        } catch {
            throw ArchiveError.unreadable("manifest.json — \(error.localizedDescription)")
        }
        guard manifest.formatVersion <= supportedFormatVersion else { throw ArchiveError.unsupportedVersion(manifest.formatVersion) }
        do {
            let data = try Data(contentsOf: root.appendingPathComponent("history.json"), options: .mappedIfSafe)
            items = try decoder.decode([Item].self, from: data)
        } catch {
            throw ArchiveError.unreadable("history.json — \(error.localizedDescription)")
        }
        let tags = (try? decoder.decode([Tag].self, from: Data(contentsOf: root.appendingPathComponent("tags.json")))) ?? []
        return Contents(manifest: manifest, items: items, tagCount: tags.count)
    }

    /// Why an archive item couldn't be imported.
    public enum SkipReason: Sendable, Equatable {
        case missingAsset
        case empty
        case unsupportedKind(String)
    }

    /// Converts a ClipBook item into a Pasty entry. Pure apart from reading the item's asset file;
    /// safe to call off the main thread and concurrently.
    public static func importedClip(from item: Item, archiveRoot: URL, generateThumbnail: Bool = true) -> Result<ImportedClip, SkipReasonBox> {
        var representations: [PasteboardRepresentation] = []
        var items: [PasteboardItemSnapshot]?

        switch item.kind {
        case "image":
            guard let assetPath = item.assetPath, let url = safeAssetURL(assetPath, root: archiveRoot),
                  let data = try? Data(contentsOf: url) else { return .failure(SkipReasonBox(.missingAsset)) }
            representations.append(PasteboardRepresentation(type: imageType(for: url, data: data), data: data))
        case "file":
            let paths = (item.filePaths ?? []).filter { !$0.isEmpty }
            guard !paths.isEmpty else { return .failure(SkipReasonBox(.empty)) }
            items = paths.map { path in
                PasteboardItemSnapshot(representations: [
                    PasteboardRepresentation(type: PasteboardType.fileURL, data: Data(URL(fileURLWithPath: path).absoluteString.utf8)),
                ])
            }
        case "text", "richText", "link", "email", "color":
            if let rtf = item.rtfBase64.flatMap({ Data(base64Encoded: $0) }), !rtf.isEmpty {
                representations.append(PasteboardRepresentation(type: PasteboardType.rtf, data: rtf))
            }
            if let html = item.html, !html.isEmpty {
                representations.append(PasteboardRepresentation(type: PasteboardType.html, data: Data(html.utf8)))
            }
            if let text = item.text, !text.isEmpty {
                representations.append(PasteboardRepresentation(type: PasteboardType.string, data: Data(text.utf8)))
            }
            guard !representations.isEmpty else { return .failure(SkipReasonBox(.empty)) }
        default:
            return .failure(SkipReasonBox(.unsupportedKind(item.kind)))
        }

        let snapshot = PasteboardSnapshot(items: items ?? [PasteboardItemSnapshot(representations: representations)])
        guard var draft = ContentAnalyzer.analyze(snapshot, generateThumbnail: generateThumbnail) else {
            return .failure(SkipReasonBox(.empty))
        }
        if let imageText = item.imageText, !imageText.isEmpty {
            draft.searchContent += "\n" + String(imageText.prefix(ContentAnalyzer.searchLimit))
        }
        if let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            draft.searchContent += "\n" + title
        }
        draft.source = source(name: item.sourceAppName, bundleID: item.sourceBundleIdentifier, appPath: item.sourceAppPath)
        let copied = parseDate(item.copiedAt) ?? Date()
        draft.date = copied
        return .success(ImportedClip(
            draft: draft,
            firstCopiedAt: min(item.firstCopiedAt.flatMap(parseDate) ?? copied, copied),
            copyCount: max(1, item.copyCount ?? 1),
            pinned: item.isFavorite ?? false
        ))
    }

    /// `Result` needs an `Error`; this carries the skip reason.
    public struct SkipReasonBox: Error, Sendable {
        public let reason: SkipReason
        init(_ reason: SkipReason) { self.reason = reason }
    }

    static func source(name: String?, bundleID: String?, appPath: String?) -> SourceApp? {
        var resolvedID = bundleID?.isEmpty == false ? bundleID : nil
        if resolvedID == nil, let appPath, !appPath.isEmpty {
            resolvedID = Bundle(path: appPath)?.bundleIdentifier
        }
        var resolvedName = name?.isEmpty == false ? name : nil
        if resolvedName == nil, let appPath, !appPath.isEmpty {
            resolvedName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        guard resolvedID != nil || resolvedName != nil else { return nil }
        return SourceApp(bundleID: resolvedID, name: resolvedName)
    }

    /// Resolves an archive-relative path, refusing anything that escapes the archive.
    static func safeAssetURL(_ relativePath: String, root: URL) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { return nil }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path) else { return nil }
        return url
    }

    static func imageType(for url: URL, data: Data) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return type.identifier
        }
        // Sniff common signatures when the extension is missing or wrong.
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return PasteboardType.png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return PasteboardType.jpeg }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return PasteboardType.tiff }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return PasteboardType.gif }
        return PasteboardType.png
    }

    private static func makeISOFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    public static func parseDate(_ string: String) -> Date? {
        makeISOFormatter(fractional: true).date(from: string) ?? makeISOFormatter(fractional: false).date(from: string)
    }

    public static func formatDate(_ date: Date) -> String {
        makeISOFormatter(fractional: true).string(from: date)
    }

    /// ClipBook's stable ID format: `00000000-0000-4000-8000-<12 hex digits>`.
    public static func archiveID(_ id: Int64) -> String {
        let hex = String(UInt64(bitPattern: id), radix: 16)
        return "00000000-0000-4000-8000-" + String(String(repeating: "0", count: max(0, 12 - hex.count)) + hex).suffix(12)
    }

    // MARK: - Writing

    /// Builds the archive item for a Pasty entry, writing its image asset (if any) into `root`.
    /// Returns nil for content ClipBook can't represent (e.g. opaque app-private data).
    public static func archiveItem(for item: ClipItem, snapshot: PasteboardSnapshot, root: URL) throws -> Item? {
        var archived = Item(id: archiveID(item.id), kind: "text", copiedAt: formatDate(item.updatedAt))
        archived.firstCopiedAt = formatDate(item.createdAt)
        archived.byteSize = item.byteSize
        archived.isFavorite = item.isPinned
        archived.copyCount = item.copyCount
        archived.tagIDs = []
        archived.tagNames = []
        archived.filePaths = []
        archived.sourceAppName = item.sourceName
        archived.sourceBundleIdentifier = item.sourceBundleID
        if let bundleID = item.sourceBundleID {
            archived.sourceAppPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
        let first = snapshot.items.first

        switch item.kind {
        case .image:
            guard let image = first?.data(forAnyOf: PasteboardType.images) else { return nil }
            let ext = UTType(image.type)?.preferredFilenameExtension ?? "png"
            let relative = "assets/images/pasty-\(item.id).\(ext)"
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.data.write(to: destination)
            archived.kind = "image"
            archived.assetPath = relative
            archived.imageWidth = item.imageWidth
            archived.imageHeight = item.imageHeight
        case .file:
            let urls = snapshot.fileURLs
            guard !urls.isEmpty else { return nil }
            archived.kind = "file"
            archived.filePaths = urls.map(\.path)
            var isDirectory: ObjCBool = false
            archived.fileFolder = FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory) && isDirectory.boolValue
                && urls[0].pathExtension != "app"
        case .url:
            archived.kind = "link"
            archived.text = snapshot.plainText
        case .text, .richText:
            let text = snapshot.plainText ?? first.flatMap(ContentAnalyzer.derivedText) ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            archived.text = text
            if let rtf = first?.data(for: PasteboardType.rtf), let rtfString = String(data: rtf, encoding: .utf8) ?? String(data: rtf, encoding: .isoLatin1) {
                archived.rtfBase64 = Data(rtfString.utf8).base64EncodedString()
            }
            if let html = first?.data(for: PasteboardType.html).flatMap({ String(data: $0, encoding: .utf8) }) {
                archived.html = html
            }
            if archived.rtfBase64 != nil || archived.html != nil {
                archived.kind = "richText"
            } else if HexColor(trimmed) != nil {
                archived.kind = "color"
            } else if isEmail(trimmed) {
                archived.kind = "email"
            } else {
                archived.kind = "text"
            }
        case .other:
            return nil
        }
        return archived
    }

    static func isEmail(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), text.count <= 254,
              let at = text.firstIndex(of: "@"), at != text.startIndex else { return false }
        let domain = text[text.index(after: at)...]
        return domain.contains(".") && !domain.contains("@") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Writes `manifest.json`, `tags.json` and `history.json` into `root` (assets are written by
    /// `archiveItem`).
    public static func writeIndex(items: [Item], root: URL, appVersion: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let manifest = Manifest(formatVersion: supportedFormatVersion, appName: "Pasty", appVersion: appVersion, exportedAt: formatDate(Date()))
        try encoder.encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        try encoder.encode([Tag]()).write(to: root.appendingPathComponent("tags.json"))
        try encoder.encode(items).write(to: root.appendingPathComponent("history.json"))
    }
}
