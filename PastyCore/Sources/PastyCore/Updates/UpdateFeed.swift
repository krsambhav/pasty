import CryptoKit
import Foundation

/// A release that can be installed over the running copy.
public struct AvailableUpdate: Sendable, Equatable {
    /// Monotonic build number (CFBundleVersion); the only thing compared.
    public var build: Int
    /// Human-readable version, e.g. "1.0.45".
    public var version: String
    public var notes: String
    public var archiveURL: URL
    public var checksumURL: URL?
    public var archiveSize: Int?
    public var pageURL: URL?

    public init(build: Int, version: String, notes: String = "", archiveURL: URL, checksumURL: URL? = nil, archiveSize: Int? = nil, pageURL: URL? = nil) {
        self.build = build
        self.version = version
        self.notes = notes
        self.archiveURL = archiveURL
        self.checksumURL = checksumURL
        self.archiveSize = archiveSize
        self.pageURL = pageURL
    }
}

public enum UpdateFeedError: Error, Equatable, CustomStringConvertible {
    case malformed
    case notARelease
    case missingArchive
    case unknownVersion(String)
    case checksumMissing
    case checksumMismatch

    public var description: String {
        switch self {
        case .malformed: "The update feed couldn’t be read."
        case .notARelease: "The latest release is a draft or pre-release."
        case .missingArchive: "The release has no Pasty.zip."
        case let .unknownVersion(tag): "Unrecognized release tag “\(tag)”."
        case .checksumMissing: "The release has no checksum."
        case .checksumMismatch: "The download didn’t match its checksum."
        }
    }
}

/// Reads GitHub's "latest release" API response and verifies downloads.
public enum UpdateFeed {
    public static let archiveName = "Pasty.zip"
    public static let checksumName = "Pasty.zip.sha256"

    /// `https://api.github.com/repos/<owner>/<repo>/releases/latest`
    public static func latestReleaseURL(repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
    }

    public static func parseGitHubRelease(_ data: Data) throws -> AvailableUpdate {
        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let size: Int?
            }
            let tag_name: String
            let name: String?
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let html_url: URL?
            let assets: [Asset]
        }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw UpdateFeedError.malformed
        }
        if release.draft == true || release.prerelease == true { throw UpdateFeedError.notARelease }
        guard let build = build(fromTag: release.tag_name) else { throw UpdateFeedError.unknownVersion(release.tag_name) }
        guard let archive = release.assets.first(where: { $0.name == archiveName }) else { throw UpdateFeedError.missingArchive }
        let checksum = release.assets.first { $0.name == checksumName }
        var version = release.tag_name
        if version.hasPrefix("v") { version.removeFirst() }
        return AvailableUpdate(
            build: build,
            version: version,
            notes: release.body ?? "",
            archiveURL: archive.browser_download_url,
            checksumURL: checksum?.browser_download_url,
            archiveSize: archive.size,
            pageURL: release.html_url
        )
    }

    /// The build number is the last numeric component of the tag: "v1.0.45" → 45, "build-45" → 45.
    public static func build(fromTag tag: String) -> Int? {
        let components = tag.split(whereSeparator: { !$0.isNumber })
        guard let last = components.last, let value = Int(last), value > 0 else { return nil }
        return value
    }

    public static func isNewer(_ update: AvailableUpdate, thanBuild current: Int) -> Bool {
        update.build > current
    }

    /// Accepts `shasum -a 256` output ("<hex>  Pasty.zip") or a bare hex digest.
    public static func parseChecksum(_ text: String) -> String? {
        guard let first = text.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        let hex = first.lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return hex
    }

    /// SHA-256 of a file, streamed in 1 MB chunks so large archives never sit in memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(fileAt url: URL, checksumText: String) throws {
        guard let expected = parseChecksum(checksumText) else { throw UpdateFeedError.checksumMissing }
        guard try sha256Hex(ofFileAt: url) == expected else { throw UpdateFeedError.checksumMismatch }
    }
}
