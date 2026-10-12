import AppKit
import PastyCore
import Quartz

/// Finder-style Quick Look for the selected entry (⌘Y, or a click on the preview).
///
/// Copied files are shown where they are; anything else is written to a temporary file first, so
/// images, text and rich text get the same full-size, zoomable window. As in Finder, Pasty's panel
/// stays key while Quick Look is up: arrows move through history and Quick Look follows, and Esc
/// closes Quick Look before Pasty.
@MainActor
final class QuickLookController: NSObject {
    private let store: ClipboardStore
    private weak var host: NSPanel?
    private var urls: [URL] = []
    /// The entry Quick Look shows (or is loading).
    private var shownID: ClipItem.ID?
    private var loadTask: Task<Void, Never>?
    nonisolated private static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Pasty Quick Look", isDirectory: true)

    /// Called when focus leaves both Pasty and Quick Look, e.g. a click in another app.
    var onFocusLost: (() -> Void)?

    init(store: ClipboardStore, host: NSPanel) {
        self.store = store
        self.host = host
        super.init()
        // Files written by an earlier run.
        try? FileManager.default.removeItem(at: Self.directory)
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// True while the Quick Look window itself has keyboard focus (the user clicked into it).
    var isKey: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isKeyWindow
    }

    func toggle(_ item: ClipItem?) {
        if isVisible {
            close()
        } else if let item {
            load(item, show: true)
        }
    }

    /// Keeps an open Quick Look on the selected entry.
    func follow(_ item: ClipItem?) {
        guard isVisible, let item, item.id != shownID else { return }
        load(item, show: false)
    }

    func close() {
        loadTask?.cancel()
        shownID = nil
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
        returnFocus()
    }

    private func load(_ item: ClipItem, show: Bool) {
        loadTask?.cancel()
        shownID = item.id
        loadTask = Task { [weak self, store] in
            let urls = await Self.files(for: item, store: store)
            guard !Task.isCancelled, let self, self.shownID == item.id else { return }
            if urls.isEmpty, show {
                NSSound.beep()
                self.shownID = nil
                return
            }
            self.urls = urls
            let panel = QLPreviewPanel.shared()!
            if show {
                panel.updateController()
                // Ordered front, not made key: typing and arrows keep going to Pasty.
                panel.orderFront(nil)
                self.raise(panel)
            }
            panel.reloadData()
        }
    }

    /// Above Pasty's panel, and on every Space with it.
    private func raise(_ panel: QLPreviewPanel) {
        guard let host else { return }
        panel.level = NSWindow.Level(rawValue: host.level.rawValue + 1)
        panel.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    private func returnFocus() {
        guard let host, host.isVisible, !host.isKeyWindow else { return }
        host.makeKey()
    }

    // MARK: Panel control (forwarded from `PastyPanel`)

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        raise(panel)
    }

    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        urls = []
        shownID = nil
    }

    // MARK: Files

    /// What Quick Look opens for an entry: the copied files themselves, or a temporary file
    /// holding the content in its richest previewable form.
    nonisolated private static func files(for item: ClipItem, store: ClipboardStore) async -> [URL] {
        guard let snapshot = try? await store.snapshot(for: item.id), let first = snapshot.items.first else { return [] }
        if item.kind == .file {
            return snapshot.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        let content: (data: Data, extension: String)?
        switch item.kind {
        case .image:
            content = first.data(forAnyOf: PasteboardType.images).map { ($0.data, imageExtension($0.type)) }
        case .richText:
            if let rtf = first.data(for: PasteboardType.rtf) {
                content = (rtf, "rtf")
            } else if let html = first.data(for: PasteboardType.html) {
                content = (html, "html")
            } else {
                content = snapshot.plainText.map { (Data($0.utf8), "txt") }
            }
        case .other:
            if let pdf = first.data(for: PasteboardType.pdf) {
                content = (pdf, "pdf")
            } else {
                content = first.data(forAnyOf: PasteboardType.images).map { ($0.data, imageExtension($0.type)) }
            }
        default:
            content = (snapshot.plainText ?? ContentAnalyzer.derivedText(from: first)).map { (Data($0.utf8), "txt") }
        }
        guard let content else { return [] }

        return await Task.detached(priority: .userInitiated) { () -> [URL] in
            // One folder per entry, so the window title can be the entry's own title.
            let folder = directory.appendingPathComponent(String(item.id), isDirectory: true)
            let url = folder.appendingPathComponent(fileName(for: item)).appendingPathExtension(content.extension)
            if !FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try content.data.write(to: url, options: .atomic)
                } catch {
                    return []
                }
            }
            return [url]
        }.value
    }

    nonisolated private static func imageExtension(_ type: String) -> String {
        switch type {
        case PasteboardType.png: "png"
        case PasteboardType.jpeg: "jpg"
        case PasteboardType.heic: "heic"
        case PasteboardType.gif: "gif"
        default: "tiff"
        }
    }

    /// The entry's title as a file name: one line, no path separators, not too long.
    nonisolated static func fileName(for item: ClipItem) -> String {
        let line = item.title.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var name = line
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.hasPrefix(".") { name.removeFirst() }
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" }
        return name.isEmpty ? item.kind.displayName : name
    }
}

// MARK: - Data source & delegate

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }

    func windowDidResignKey(_ notification: Notification) {
        // Quick Look was clicked into, and now focus moved on: back to Pasty is fine, anywhere
        // else dismisses both.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let host = self.host, host.isVisible, !host.isKeyWindow, !self.isKey else { return }
                self.onFocusLost?()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closed with its own close button or Esc while it had focus.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.returnFocus() }
        }
    }
}
