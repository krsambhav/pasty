import AppKit
import PastyCore
import SwiftUI
import UniformTypeIdentifiers

/// The history list, built on `NSTableView` for smooth, display-rate scrolling.
///
/// SwiftUI's `LazyVStack` rebuilds row views as they scroll in, and per-row hover, tooltip and
/// context-menu modifiers each install their own tracking machinery. Here, row views are reused,
/// hover is one tracking area for the whole table, menus are built on demand, and thumbnails load
/// asynchronously into whichever cell is still showing that item.
///
/// Mouse: a single click selects (and previews) an item; a double-click uses it.
struct ClipListView: NSViewRepresentable {
    let model: PanelModel
    let send: (PanelCommand) -> Void

    func makeCoordinator() -> ClipTableController {
        ClipTableController(model: model, send: send)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Reading these registers observation, so SwiftUI calls this when any of them change.
        context.coordinator.update(
            sections: model.sections,
            selectedID: model.selectedID,
            query: model.query,
            now: model.now,
            showsQuickKeys: model.showsQuickKeys,
            scrollTarget: model.scrollTarget
        )
    }
}

// MARK: - Controller

@MainActor
final class ClipTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row: Equatable {
        case header(String)
        case item(ClipItem)
    }

    static let itemHeight: CGFloat = 38
    static let headerHeight: CGFloat = 30
    static let horizontalInset: CGFloat = 6

    let scrollView = NSScrollView()
    let tableView = ClipTableView()
    private let model: PanelModel
    private let send: (PanelCommand) -> Void

    private var sections: [HistorySection] = []
    private var rows: [Row] = []
    private var rowIndexByID: [ClipItem.ID: Int] = [:]
    private var selectedID: ClipItem.ID?
    private var query = SearchQuery("")
    private var now = Date()
    private var quickKeyIDs: [ClipItem.ID] = []
    private var lastScrollToken: Int?
    fileprivate var hoveredRow: Int? {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow].compactMap({ $0 }) where row < rows.count {
                (tableView.rowView(atRow: row, makeIfNecessary: false) as? ClipRowView)?.isHovered = row == hoveredRow
            }
        }
    }

    init(model: PanelModel, send: @escaping (PanelCommand) -> Void) {
        self.model = model
        self.send = send
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        tableView.setAccessibilityLabel("Clipboard history")
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
    }

    // MARK: Updates from the model

    func update(sections newSections: [HistorySection], selectedID newSelection: ClipItem.ID?, query newQuery: String,
                now newNow: Date, showsQuickKeys: Bool, scrollTarget: PanelModel.ScrollTarget?) {
        let parsedQuery = SearchQuery(newQuery)
        let newQuickKeys = showsQuickKeys ? Array(newSections.lazy.flatMap(\.items).prefix(9).map(\.id)) : []

        if newSections != sections {
            sections = newSections
            rows = newSections.flatMap { section in [Row.header(section.title)] + section.items.map(Row.item) }
            var index: [ClipItem.ID: Int] = [:]
            index.reserveCapacity(rows.count)
            for (offset, row) in rows.enumerated() {
                if case let .item(item) = row { index[item.id] = offset }
            }
            rowIndexByID = index
            selectedID = newSelection
            query = parsedQuery
            now = newNow
            quickKeyIDs = newQuickKeys
            hoveredRow = nil
            tableView.reloadData()
        } else {
            var changedRows = IndexSet()
            if newSelection != selectedID {
                for id in [selectedID, newSelection].compactMap({ $0 }) {
                    if let row = rowIndexByID[id] { changedRows.insert(row) }
                }
                selectedID = newSelection
            }
            if parsedQuery != query || newNow != now || newQuickKeys != quickKeyIDs {
                query = parsedQuery
                now = newNow
                quickKeyIDs = newQuickKeys
                changedRows.formUnion(visibleRows)
            }
            for row in changedRows { refresh(row: row) }
        }

        if let scrollTarget, scrollTarget.token != lastScrollToken {
            lastScrollToken = scrollTarget.token
            scroll(to: scrollTarget.id)
        }
    }

    private var visibleRows: IndexSet {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return IndexSet(integersIn: range.location..<(range.location + range.length))
    }

    /// Reconfigures a visible row in place (no view churn).
    private func refresh(row: Int) {
        guard row < rows.count, case let .item(item) = rows[row] else { return }
        (tableView.rowView(atRow: row, makeIfNecessary: false) as? ClipRowView)?.isChosen = item.id == selectedID
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView {
            configure(cell, with: item)
        }
    }

    private func scroll(to id: ClipItem.ID) {
        guard let row = rowIndexByID[id] else { return }
        if row <= 1 {
            // The first item: reveal its section heading too.
            tableView.scroll(.zero)
        } else {
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return Self.headerHeight }
        return Self.itemHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipRowView")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipRowView ?? {
            let view = ClipRowView()
            view.identifier = identifier
            return view
        }()
        if case let .item(item) = rows[row] {
            view.isSelectable = true
            view.isChosen = item.id == selectedID
            view.isHovered = row == hoveredRow
        } else {
            view.isSelectable = false
            view.isChosen = false
            view.isHovered = false
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let identifier = NSUserInterfaceItemIdentifier("ClipHeader")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipHeaderView ?? {
                let cell = ClipHeaderView()
                cell.identifier = identifier
                return cell
            }()
            cell.title = title
            return cell
        case let .item(item):
            let identifier = NSUserInterfaceItemIdentifier("ClipCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipCellView ?? {
                let cell = ClipCellView()
                cell.identifier = identifier
                return cell
            }()
            configure(cell, with: item)
            return cell
        }
    }

    private func configure(_ cell: ClipCellView, with item: ClipItem) {
        let quickKey = quickKeyIDs.firstIndex(of: item.id).map { $0 + 1 }
        cell.configure(item: item, query: query, now: now, quickKey: quickKey, thumbnails: model.thumbnails)
    }

    // MARK: Mouse

    fileprivate func item(at row: Int) -> ClipItem? {
        guard row >= 0, row < rows.count, case let .item(item) = rows[row] else { return nil }
        return item
    }

    /// Single click: select, so the preview pane shows the item in full.
    fileprivate func clicked(row: Int) {
        guard let item = item(at: row) else { return }
        model.select(item)
    }

    /// Double click: use it (paste, or copy — per Settings).
    fileprivate func doubleClicked(row: Int) {
        guard let item = item(at: row) else { return }
        send(.activate(item, model.primaryAction))
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = item(at: tableView.clickedRow) else { return }
        model.select(item)
        func add(_ title: String, _ command: PanelCommand) {
            let entry = NSMenuItem(title: title, action: #selector(performMenuCommand(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = MenuCommand(command)
            menu.addItem(entry)
        }
        add("Paste", .activate(item, .paste))
        if item.kind == .text || item.kind == .richText || item.kind == .url {
            add("Paste as Plain Text", .activate(item, .pastePlainText))
        }
        add("Copy", .activate(item, .copy))
        menu.addItem(.separator())
        if item.kind == .url { add("Open Link", .open(item)) }
        if item.kind == .file { add("Show in Finder", .open(item)) }
        add(item.isPinned ? "Unpin" : "Pin", .togglePin(item))
        menu.addItem(.separator())
        add("Delete", .delete(item))
    }

    @objc private func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? MenuCommand)?.command else { return }
        send(command)
    }

    private final class MenuCommand: NSObject {
        let command: PanelCommand
        init(_ command: PanelCommand) { self.command = command }
    }
}

