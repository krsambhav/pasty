import AppKit
import Observation
import PastyCore
import Security

/// Keeps Pasty up to date from the project's GitHub Releases, quietly and safely.
///
/// 1. **Check** `releases/latest` shortly after launch and every few hours (one small HTTPS
///    request to GitHub; nothing about your clipboard is ever sent).
/// 2. **Download** `Pasty.zip` in the background and verify it against the release's SHA-256.
/// 3. **Validate** the unpacked app: same bundle identifier, the advertised build number, a valid
///    code signature — and, when this copy is signed with a real certificate, a signature that
///    satisfies this copy's designated requirement (so only builds from the same signer install).
/// 4. **Install** when Pasty is idle: a tiny helper script waits for Pasty to quit, swaps the
///    bundle (rolling back on failure) and relaunches it.
@MainActor
@Observable
final class Updater {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case ready(String)
        case installing(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?
    private(set) var available: AvailableUpdate?

    let currentBuild: Int
    let currentVersion: String
    /// Why updates can't run in this copy, if they can't (Debug builds, not an app bundle…).
    let unsupportedReason: String?

    @ObservationIgnored var onReady: ((AvailableUpdate) -> Void)?
    /// Background checks run only while this returns true ("Update automatically").
    @ObservationIgnored var automaticChecksEnabled: () -> Bool = { true }
    @ObservationIgnored private let feedURL: URL?
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var isWorking = false

    static let checkInterval: Duration = .seconds(6 * 60 * 60)

    init(bundle: Bundle = .main, feedOverride: URL? = nil) {
        currentBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let repository = bundle.object(forInfoDictionaryKey: "PastyUpdateRepository") as? String ?? ""
        feedURL = feedOverride ?? UpdateFeed.latestReleaseURL(repository: repository)

        #if DEBUG
        unsupportedReason = feedOverride == nil ? "Updates are disabled in Debug builds." : nil
        #else
        if bundle.bundleURL.pathExtension != "app" {
            unsupportedReason = "Pasty isn’t running from an app bundle."
        } else if feedURL == nil || (repository.isEmpty && feedOverride == nil) {
            unsupportedReason = "No update source is configured."
        } else {
            unsupportedReason = nil
        }
        #endif
    }

    // MARK: Scheduling

    /// Checks a minute after launch, then every six hours.
    func start(initialDelay: Duration = .seconds(60)) {
        guard unsupportedReason == nil, scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                if let self, automaticChecksEnabled() {
                    await check(userInitiated: false)
                }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    // MARK: Check & download

    /// Checks for, downloads and validates an update. Returns the staged update, if any.
    @discardableResult
    func check(userInitiated: Bool) async -> AvailableUpdate? {
        guard unsupportedReason == nil, let feedURL, !isWorking else { return nil }
        if case .ready = phase { return available }
        isWorking = true
        defer { isWorking = false }
        phase = .checking

        do {
            let update = try await fetchLatest(from: feedURL)
            lastChecked = Date()
            guard let update, UpdateFeed.isNewer(update, thanBuild: currentBuild) else {
                phase = .upToDate
                return nil
            }
            available = update
            phase = .downloading(update.version)
            let app = try await download(update)
            stagedApp = app
            phase = .ready(update.version)
            onReady?(update)
            return update
        } catch {
            lastChecked = Date()
            phase = userInitiated ? .failed(Self.describe(error)) : .idle
            NSLog("Pasty: update check failed: \(error)")
            return nil
        }
    }

    private func fetchLatest(from url: URL) async throws -> AvailableUpdate? {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Pasty/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404: no published release yet (or the repository isn't public) — nothing to do.
            if status == 404 { return nil }
            guard (200..<300).contains(status) else { throw UpdaterError.http(status) }
            data = body
        }
        return try UpdateFeed.parseGitHubRelease(data)
    }

    private func download(_ update: AvailableUpdate) async throws -> URL {
        guard let checksumURL = update.checksumURL else { throw UpdateFeedError.checksumMissing }
        let staging = Self.stagingDirectory.appendingPathComponent("\(update.build)", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: Self.stagingDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let archive = staging.appendingPathComponent(UpdateFeed.archiveName)
        try await Self.fetch(update.archiveURL, to: archive)
        let checksumText = try await Self.fetchText(checksumURL)
        let expectedBuild = update.build
        let bundleID = Bundle.main.bundleIdentifier

        // Verification, unpacking and signature checks run off the main thread.
        return try await Task.detached(priority: .utility) {
            try UpdateFeed.verify(fileAt: archive, checksumText: checksumText)
            let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])
            let app = unpacked.appendingPathComponent("Pasty.app", isDirectory: true)
            try Self.validate(app: app, expectedBuild: expectedBuild, bundleID: bundleID)
            return app
        }.value
    }

    // MARK: Install

    /// Replaces the running app with the staged update and relaunches. Returns false (and
    /// explains why in `phase`) if the update can't be installed here.
    @discardableResult
    func installAndRelaunch(target: URL = Bundle.main.bundleURL, terminate: Bool = true) -> Bool {
        guard let stagedApp, let available else { return false }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: target.path) else {
            phase = .failed("Pasty can’t replace itself in \(target.deletingLastPathComponent().path). Download the update from GitHub instead.")
            return false
        }
        do {
            let script = Self.stagingDirectory.appendingPathComponent("install.sh")
            try Self.installScript.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, "\(ProcessInfo.processInfo.processIdentifier)", target.path, stagedApp.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            phase = .failed("Couldn’t start the installer: \(error.localizedDescription)")
            return false
        }
        phase = .installing(available.version)
        if terminate { NSApp.terminate(nil) }
        return true
    }

