import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PastyCore

/// Best-effort attribution of a clipboard change to an application.
enum SourceAppResolver {
    /// Prefers a bundle ID the writing app declared (`org.nspasteboard.source`), otherwise the
    /// frontmost app at the moment the change was noticed. Safe to call off the main thread.
    @Sendable
    static func resolve(declaredBundleID: String?) -> SourceApp? {
        if let declaredBundleID, !declaredBundleID.isEmpty {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: declaredBundleID).first
            let name = running?.localizedName ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: declaredBundleID)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            return SourceApp(bundleID: declaredBundleID, name: name)
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}

/// Accessibility (AX) trust is required to post the synthetic ⌘V that pastes into other apps.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security › Accessibility.
    @discardableResult
    static func requestWithPrompt() -> Bool {
        // The literal value of kAXTrustedCheckOptionPrompt (the global is not concurrency-safe in Swift 6).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Posts a ⌘V keystroke to whichever app has keyboard focus.
enum KeystrokeSender {
    static func pasteCommand() -> Bool {
        let keyCode = CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? UInt16(kVK_ANSI_V))
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }
        // Explicit flags: modifiers the user may still be holding (e.g. ⇧ from ⇧↩) must not leak
        // into the paste and turn it into "Paste and Match Style" or re-trigger our own hotkey.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Waits for a specific app to become active, driven by the workspace notification rather than a
/// fixed delay. A timeout guards against apps that never report activation.
@MainActor
final class ActivationWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private let pid: pid_t

    private init(pid: pid_t) {
        self.pid = pid
    }

    static func activate(_ app: NSRunningApplication, timeout: Duration = .milliseconds(800)) async -> Bool {
        // Note: while a non-activating panel is key, `NSApp.isActive` reads true even though the
        // other app keeps the menu bar. The frontmost application is the reliable signal.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            return true
        }
        let waiter = ActivationWaiter(pid: app.processIdentifier)
        return await waiter.run(app, timeout: timeout)
    }

    private func run(_ app: NSRunningApplication, timeout: Duration) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.continuation = continuation
            let pid = self.pid
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let activated = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                guard activated == pid else { return }
                MainActor.assumeIsolated { self?.finish(true) }
            }
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
            }
            app.activate()
        }
    }

    private func finish(_ result: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        timeoutTask?.cancel()
        continuation.resume(returning: result)
    }
}

/// Small main-thread caches for icons. NSImage is not Sendable, so these stay on the main actor.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let appIcons = NSCache<NSString, NSImage>()
    private let fileIcons = NSCache<NSString, NSImage>()

    private init() {
        fileIcons.countLimit = 300
    }

    func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = appIcons.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        appIcons.setObject(icon, forKey: bundleID as NSString)
        return icon
    }

    func fileIcon(path: String) -> NSImage {
        if let cached = fileIcons.object(forKey: path as NSString) { return cached }
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: .data)
        fileIcons.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// Decoded thumbnails keyed by item, loaded from the store on demand.
@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSNumber, NSImage>()
    private let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
        cache.countLimit = 400
    }

    func cached(_ id: ClipItem.ID) -> NSImage? {
        cache.object(forKey: NSNumber(value: id))
    }

    func load(_ id: ClipItem.ID) async -> NSImage? {
        if let cached = cached(id) { return cached }
        guard let data = try? await store.thumbnail(for: id), let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: NSNumber(value: id))
        return image
    }
}

/// Wraps a value that is safe to hand across isolation domains in practice (immutable CF types).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