// MARK: - Table

/// Never takes keyboard focus (typing always goes to the search field) and handles clicks itself.
final class ClipTableView: NSTableView {
    weak var controller: ClipTableController?
    private var hoverArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        if event.clickCount >= 2 {
            controller?.doubleClicked(row: row)
        } else {
            controller?.clicked(row: row)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        controller?.hoveredRow = nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // Hover follows the content while scrolling, without per-row tracking areas.
        if let window {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if visibleRect.contains(location) { updateHover(at: location) } else { controller?.hoveredRow = nil }
        }
    }

    private func updateHover(at location: NSPoint) {
        let row = row(at: location)
        controller?.hoveredRow = controller?.item(at: row) == nil ? nil : row
    }
}

/// Draws the rounded selection / hover background (shadcn "accent").
final class ClipRowView: NSTableRowView {
    var isSelectable = true
    var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override var isOpaque: Bool { false }
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelectable, isChosen || isHovered else { return }
        let rect = bounds.insetBy(dx: ClipTableController.horizontalInset, dy: 0)
        Theme.NS.accent.withAlphaComponent(isChosen ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Theme.radiusMedium, yRadius: Theme.radiusMedium).fill()
    }
}

/// cmdk's CommandGroup heading.
final class ClipHeaderView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = Typeface.nsFont(12, .medium)
        label.textColor = Theme.NS.mutedForeground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ClipTableController.horizontalInset + 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// cmdk's CommandItem: icon, label, and a right-aligned slot for pin, time / shortcut and source.
