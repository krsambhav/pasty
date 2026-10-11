import AppKit
import Observation
import PastyCore

/// The content of the preview pane for the selected entry.
enum ClipDetailContent {
    case text(String, isCode: Bool, truncated: Bool)
    case rich(NSAttributedString)
    case image(NSImage, pixelSize: CGSize)
    case files([URL])
    case link(URL, display: String)
    case color(NSColor, String)
    case unavailable
}

struct ClipDetail {
    let itemID: ClipItem.ID
    let content: ClipDetailContent
}

enum PanelCommand {
    case activate(ClipItem, PasteAction)
    case togglePin(ClipItem)
    case delete(ClipItem)
    case open(ClipItem)
    case showSettings
    case resumeMonitoring
}

/// State for the floating panel. Lives for the app's lifetime so opening is instant.
@MainActor
@Observable
final class PanelModel {
    var query = "" {
        didSet { if query != oldValue { queryDidChange() } }
    }
    var filter: ClipFilter = .all {
        didSet { if filter != oldValue { queryDidChange() } }
    }
    private(set) var items: [ClipItem] = []
    var selectedID: ClipItem.ID? {
        didSet { if selectedID != oldValue { loadDetail() } }
    }
    private(set) var detail: ClipDetail?
    /// Total entries in history, to tell "nothing yet" apart from "no matches".
    private(set) var totalCount = 0
    private(set) var hasLoaded = false
    var isPaused: Bool
    /// Reference time for relative timestamps; refreshed on every presentation.
    var now = Date()
    /// True while ⌘ is held: rows show their ⌘1–⌘9 shortcuts.
    var showsQuickKeys = false
    /// Bumped to ask the list to scroll the selection into view.
    private(set) var scrollTarget: ScrollTarget?
    /// Duration of the most recent completed query, for diagnostics.
    @ObservationIgnored private(set) var lastQueryDuration: Duration = .zero

    struct ScrollTarget: Equatable {
        let id: ClipItem.ID
        let token: Int
    }

    @ObservationIgnored let store: ClipboardStore
    @ObservationIgnored let thumbnails: ThumbnailCache
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scrollToken = 0

    init(store: ClipboardStore, preferences: Preferences) {
        self.store = store
        self.preferences = preferences
        thumbnails = ThumbnailCache(store: store)
        isPaused = preferences.isPaused
    }

    var selectedItem: ClipItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    var primaryAction: PasteAction {
        preferences.pasteOnSelect ? .paste : .copy
    }

    // MARK: Presentation

    /// Resets transient state so every opening starts at the newest entry with an empty query.
    func prepareForPresentation() {
        now = Date()
        showsQuickKeys = false
        if query.isEmpty && filter == .all {
            selectFirst()
        } else {
            query = ""
            filter = .all
        }
    }

    // MARK: Loading

    /// Re-runs the current query and awaits the result.
    func reload() async {
        await runQuery()
    }