    /// Waits for Pasty to quit, swaps the bundle with rollback, and relaunches the result.
    static let installScript = """
    #!/bin/sh
    PID="$1"; TARGET="$2"; NEW="$3"; RELAUNCH="${4:-yes}"
    i=0
    while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
    BACKUP="$TARGET.pasty-previous"
    rm -rf "$BACKUP"
    if mv "$TARGET" "$BACKUP"; then
      if mv "$NEW" "$TARGET"; then
        rm -rf "$BACKUP"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        [ "$RELAUNCH" = "yes" ] && /usr/bin/open "$TARGET" --args --after-update
      else
        mv "$BACKUP" "$TARGET"
        [ "$RELAUNCH" = "yes" ] && /usr/bin/open "$TARGET"
      fi
    else
      [ "$RELAUNCH" = "yes" ] && /usr/bin/open "$TARGET"
    fi
    exit 0
    """

    // MARK: Helpers

    static var stagingDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Pasty", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    private static func fetch(_ url: URL, to destination: URL) async throws {
        if url.isFileURL {
            try FileManager.default.copyItem(at: url, to: destination)
            return
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UpdaterError.http(status) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func fetchText(_ url: URL) async throws -> String {
        if url.isFileURL { return try String(contentsOf: url, encoding: .utf8) }
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw UpdaterError.http(status) }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdaterError.tool(tool, process.terminationStatus) }
    }

    nonisolated static func validate(app: URL, expectedBuild: Int, bundleID: String?) throws {
        guard let bundle = Bundle(url: app) else { throw UpdaterError.invalidBundle("not an app") }
        guard bundle.bundleIdentifier == bundleID else { throw UpdaterError.invalidBundle("different bundle identifier") }
        let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        guard build == expectedBuild else { throw UpdaterError.invalidBundle("build \(build), expected \(expectedBuild)") }
        try CodeSignature.verify(app: app)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as UpdateFeedError: error.description
        case let error as UpdaterError: error.description
        default: error.localizedDescription
        }
    }
}

enum UpdaterError: Error, CustomStringConvertible {
    case http(Int)
    case tool(String, Int32)
    case invalidBundle(String)
    case signature(String)

    var description: String {
        switch self {
        case let .http(status): "GitHub responded with HTTP \(status)."
        case let .tool(tool, status): "\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(status))."
        case let .invalidBundle(reason): "The downloaded app is invalid: \(reason)."
        case let .signature(reason): "The downloaded app’s signature was rejected: \(reason)."
        }
    }
}

/// Code-signature checks with the Security framework.
enum CodeSignature {
    /// Whether this running copy is signed with a certificate (rather than ad hoc).
    static var isCertificateSigned: Bool {
        guard let code = selfStaticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let isAdHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        return !isAdHoc && dictionary[kSecCodeInfoCertificates as String] != nil
    }

    private static var selfStaticCode: SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    /// The new app must carry a valid signature. If this copy is certificate-signed, the new one
    /// must also satisfy this copy's designated requirement — i.e. come from the same signer.
    static func verify(app: URL) throws {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdaterError.signature("unreadable")
        }
        var requirement: SecRequirement?
        if isCertificateSigned, let current = selfStaticCode {
            guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess else {
                throw UpdaterError.signature("no designated requirement")
            }
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckNestedCode))
        let status = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdaterError.signature(requirement == nil ? "invalid signature (\(status))" : "not signed by the same developer (\(status))")
        }
    }
}
