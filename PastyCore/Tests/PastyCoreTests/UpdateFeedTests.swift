import XCTest
@testable import PastyCore

final class UpdateFeedTests: XCTestCase {
    private func release(tag: String = "v1.0.45", assets: [String] = ["Pasty.zip", "Pasty.zip.sha256"], draft: Bool = false, prerelease: Bool = false) -> Data {
        let assetJSON = assets.map {
            #"{"name":"\#($0)","browser_download_url":"https://github.com/o/r/releases/download/\#(tag)/\#($0)","size":2048}"#
        }.joined(separator: ",")
        return Data(#"""
        {"tag_name":"\#(tag)","name":"Pasty \#(tag)","body":"Fixes","draft":\#(draft),"prerelease":\#(prerelease),
         "html_url":"https://github.com/o/r/releases/tag/\#(tag)","assets":[\#(assetJSON)],"extra":{"ignored":true}}
        """#.utf8)
    }

    func testParsesLatestRelease() throws {
        let update = try UpdateFeed.parseGitHubRelease(release())
        XCTAssertEqual(update.build, 45)
        XCTAssertEqual(update.version, "1.0.45")
        XCTAssertEqual(update.notes, "Fixes")
        XCTAssertEqual(update.archiveURL.lastPathComponent, "Pasty.zip")
        XCTAssertEqual(update.checksumURL?.lastPathComponent, "Pasty.zip.sha256")
        XCTAssertEqual(update.archiveSize, 2048)
    }

    func testRejectsBadReleases() {
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(Data("not json".utf8))) { XCTAssertEqual($0 as? UpdateFeedError, .malformed) }
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(Data(#"{"message":"Not Found"}"#.utf8))) { XCTAssertEqual($0 as? UpdateFeedError, .malformed) }
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(release(draft: true))) { XCTAssertEqual($0 as? UpdateFeedError, .notARelease) }
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(release(prerelease: true))) { XCTAssertEqual($0 as? UpdateFeedError, .notARelease) }
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(release(assets: ["Other.dmg"]))) { XCTAssertEqual($0 as? UpdateFeedError, .missingArchive) }
        XCTAssertThrowsError(try UpdateFeed.parseGitHubRelease(release(tag: "latest"))) { XCTAssertEqual($0 as? UpdateFeedError, .unknownVersion("latest")) }
    }

    func testBuildNumbersFromTags() {
        XCTAssertEqual(UpdateFeed.build(fromTag: "v1.0.45"), 45)
        XCTAssertEqual(UpdateFeed.build(fromTag: "build-120"), 120)
        XCTAssertEqual(UpdateFeed.build(fromTag: "v2.3.1007"), 1007)
        XCTAssertNil(UpdateFeed.build(fromTag: "nightly"))
        XCTAssertNil(UpdateFeed.build(fromTag: "v1.0.0"))
    }

    func testNewerComparesBuildNumbersNumerically() throws {
        let update = try UpdateFeed.parseGitHubRelease(release(tag: "v1.0.10"))
        XCTAssertTrue(UpdateFeed.isNewer(update, thanBuild: 9))
        XCTAssertFalse(UpdateFeed.isNewer(update, thanBuild: 10))
        XCTAssertFalse(UpdateFeed.isNewer(update, thanBuild: 11))
    }

    func testChecksumParsingAndVerification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasty-update-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 7, count: 3_000_000).write(to: url)
        let digest = try UpdateFeed.sha256Hex(ofFileAt: url)
        XCTAssertEqual(digest.count, 64)

        XCTAssertNoThrow(try UpdateFeed.verify(fileAt: url, checksumText: "\(digest)  Pasty.zip\n"))
        XCTAssertNoThrow(try UpdateFeed.verify(fileAt: url, checksumText: digest.uppercased()))
        XCTAssertThrowsError(try UpdateFeed.verify(fileAt: url, checksumText: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? UpdateFeedError, .checksumMismatch)
        }
        XCTAssertThrowsError(try UpdateFeed.verify(fileAt: url, checksumText: "")) { XCTAssertEqual($0 as? UpdateFeedError, .checksumMissing) }
        XCTAssertNil(UpdateFeed.parseChecksum("xyz"))
    }
}
