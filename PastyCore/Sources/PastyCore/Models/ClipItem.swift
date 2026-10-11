import Foundation

/// The broad category of a clipboard entry. Raw values are persisted — never reorder.
public enum ClipKind: Int, Sendable, Codable, CaseIterable {
    case text = 0
    case richText = 1
    case url = 2
    case image = 3
    case file = 4
    /// Content with no text, link, image or file form (e.g. a PDF or an app's private format).
    /// It is still restored exactly when pasted back into the app that understands it.
    case other = 5

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .richText: "Rich Text"
        case .url: "Link"
        case .image: "Image"
        case .file: "File"
        case .other: "Data"
        }
    }
}

/// Lightweight, list-friendly metadata for a clipboard entry.
///
/// Deliberately excludes heavy payloads (representations, thumbnails, long previews)
/// so that thousands of entries can be held in memory and diffed cheaply.
public struct ClipItem: Identifiable, Sendable, Hashable {
    public typealias ID = Int64

    public let id: ID
    public var kind: ClipKind
    /// Single-line, whitespace-collapsed summary suitable for a list row.
    public var title: String
    /// Secondary detail: URL host, image dimensions, parent folder, etc.
    public var subtitle: String?
    /// First file path for file entries (used for icons and Finder reveal).
    public var filePath: String?
    public var isCode: Bool
    public var isPinned: Bool
    /// When the content was first copied.
    public var createdAt: Date
    /// When the content was last copied or pasted — the list sort key.
    public var updatedAt: Date
    public var sourceBundleID: String?
    public var sourceName: String?
    public var byteSize: Int
    public var characterCount: Int
    public var lineCount: Int
    public var imageWidth: Int
    public var imageHeight: Int
    public var fileCount: Int
    public var copyCount: Int

    public init(
        id: ID,
        kind: ClipKind,
        title: String,
        subtitle: String? = nil,
        filePath: String? = nil,
        isCode: Bool = false,
        isPinned: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        byteSize: Int = 0,
        characterCount: Int = 0,
        lineCount: Int = 0,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        fileCount: Int = 0,
        copyCount: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.filePath = filePath
        self.isCode = isCode
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.byteSize = byteSize
        self.characterCount = characterCount
        self.lineCount = lineCount
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileCount = fileCount
        self.copyCount = copyCount
    }
}

/// Which slice of history to show.
public enum ClipFilter: Int, Sendable, CaseIterable {
    case all
    case pinned

    public var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        }
    }
}

/// The application that most likely produced a clipboard change.
public struct SourceApp: Sendable, Hashable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}
