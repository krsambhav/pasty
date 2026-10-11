import AppKit
import Observation
import PastyCore

/// The content of the preview pane for the selected entry.
enum ClipDetailContent {
    /// Plain or rich text, already styled for display.
    case document(NSAttributedString, truncated: Bool)
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
            // An empty query lists the whole history (up to 50,000 entries); a search returns the
            // top 500 matches.
            let newItems = SearchQuery(query).isEmpty
                ? try await store.items(filter: filter, limit: 100_000)
                : try await store.search(query, filter: filter)
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
            // While the user flicks through the list, don't start decoding large previews for
            // rows they only pass over.
            if item.byteSize > DetailBuilder.debounceThreshold {
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled else { return }
            }
            let prepared = await DetailBuilder.build(for: item, store: store)
            guard !Task.isCancelled, let self, self.selectedID == item.id else { return }
            self.detail = ClipDetail(itemID: item.id, content: prepared.value)
        }
    }
}

/// Builds preview content entirely off the main thread: loading, decoding, RTF parsing, text
/// styling and image downsampling. The main thread only swaps the finished result in, so even a
/// 10,000-line or multi-megabyte entry never stalls the UI.
enum DetailBuilder {
    /// Entries larger than this get a short debounce before their preview is prepared.
    static let debounceThreshold = 200_000
    /// Characters shown in the preview (the full content is always what gets pasted).
    static let maxPreviewCharacters = 300_000
    /// Text with lines longer than this (minified code, base64) is previewed more briefly,
    /// because laying out one enormous paragraph is expensive.
    static let longLineThreshold = 10_000
    static let longLinePreviewCharacters = 50_000
    static let maxRichPreviewBytes = 1_000_000

    static func build(for item: ClipItem, store: ClipboardStore) async -> UncheckedSendable<ClipDetailContent> {
        guard let snapshot = try? await store.snapshot(for: item.id) else {
            return UncheckedSendable(value: .unavailable)
        }
        return await Task.detached(priority: .userInitiated) {
            UncheckedSendable(value: content(for: item, snapshot: snapshot))
        }.value
    }

    private static func content(for item: ClipItem, snapshot: PasteboardSnapshot) -> ClipDetailContent {
        guard let first = snapshot.items.first else { return .unavailable }
        switch item.kind {
        case .image:
            guard let image = first.data(forAnyOf: PasteboardType.images),
                  let cgImage = ImageTools.downsample(image.data, maxPixelSize: 1_600) else { return .unavailable }
            let size = CGSize(width: item.imageWidth, height: item.imageHeight)
            return .image(NSImage(cgImage: cgImage, size: .zero), pixelSize: size)
        case .file:
            return .files(snapshot.fileURLs)
        case .url:
            guard let text = snapshot.plainText, let url = ContentAnalyzer.detectURL(in: text) else { return .unavailable }
            return .link(url, display: ContentAnalyzer.readableURL(url))
        case .richText:
            if let rich = richText(from: first) { return .document(rich, truncated: false) }
            return plainDocument(snapshot, item: item)
        case .other:
            if let pdf = first.data(for: PasteboardType.pdf), pdf.count <= maxRichPreviewBytes * 5,
               let image = NSImage(data: pdf) {
                return .image(image, pixelSize: CGSize(width: image.size.width * 2, height: image.size.height * 2))
            }
            return .data(snapshot.items.flatMap(\.types))
        case .text:
            if item.lineCount == 1, let color = ColorParser.parse(item.title) {
                return .color(color, item.title)
            }
            return plainDocument(snapshot, item: item)
        }
    }

    /// The previewed slice of `text`, shortened further when it contains very long lines.
    static func previewSlice(of text: String) -> (text: String, truncated: Bool) {
        var limit = maxPreviewCharacters
        var lineLength = 0
        var scanned = 0
        for unit in text.utf16 {
            scanned += 1
            if scanned > maxPreviewCharacters { break }
            if unit == 10 { lineLength = 0; continue }
            lineLength += 1
            if lineLength > longLineThreshold {
                limit = longLinePreviewCharacters
                break
            }
        }
        guard text.utf16.count > limit else { return (text, false) }
        // Cut on a Character boundary at or before `limit` UTF-16 units.
        let index = text.utf16.index(text.utf16.startIndex, offsetBy: limit)
        let boundary = index.samePosition(in: text) ?? text.index(before: index)
        return (String(text[..<boundary]), true)
    }

    private static func plainDocument(_ snapshot: PasteboardSnapshot, item: ClipItem) -> ClipDetailContent {
        guard let full = snapshot.plainText ?? snapshot.items.first.flatMap(ContentAnalyzer.derivedText) else {
            return .unavailable
        }
        let (text, truncated) = previewSlice(of: full)
        let font: NSFont = item.isCode ? .monospacedSystemFont(ofSize: 12, weight: .regular) : Typeface.nsFont(13.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = item.isCode ? 2.5 : 3.5
        let document = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Theme.foregroundNS, .paragraphStyle: paragraph,
        ])
        return .document(document, truncated: truncated)
    }

    private static func richText(from item: PasteboardItemSnapshot) -> NSAttributedString? {
        var parsed: NSAttributedString?
        if let data = item.data(for: PasteboardType.rtfd), data.count <= maxRichPreviewBytes {
            parsed = NSAttributedString(rtfd: data, documentAttributes: nil)
        }
        if parsed == nil, let data = item.data(for: PasteboardType.rtf), data.count <= maxRichPreviewBytes {
            parsed = NSAttributedString(rtf: data, documentAttributes: nil)
        }
        // HTML import spins up WebKit and is main-thread only; such entries preview as plain text.
        guard let parsed, parsed.length <= maxPreviewCharacters else { return nil }
        return adaptingDefaultColors(parsed)
    }

    /// Rich text usually hard-codes black text; map default-looking colors to the dynamic
    /// foreground so it stays legible in Dark Mode, while keeping intentional colors intact.
    static func adaptingDefaultColors(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: result.length)
        let foreground = Theme.foregroundNS
        result.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            guard let color = (value as? NSColor)?.usingColorSpace(.sRGB) else {
                result.addAttribute(.foregroundColor, value: foreground, range: range)
                return
            }
            if color.saturationComponent < 0.1, color.brightnessComponent < 0.2 {
                result.addAttribute(.foregroundColor, value: foreground, range: range)
            }
        }
        result.enumerateAttribute(.backgroundColor, in: full) { value, range, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB), color.saturationComponent < 0.1, color.brightnessComponent > 0.9 {
                result.removeAttribute(.backgroundColor, range: range)
            }
        }
        return result
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