final class ClipCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let swatch = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let pinView = NSImageView()
    private let timeField = NSTextField(labelWithString: "")
    private let keycap = NSTextField(labelWithString: "")
    private let appIconView = NSImageView()
    private var itemID: ClipItem.ID?
    private var hasThumbnailBorder = false
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)

        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Theme.radiusSmall
        iconView.layer?.masksToBounds = true
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = Theme.radiusSmall
        swatch.layer?.borderWidth = 1

        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pinView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        pinView.contentTintColor = Theme.NS.mutedForeground
        pinView.frameCenterRotation = -40

        timeField.font = Typeface.nsFont(11.5)
        timeField.textColor = Theme.NS.mutedForeground
        timeField.alignment = .right

        keycap.font = Typeface.nsFont(11, .medium)
        keycap.textColor = Theme.NS.mutedForeground
        keycap.alignment = .center
        keycap.wantsLayer = true
        keycap.layer?.cornerRadius = Theme.radiusSmall
        keycap.layer?.borderWidth = 0.5

        appIconView.imageScaling = .scaleProportionallyUpOrDown

        let trailing = NSStackView(views: [pinView, timeField, keycap, appIconView])
        trailing.orientation = .horizontal
        trailing.spacing = 7
        trailing.setHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [iconView, swatch, titleField, trailing] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = ClipTableController.horizontalInset + 8
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),
            swatch.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            swatch.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 18),
            swatch.heightAnchor.constraint(equalToConstant: 18),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 15),
            appIconView.heightAnchor.constraint(equalToConstant: 15),
            keycap.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            keycap.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerColors()
    }

    /// Layer colors are static CGColors, so they are re-resolved when the appearance changes.
    private func applyLayerColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            swatch.layer?.borderColor = Theme.NS.border.cgColor
            keycap.layer?.backgroundColor = Theme.NS.accent.cgColor
            keycap.layer?.borderColor = Theme.NS.border.cgColor
            iconView.layer?.borderColor = Theme.NS.border.cgColor
            iconView.layer?.borderWidth = hasThumbnailBorder ? 0.5 : 0
        }
    }

    func configure(item: ClipItem, query: SearchQuery, now: Date, quickKey: Int?, thumbnails: ThumbnailCache) {
        let isNewItem = item.id != itemID
        itemID = item.id

        titleField.attributedStringValue = Self.title(for: item, query: query)
        pinView.isHidden = !item.isPinned
        if let quickKey {
            keycap.stringValue = "⌘\(quickKey)"
            keycap.isHidden = false
            timeField.isHidden = true
        } else {
            keycap.isHidden = true
            timeField.isHidden = false
            timeField.stringValue = RelativeTime.short(item.updatedAt, now: now)
        }
        let appIcon = IconCache.shared.appIcon(bundleID: item.sourceBundleID)
        appIconView.image = appIcon
        appIconView.isHidden = appIcon == nil
        appIconView.toolTip = nil
        setAccessibilityLabel(ClipAccessibility.label(for: item, now: now))

        guard isNewItem else { return }
        loadTask?.cancel()
        configureIcon(for: item, thumbnails: thumbnails)
    }

    private func showThumbnail(_ image: NSImage) {
        iconView.image = image
        iconView.imageScaling = .scaleAxesIndependently
        iconView.contentTintColor = nil
        // Fill the square (crop) rather than letterbox.
        iconView.image = Self.squareCropped(image)
        hasThumbnailBorder = true
        applyLayerColors()
    }

    private func showIcon(_ image: NSImage?, tinted: Bool) {
        iconView.image = image
        iconView.imageScaling = tinted ? .scaleNone : .scaleProportionallyUpOrDown
        iconView.contentTintColor = tinted ? Theme.NS.mutedForeground : nil
        hasThumbnailBorder = false
        applyLayerColors()
    }

    private func configureIcon(for item: ClipItem, thumbnails: ThumbnailCache) {
        swatch.isHidden = true
        iconView.isHidden = false
        let symbol = { (name: String) in
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }

        switch item.kind {
        case .image:
            if let cached = thumbnails.cached(item.id) {
                showThumbnail(cached)
            } else {
                showIcon(symbol("photo"), tinted: true)
                let id = item.id
                loadTask = Task { [weak self] in
                    guard let image = await thumbnails.load(id), let self, self.itemID == id else { return }
                    self.showThumbnail(image)
                }
            }
        case .file:
            let path = item.filePath ?? "/"
            let previewable = FileThumbnails.hasContentPreview(path)
            if previewable, let cached = FileThumbnails.shared.cached(path: path, size: 48) {
                showThumbnail(cached)
            } else {
                showIcon(IconCache.shared.fileIcon(path: path), tinted: false)
                if previewable {
                    let id = item.id
                    loadTask = Task { [weak self] in
                        guard let image = await FileThumbnails.shared.thumbnail(path: path, size: 48),
                              let self, self.itemID == id else { return }
                        self.showThumbnail(image)
                    }
                }
            }
        default:
            if item.lineCount == 1, let color = ColorParser.parse(item.title) {
                iconView.isHidden = true
                swatch.isHidden = false
                swatch.layer?.backgroundColor = color.cgColor
            } else {
                showIcon(symbol(item.symbolName), tinted: true)
            }
        }
    }

    /// Center-crops a thumbnail to a square so it fills the 24 pt icon slot.
    private static func squareCropped(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let side = min(cgImage.width, cgImage.height)
        let rect = CGRect(x: (cgImage.width - side) / 2, y: (cgImage.height - side) / 2, width: side, height: side)
        guard let cropped = cgImage.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: 24, height: 24))
    }

    /// The row title with search matches emphasized.
    static func title(for item: ClipItem, query: SearchQuery) -> NSAttributedString {
        let text = item.title.isEmpty ? " " : item.title
        let font = item.isCode ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) : Typeface.nsFont(13.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: Theme.NS.foreground, .paragraphStyle: paragraph,
        ])
        guard !query.isEmpty else { return result }
        let bold = item.isCode ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold) : Typeface.nsFont(13.5, .semibold)
        for range in SearchRanker.highlightRanges(in: text, query: query) {
            result.addAttributes([.font: bold, .backgroundColor: Theme.NS.highlight], range: NSRange(range, in: text))
        }
        return result
    }
}

extension FileThumbnails {
    /// Files whose QuickLook thumbnail shows their content rather than an icon.
    nonisolated static func hasContentPreview(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension) else { return false }
        return [UTType.image, .pdf, .movie, .presentation, .spreadsheet, .text].contains { type.conforms(to: $0) }
    }
}
