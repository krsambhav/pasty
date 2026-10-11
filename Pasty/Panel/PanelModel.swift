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
    /// No visual form; lists the stored types.
    case data([String])
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
    /// Entries in display order. Selection and ⌘1–⌘9 operate on this flat list.
    private(set) var items: [ClipItem] = []
    /// The same entries grouped for display ("Today", "Pinned", "Results"…).
    private(set) var sections: [HistorySection] = []
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
    /// Set when the user moves the selection after the query changed, so late-arriving results
    /// don't yank it back to the top.
    @ObservationIgnored private var selectionMovedSinceQueryChange = false

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
        selectionMovedSinceQueryChange = false
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
        selectionMovedSinceQueryChange = false
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
        // Remember where the selection was, so removing it (delete, unpin in Pinned) selects
        // the neighbour that slid into its place rather than jumping back to the top.
        let previousIndex = selectedIndex
        if newItems != items { items = newItems }
        let grouped: [HistorySection]
        if newItems.isEmpty {
            grouped = []
        } else if !SearchQuery(query).isEmpty {
            grouped = [HistorySection(title: newItems.count == 1 ? "1 Result" : "\(newItems.count.formatted()) Results", items: newItems)]
        } else if filter == .pinned {
            grouped = [HistorySection(title: "Pinned", items: newItems)]
        } else {
            grouped = HistorySections.byDate(newItems, now: Date())
        }
        if grouped != sections { sections = grouped }
        totalCount = total
        hasLoaded = true
        let keepUserSelection = selectionMovedSinceQueryChange && newItems.contains { $0.id == selectedID }
        if (resetSelection && !keepUserSelection) || selectedID == nil {
            selectFirst()
        } else if !newItems.contains(where: { $0.id == selectedID }) {
            if let previousIndex, !newItems.isEmpty {
                let item = newItems[min(previousIndex, newItems.count - 1)]
                selectedID = item.id
                requestScroll(to: item.id)
            } else {
                selectFirst()
            }
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
        selectionMovedSinceQueryChange = true
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
        case .other:
            if let pdf = first.data(for: PasteboardType.pdf), pdf.count <= maxRichPreviewBytes * 5,
               let image = NSImage(data: pdf) {
                return .image(image, pixelSize: CGSize(width: image.size.width * 2, height: image.size.height * 2))
            }
            return .data(snapshot.items.flatMap(\.types))
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

extension ClipItem {
    /// SF Symbol for the entry's type.
    var symbolName: String {
        if isCode { return "chevron.left.forwardslash.chevron.right" }
        switch kind {
        case .text: return "text.alignleft"
        case .richText: return "textformat"
        case .url: return "link"
        case .image: return "photo"
        case .file: return "doc"
        case .other: return "shippingbox"
        }
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

/// Hex colors as `NSColor`, for swatches.
enum ColorParser {
    static func parse(_ text: String) -> NSColor? {
        guard let color = HexColor(text) else { return nil }
        return NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