    /// Coalesces bursts of history changes (e.g. rapid copies) into one reload.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            await self?.runQuery()
        }
    }

    private func queryDidChange() {
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            await self?.runQuery(resetSelection: true)
        }
    }

    private func runQuery(resetSelection: Bool = false) async {
        generation += 1
        let current = generation
        let query = query
        let filter = filter
        let started = ContinuousClock.now
        do {
            let newItems = try await store.search(query, filter: filter)
            let newTotal = try await store.count()
            // A newer query superseded this one while it ran.
            guard current == generation else { return }
            lastQueryDuration = ContinuousClock.now - started
            apply(newItems, total: newTotal, resetSelection: resetSelection)
        } catch {
            NSLog("Pasty: query failed: \(error)")
        }
    }

    private func apply(_ newItems: [ClipItem], total: Int, resetSelection: Bool) {
        if newItems != items { items = newItems }
        totalCount = total
        hasLoaded = true
        if resetSelection || selectedID == nil || !newItems.contains(where: { $0.id == selectedID }) {
            selectFirst()
        } else if detail?.itemID != selectedID {
            loadDetail()
        }
    }

    // MARK: Selection

    func selectFirst() {
        selectedID = items.first?.id
        if let id = selectedID { requestScroll(to: id) }
    }

    func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? -1
        let next = min(max(current + offset, 0), items.count - 1)
        select(items[next])
    }

    func moveToEdge(top: Bool) {
        guard let item = top ? items.first : items.last else { return }
        select(item)
    }

    func select(_ item: ClipItem) {
        selectedID = item.id
        requestScroll(to: item.id)
        announce(item)
    }

    private func requestScroll(to id: ClipItem.ID) {
        scrollToken += 1
        scrollTarget = ScrollTarget(id: id, token: scrollToken)
    }

    /// VoiceOver users keep focus in the search field, so selection changes are announced.
    private func announce(_ item: ClipItem) {
        guard NSWorkspace.shared.isVoiceOverEnabled, let window = NSApp.keyWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [.announcement: ClipAccessibility.label(for: item, now: now), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )
    }

    // MARK: Detail

    private func loadDetail() {
        detailTask?.cancel()
        guard let item = selectedItem else {
            detail = nil
            return
        }
        if detail?.itemID != item.id { detail = nil }
        detailTask = Task { [weak self, store] in
            let content = await Self.makeDetail(for: item, store: store)
            guard !Task.isCancelled, let self, self.selectedID == item.id else { return }
            self.detail = ClipDetail(itemID: item.id, content: content)
        }
    }

    private static let maxPreviewCharacters = 300_000
    private static let maxRichPreviewBytes = 2_000_000

    private static func makeDetail(for item: ClipItem, store: ClipboardStore) async -> ClipDetailContent {
        guard let snapshot = try? await store.snapshot(for: item.id), let first = snapshot.items.first else {
            return .unavailable
        }
        switch item.kind {
        case .image:
            guard let image = first.data(forAnyOf: PasteboardType.images) else { return .unavailable }
            let data = image.data
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageTools.downsample(data, maxPixelSize: 1_600).map(UncheckedSendable.init)
            }.value
            guard let cgImage = decoded?.value else { return .unavailable }
            let size = CGSize(width: item.imageWidth, height: item.imageHeight)
            return .image(NSImage(cgImage: cgImage, size: .zero), pixelSize: size)
        case .file:
            return .files(snapshot.fileURLs)
        case .url:
            guard let text = snapshot.plainText, let url = ContentAnalyzer.detectURL(in: text) else { return .unavailable }
            return .link(url, display: ContentAnalyzer.readableURL(url))
        case .richText:
            if let rich = richText(from: first) { return .rich(rich) }
            return plainText(snapshot, item: item)
        case .text:
            if let color = ColorParser.parse(item.title), item.lineCount == 1 {
                return .color(color, item.title)
            }
            return plainText(snapshot, item: item)
        }
    }

    private static func plainText(_ snapshot: PasteboardSnapshot, item: ClipItem) -> ClipDetailContent {
        guard let text = snapshot.plainText else { return .unavailable }
        let truncated = text.utf16.count > maxPreviewCharacters
        return .text(truncated ? String(text.prefix(maxPreviewCharacters)) : text, isCode: item.isCode, truncated: truncated)
    }

    private static func richText(from item: PasteboardItemSnapshot) -> NSAttributedString? {
        if let data = item.data(for: PasteboardType.rtfd), data.count <= maxRichPreviewBytes,
           let string = NSAttributedString(rtfd: data, documentAttributes: nil) {
            return string
        }
        if let data = item.data(for: PasteboardType.rtf), data.count <= maxRichPreviewBytes,
           let string = NSAttributedString(rtf: data, documentAttributes: nil) {
            return string
        }
        // HTML import spins up WebKit and is too slow for a live preview; plain text is used instead.
        return nil
    }
}

enum ClipAccessibility {
    static func label(for item: ClipItem, now: Date) -> String {
        var parts = [item.isCode ? "Code" : item.kind.displayName, item.title]
        if item.isPinned { parts.append("pinned") }
        if let source = item.sourceName { parts.append("from \(source)") }
        parts.append(RelativeTime.short(item.updatedAt, now: now))
        return parts.joined(separator: ", ")
    }
}

/// Recognizes CSS-style hex colors so they can be previewed as swatches.
enum ColorParser {
    static func parse(_ text: String) -> NSColor? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() } else { return nil }
        guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
