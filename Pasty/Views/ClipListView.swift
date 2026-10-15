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
/// Mouse: a single click selects (and previews) an item; a double-click uses it; dragging an item
/// drops its contents into another app (or, for files, images and PDFs, into Finder).
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
            items: model.items,
            sections: model.sections,
            selectedIndex: model.selectedIndex,
            query: model.query,
            now: model.now,
            showsQuickKeys: model.showsQuickKeys,
            scrollTarget: model.scrollTarget
        )
    }
}

// MARK: - Controller

@MainActor
final class ClipTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSDraggingSource {
    enum Row: Equatable {
        case header(String)
        /// An entry, by its index in the model's list.
        case item(Int)
    }

    /// Every row is the same height, so the table never asks per-row heights — with a million
    /// rows that matters — and section headings sit in an item-sized row.
    static let rowHeight: CGFloat = 38
    static let horizontalInset: CGFloat = 6

    let scrollView = NSScrollView()
    let tableView = ClipTableView()
    private let model: PanelModel
    private let send: (PanelCommand) -> Void

    private var items = ClipList.empty
    private var sections: [ListSection] = []
    private var rowCount = 0
    private var selectedIndex: Int?
    private var query = SearchQuery("")
    private var now = Date()
    private var quickKeyIDs: [ClipItem.ID] = []
    private var lastScrollToken: Int?
    fileprivate var hoveredRow: Int? {
        didSet {
            guard hoveredRow != oldValue else { return }
            for row in [oldValue, hoveredRow].compactMap({ $0 }) where row < rowCount {
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
        tableView.rowHeight = Self.rowHeight
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
        // No visible scroller: the list still scrolls with the trackpad, mouse wheel and keyboard.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .allowed
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        tableView.clipViewDidScroll()
    }

    // MARK: Updates from the model

    func update(items newItems: ClipList, sections newSections: [ListSection], selectedIndex newSelection: Int?, query newQuery: String,
                now newNow: Date, showsQuickKeys: Bool, scrollTarget: PanelModel.ScrollTarget?) {
        let parsedQuery = SearchQuery(newQuery)

        if newItems != items || newSections != sections {
            items = newItems
            sections = newSections
            rowCount = newSections.reduce(0) { $0 + 1 + $1.count }
            selectedIndex = newSelection
            query = parsedQuery
            now = newNow
            quickKeyIDs = showsQuickKeys ? Self.quickKeys(in: newItems) : []
            hoveredRow = nil
            tableView.reloadData()
        } else {
            let newQuickKeys = showsQuickKeys ? Self.quickKeys(in: newItems) : []
            var changedRows = IndexSet()
            if newSelection != selectedIndex {
                for index in [selectedIndex, newSelection].compactMap({ $0 }) {
                    if let row = row(forItem: index) { changedRows.insert(row) }
                }
                selectedIndex = newSelection
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
            scroll(toItem: scrollTarget.index)
        }
    }

    private static func quickKeys(in items: ClipList) -> [ClipItem.ID] {
        (0..<min(9, items.count)).map { items[$0].id }
    }

    // MARK: Rows

    /// What a table row shows: each section is a heading row followed by its entries.
    func content(ofRow row: Int) -> Row? {
        var first = 0
        for section in sections {
            if row == first { return .header(section.title) }
            if row <= first + section.count { return .item(section.start + row - first - 1) }
            first += 1 + section.count
        }
        return nil
    }

    /// The table row showing entry `index`.
    func row(forItem index: Int) -> Int? {
        for (number, section) in sections.enumerated() where section.range.contains(index) {
            return index + number + 1
        }
        return nil
    }

    private var visibleRows: IndexSet {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.location != NSNotFound else { return [] }
        return IndexSet(integersIn: range.location..<(range.location + range.length))
    }

    /// Reconfigures a visible row in place (no view churn).
    private func refresh(row: Int) {
        guard case let .item(index)? = content(ofRow: row) else { return }
        (tableView.rowView(atRow: row, makeIfNecessary: false) as? ClipRowView)?.isChosen = index == selectedIndex
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ClipCellView {
            configure(cell, with: items[index])
        }
    }

    private func scroll(toItem index: Int) {
        guard let row = row(forItem: index) else { return }
        if row <= 1 {
            // The first item: reveal its section heading too.
            tableView.scroll(.zero)
        } else {
            tableView.scrollRowToVisible(row)
        }
    }

    // MARK: Data source & delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ClipRowView")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipRowView ?? {
            let view = ClipRowView()
            view.identifier = identifier
            return view
        }()
        if case let .item(index)? = content(ofRow: row) {
            view.isEntry = true
            view.isChosen = index == selectedIndex
            view.isHovered = row == hoveredRow
        } else {
            view.isEntry = false
            view.isChosen = false
            view.isHovered = false
        }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch content(ofRow: row) {
        case let .header(title)?:
            let identifier = NSUserInterfaceItemIdentifier("ClipHeader")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipHeaderView ?? {
                let cell = ClipHeaderView()
                cell.identifier = identifier
                return cell
            }()
            cell.title = title
            return cell
        case let .item(index)?:
            let identifier = NSUserInterfaceItemIdentifier("ClipCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ClipCellView ?? {
                let cell = ClipCellView()
                cell.identifier = identifier
                return cell
            }()
            configure(cell, with: items[index])
            return cell
        case nil:
            return nil
        }
    }

    private func configure(_ cell: ClipCellView, with item: ClipItem) {
        let quickKey = quickKeyIDs.firstIndex(of: item.id).map { $0 + 1 }
        cell.configure(item: item, query: query, now: now, quickKey: quickKey, thumbnails: model.thumbnails)
    }

    // MARK: Mouse

    fileprivate func itemIndex(at row: Int) -> Int? {
        guard row >= 0, row < rowCount, case let .item(index)? = content(ofRow: row) else { return nil }
        return index
    }

    fileprivate func item(at row: Int) -> ClipItem? {
        itemIndex(at: row).flatMap { items.item(at: $0) }
    }

    /// Single click: select, so the preview pane shows the item in full.
    fileprivate func clicked(row: Int) {
        guard let index = itemIndex(at: row) else { return }
        model.select(at: index)
    }

    /// Double click: use it (paste, or copy — per Settings).
    fileprivate func doubleClicked(row: Int) {
        guard let item = item(at: row) else { return }
        send(.activate(item, model.primaryAction))
    }

    // MARK: Dragging

    /// Starts dragging the entry in `row` out of the list, with everything it was copied with.
    fileprivate func beginDrag(fromRow row: Int, event: NSEvent) {
        guard let item = item(at: row), let snapshot = model.storedSnapshot(for: item.id) else { return }
        model.select(at: itemIndex(at: row)!)

        let pasteboardItems = snapshot.items.map { itemSnapshot in
            let pasteboardItem = NSPasteboardItem()
            for rep in itemSnapshot.representations {
                pasteboardItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
            }
            return pasteboardItem
        }
        // Images and PDFs also travel as a file, so dropping one in Finder (or on an upload
        // field) gives a file rather than nothing. Text stays text: editors would insert a file.
        if item.kind == .image || item.kind == .other, let first = pasteboardItems.first,
           !snapshot.allTypes.contains(PasteboardType.fileURL),
           let content = QuickLookController.fileContent(for: item, snapshot: snapshot),
           let url = QuickLookController.temporaryFile(content, for: item) {
            first.setString(url.absoluteString, forType: .fileURL)
        }

        let frame = tableView.rect(ofRow: row)
        let image = rowImage(row) as Any?
        let draggingItems = pasteboardItems.enumerated().map { index, pasteboardItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            draggingItem.setDraggingFrame(frame, contents: index == 0 ? image : nil)
            return draggingItem
        }
        let session = tableView.beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// The row as it looks now (highlight included), to drag around.
    private func rowImage(_ row: Int) -> NSImage? {
        guard let view = tableView.rowView(atRow: row, makeIfNecessary: false),
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // A copy: the entry stays in history, and Finder never moves a copied file.
        context == .outsideApplication ? .copy : []
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let index = itemIndex(at: tableView.clickedRow), let item = items.item(at: index) else { return }
        model.select(at: index)
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
        add(item.kind == .url ? "Open Link" : "Open", .open(item))
        if item.kind == .file { add("Show in Finder", .revealInFinder(item)) }
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
    /// The click that may turn into a drag, until the mouse goes up or moves far enough.
    private var pendingDragEvent: NSEvent?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        pendingDragEvent = nil
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        if event.clickCount >= 2 {
            controller?.doubleClicked(row: row)
        } else {
            pendingDragEvent = event
            controller?.clicked(row: row)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pendingDragEvent else { return }
        let origin = convert(start.locationInWindow, from: nil)
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - origin.x, location.y - origin.y) >= 4 else { return }
        pendingDragEvent = nil
        controller?.beginDrag(fromRow: row(at: origin), event: start)
    }

    override func mouseUp(with event: NSEvent) {
        pendingDragEvent = nil
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

    // No `scrollWheel(with:)` override: one disables AppKit's responsive scrolling, which caps
    // scrolling at 60 Hz on ProMotion displays. Hover follows scrolling via `clipViewDidScroll()`.

    /// Hover follows the content while scrolling, without per-row tracking areas.
    func clipViewDidScroll() {
        guard let window else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(location) { updateHover(at: location) } else { controller?.hoveredRow = nil }
    }

    private func updateHover(at location: NSPoint) {
        let row = row(at: location)
        controller?.hoveredRow = controller?.item(at: row) == nil ? nil : row
    }
}

/// Draws the rounded selection / hover background (shadcn "accent").
final class ClipRowView: NSTableRowView {
    var isEntry = true
    var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override var isOpaque: Bool { false }
    override func drawSelection(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard isEntry, isChosen || isHovered else { return }
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
