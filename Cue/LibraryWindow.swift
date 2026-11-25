import AppKit
import Combine

private enum Screen: Equatable {
    case catalog(Catalog), artist(id: String?, name: String), artistTracks(id: String, name: String), album(Album), queue

    var catalogRequest: (kind: Catalog, artist: ArtistFilter?)? {
        switch self {
        case .catalog(let kind): return (kind, nil)
        case .artist(let id, let name): return (.albums, id.map(ArtistFilter.id) ?? .name(name))
        case .artistTracks(let id, _): return (.tracks, .id(id))
        default: return nil
        }
    }

    var heading: String {
        switch self {
        case .catalog(let kind): kind.title
        case .artist(_, let name): name
        case .artistTracks(_, let name): "\(name) — Tracks"
        case .album(let album): album.title
        case .queue: "Queue"
        }
    }
    var columns: [CatalogOrder.Field] {
        switch self {
        case .catalog(.artists): [.artist]
        case .artist, .catalog(.albums): [.album, .artist, .year]
        case .album: [.number, .track, .artist, .duration]
        case .artistTracks, .catalog(.tracks): [.number, .track, .artist, .album, .duration]
        case .queue: [.track, .artist, .album, .duration]
        }
    }

    var availableColumns: [CatalogOrder.Field] {
        switch self {
        case .catalog(.artists), .catalog(.albums), .artist: columns + [.recent]
        case .album: columns + [.disc, .year, .albumArtist, .album]
        case .artistTracks, .catalog(.tracks): columns + [.disc, .year, .albumArtist]
        case .queue: columns + [.number, .disc, .year, .albumArtist, .position]
        }
    }

    var viewKey: String {
        switch self {
        case .catalog(let kind): kind.title
        case .artistTracks: "ArtistTracks"
        case .artist: "ArtistAlbums"
        case .album: "AlbumTracks"
        case .queue: "Queue"
        }
    }
}

private struct TablePosition {
    var firstRow = 0
    var origin: NSPoint?
    var selectedRow = -1
    var queueSelection = Set<UUID>()
}

private struct Location {
    var screen: Screen
    var query = ""
    var position = TablePosition()
    var order = CatalogOrder.standard(for: .albums)
}

private final class TitlebarBackground: NSView {
    var isWindowKey = false { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isWindowKey {
            drawWindowGradient(in: self)
        } else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
    }
}

private final class PlacesBar: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        let area = dirtyRect.intersection(bounds)
        NSColor.windowBackgroundColor.setFill()
        area.fill()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        area.fill()
        super.draw(dirtyRect)
    }
}

private final class LibraryCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .left
        label.allowsExpansionToolTips = true
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }
}

private final class PlayerWindow: NSWindow {
    var playPause: (() -> Void)?

    var acceptsPlaybackSpace: Bool {
        attachedSheet == nil && (firstResponder === self || firstResponder is MusicTable)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           acceptsPlaybackSpace, let playPause {
            if !event.isARepeat { playPause() }
            return
        }
        super.sendEvent(event)
    }
}

private final class MusicTable: NSTableView {
    var openSelection: (() -> Void)?
    var rowMenu: ((Int) -> NSMenu?)?
    weak var searchField: NSSearchField?

    var deleteSelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        if allowsMultipleSelection, event.keyCode == 51 || event.keyCode == 117 {
            if !event.isARepeat { deleteSelection?() }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelection?()
            return
        }
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              event.specialKey == nil, let keys = event.charactersIgnoringModifiers,
              keys.rangeOfCharacter(from: CharacterSet.controlCharacters.union(.whitespacesAndNewlines).inverted) != nil,
              let searchField, window?.makeFirstResponder(searchField) == true,
              let editor = searchField.currentEditor() else {
            super.keyDown(with: event)
            return
        }
        editor.selectAll(nil)
        editor.keyDown(with: event)
    }
}

@MainActor
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSToolbarDelegate {
    private struct RowMenuSelection {
        let row: MusicRow
        let albumTracks: [Track]?
        let revision: Int
    }

    private static let queueTab = Catalog.allCases.count
    private let store: LibraryStore
    private let table = MusicTable()
    private let tabs = NSSegmentedControl(labels: Catalog.allCases.map(\.title) + ["Queue"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let breadcrumbs = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private lazy var transport = Transport(player: store.player, target: self, action: #selector(toggle))
    let columnMenu = NSMenu(title: "Columns")
    private let columnButton = NSButton()
    private let retry = NSButton()
    private lazy var plexItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: Self.connectionItem)
        item.target = self
        item.action = #selector(connect)
        item.isBordered = true
        return item
    }()
    private var connection: NSWindow?
    private var location = Location(screen: .catalog(.albums))
    private var preferredOrders: [String: CatalogOrder] = [:]
    private var history: [Location] = []
    private var activeTab: Int?
    private var savedTabs: [Int: [Location]] = [:]
    private var albumTracks: [Track]?
    private static let queueDragType = NSPasteboard.PasteboardType("org.cueplayer.queue-entry")
    private var displayedQueue: ArraySlice<QueueEntry> = []
    private var queueRevision: Int?
    private var trackIndices = TrackIndices.natural(count: 0, reversed: false)
    private var loading = false
    private var catalog = CatalogRows()
    // Keep one bounded viewport for Back and tab switches.
    private var catalogRevision: Int?
    private var previousCatalog: (location: Location, revision: Int, rows: CatalogRows)?
    private var lastViewport = 0..<0
    private var pendingOffset: Int?
    private var failedOffset: Int?
    private var job: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(store: LibraryStore) {
        self.store = store
        let window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Cue"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 610, height: 300)
        window.center()
        window.playPause = { [weak self] in self?.toggle() }
        build(window)
        store.player.setProgressVisible(window.occlusionState.contains(.visible))
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
            .sink { [weak window, weak player = store.player] _ in
                player?.setProgressVisible(window?.occlusionState.contains(.visible) == true)
            }.store(in: &subscriptions)
        store.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateConnectionButton()
            self.previousCatalog = nil
            self.catalogRevision = nil
            self.savedTabs.removeAll()
            self.activeTab = nil
            self.selectTab(0)
        }.store(in: &subscriptions)
        store.$showConnection.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] show in
            self?.presentConnection(show)
        }.store(in: &subscriptions)
        store.player.$queue.dropFirst().map { _ in () }.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, case .queue = location.screen, queueRevision != store.player.queueRevision else { return }
            location = currentLocation()
            reload()
        }.store(in: &subscriptions)
        store.player.$queue.map(\.count).removeDuplicates().receive(on: RunLoop.main).sink { [weak self] count in
            self?.updateQueueBadge(count)
        }.store(in: &subscriptions)
        store.player.$current.map { $0?.id }.removeDuplicates()
            .scan((previous: UUID?.none, current: UUID?.none)) { ($0.current, $1) }
            .receive(on: RunLoop.main).sink { [weak self] change in
                guard let self, case .queue = location.screen else { return }
                let changedRows = visibleRows.filter { row in
                    guard self.trackIndices.indices.contains(row) else { return false }
                    let id = self.displayedQueue[position: self.trackIndices[row]].id
                    return id == change.previous || id == change.current
                }
                guard !changedRows.isEmpty else { return }
                table.reloadData(forRowIndexes: IndexSet(changedRows), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
            }.store(in: &subscriptions)
        selectTab(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ window: NSWindow) {
        let content = NSView()
        window.contentView = content
        let contentTop = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? content.topAnchor
        let titlebar = TitlebarBackground()
        titlebar.translatesAutoresizingMaskIntoConstraints = false
        titlebar.setAccessibilityElement(false)
        content.addSubview(titlebar)
        titlebar.isWindowKey = window.isKeyWindow
        let notifications = NotificationCenter.default
        notifications.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .merge(with: notifications.publisher(for: NSWindow.didResignKeyNotification, object: window))
            .sink { [weak titlebar] in titlebar?.isWindowKey = $0.name == NSWindow.didBecomeKeyNotification }
            .store(in: &subscriptions)

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            titlebar.topAnchor.constraint(equalTo: content.topAnchor),
            titlebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            titlebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titlebar.bottomAnchor.constraint(equalTo: contentTop),
            root.topAnchor.constraint(equalTo: contentTop),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        func divider() {
            let rule = NSBox()
            rule.boxType = .separator
            root.addArrangedSubview(rule)
            rule.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        func bar(_ stack: NSStackView, inset: CGFloat) {
            stack.spacing = 8
            stack.edgeInsets = .init(top: inset, left: 10, bottom: inset, right: 10)
            root.addArrangedSubview(stack)
            stack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            divider()
        }
        func configure(_ button: NSButton, _ title: String, _ action: Selector) {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        tabs.segmentStyle = .texturedSquare
        tabs.controlSize = .small
        tabs.font = .systemFont(ofSize: 12, weight: .medium)
        for catalog in Catalog.allCases {
            let image = NSImage(systemSymbolName: catalog.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            tabs.setImage(image, forSegment: catalog.rawValue)
        }
        updateQueueBadge(store.player.queue.count)
        tabs.target = self
        tabs.action = #selector(changeTab)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 185).isActive = true
        updateConnectionButton()
        let toolbar = NSToolbar(identifier: "CueLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        configure(columnButton, "Columns", #selector(showColumns(_:)))
        columnButton.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        columnButton.imagePosition = .imageOnly
        columnButton.toolTip = "Choose columns"
        columnButton.setAccessibilityLabel("Choose columns")
        columnButton.menu = columnMenu
        tabs.menu = columnMenu
        let places = PlacesBar(views: [tabs, NSView(), columnButton, search])
        places.menu = columnMenu
        bar(places, inset: 5)
        configure(backButton, "Back", #selector(back))
        backButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: nil)
        backButton.imagePosition = .imageOnly
        backButton.isBordered = false
        backButton.setAccessibilityLabel("Back")
        backButton.toolTip = "Back (⌘[)"
        breadcrumbs.spacing = 5
        breadcrumbs.detachesHiddenViews = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(retry, "Retry", #selector(retryLoading))
        bar(NSStackView(views: [backButton, breadcrumbs, NSView(), status, retry]), inset: 4)
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.rowMenu = { [weak self] row in self?.rowMenu(at: row) }
        table.registerForDraggedTypes([Self.queueDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.deleteSelection = { [weak self] in
            guard let self, !loading, case .queue = location.screen else { return }
            store.player.removeQueuedEntries(selectedQueueIDs)
        }
        table.searchField = search
        table.openSelection = { [weak self] in self?.act() }
        let scroll = NSScrollView()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.loadVisibleRows(ifViewportChanged: true) }.store(in: &subscriptions)
        table.headerView?.menu = columnMenu
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        divider()
        root.addArrangedSubview(transport)
        transport.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.initialFirstResponder = table
    }

    private static let connectionItem = NSToolbarItem.Identifier("CuePlexConnection")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.connectionItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        identifier == Self.connectionItem ? plexItem : nil
    }

    private func updateConnectionButton() {
        let server = store.server
        let name = server?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let connected = server != nil
        let title = connected ? (name.isEmpty ? "Plex" : name) : "Connect to Plex…"
        let image = Self.connectionIcon(connected: connected)
        plexItem.title = Self.toolbarTitle(title)
        plexItem.label = title
        plexItem.image = image
        plexItem.toolTip = connected ? "Connected to \(title)" : title
    }

    private static func toolbarTitle(_ title: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        let maxWidth: CGFloat = 200
        guard title.size(withAttributes: attributes).width > maxWidth else { return title }
        var shortened = ""
        for character in title {
            let next = shortened + String(character)
            guard (next + "…").size(withAttributes: attributes).width <= maxWidth else { break }
            shortened = next
        }
        return shortened + "…"
    }

    private static func connectionIcon(connected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let face: CGFloat = connected ? 0.95 : 3.15
            let rear = face + 4.25
            let halfBody: CGFloat = 3.15
            let body = NSBezierPath()
            body.move(to: NSPoint(x: face, y: -halfBody))
            body.line(to: NSPoint(x: rear - 1.75, y: -halfBody))
            body.curve(to: NSPoint(x: rear, y: -halfBody + 1.75),
                       controlPoint1: NSPoint(x: rear - 0.8, y: -halfBody),
                       controlPoint2: NSPoint(x: rear, y: -halfBody + 0.8))
            body.line(to: NSPoint(x: rear, y: halfBody - 1.75))
            body.curve(to: NSPoint(x: rear - 1.75, y: halfBody),
                       controlPoint1: NSPoint(x: rear, y: halfBody - 0.8),
                       controlPoint2: NSPoint(x: rear - 0.8, y: halfBody))
            body.line(to: NSPoint(x: face, y: halfBody))
            body.move(to: NSPoint(x: face, y: -3.9))
            body.line(to: NSPoint(x: face, y: 3.9))
            for y in [-1.1, 1.1] {
                body.move(to: NSPoint(x: rear, y: y))
                body.line(to: NSPoint(x: 9.5, y: y))
            }

            let pair = NSBezierPath()
            pair.append(body)
            body.transform(using: AffineTransform(scaleByX: -1, byY: 1))
            pair.append(body)
            if !connected {
                for y in [-1.45, 1.45] {
                    pair.move(to: NSPoint(x: face, y: y))
                    pair.line(to: NSPoint(x: 0.15, y: y))
                }
            }

            var angle = AffineTransform(translationByX: rect.midX, byY: rect.midY)
            angle.rotate(byDegrees: 45)
            pair.transform(using: angle)
            pair.lineWidth = 1.3
            pair.lineCapStyle = .round
            pair.lineJoinStyle = .round
            (connected ? NSColor.systemGreen : .secondaryLabelColor).setStroke()
            pair.stroke()
            return true
        }
    }

    private func selectTab(_ tab: Int) {
        guard activeTab != tab else { return }
        if let activeTab { savedTabs[activeTab] = history + [currentLocation()] }
        activeTab = tab
        tabs.selectedSegment = tab
        history = savedTabs.removeValue(forKey: tab) ?? []
        let destination = history.popLast() ?? newLocation(for: Catalog(rawValue: tab).map(Screen.catalog) ?? .queue)
        navigate(destination)
    }
    private func currentLocation() -> Location {
        var result = location
        if !loading, table.numberOfRows > 0, let clip = table.enclosingScrollView?.contentView {
            result.position = TablePosition(firstRow: visibleRows.lowerBound, origin: clip.bounds.origin,
                                            selectedRow: table.selectedRow, queueSelection: selectedQueueIDs)
        }
        return result
    }

    private func open(_ screen: Screen) {
        history.append(currentLocation())
        navigate(newLocation(for: screen))
    }

    private func newLocation(for screen: Screen) -> Location {
        var result = Location(screen: screen)
        if let saved = preferredOrders[screen.viewKey] {
            result.order = saved
        } else if let request = screen.catalogRequest {
            result.order = .standard(for: request.kind, withinArtist: request.artist != nil)
        } else {
            if case .queue = screen { result.order = CatalogOrder(field: .position) }
            else { result.order = CatalogOrder(field: .number) }
        }
        return result
    }
    private func rebuildBreadcrumbs() {
        breadcrumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, parent) in history.enumerated() {
            let button = NSButton(title: parent.screen.heading, target: self, action: #selector(goToBreadcrumb(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = .labelColor
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = parent.screen.heading
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            breadcrumbs.addArrangedSubview(button)
            let separator = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
            separator.symbolConfiguration = .init(pointSize: 8, weight: .medium)
            separator.contentTintColor = .tertiaryLabelColor
            separator.setAccessibilityElement(false)
            breadcrumbs.addArrangedSubview(separator)
        }
        let current = NSTextField(labelWithString: location.screen.heading)
        current.font = .systemFont(ofSize: 11, weight: .medium)
        current.textColor = .labelColor
        current.lineBreakMode = .byTruncatingTail
        current.toolTip = location.screen.heading
        current.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbs.addArrangedSubview(current)
        backButton.isHidden = history.isEmpty
    }

    @objc private func goToBreadcrumb(_ sender: NSButton) {
        guard history.indices.contains(sender.tag) else { return }
        let parent = history[sender.tag]
        history.removeSubrange(sender.tag...)
        navigate(parent)
    }

    private func navigate(_ newLocation: Location) {
        let cached = previousCatalog.flatMap { saved -> CatalogRows? in
            guard saved.revision == store.revision, saved.location.screen == newLocation.screen,
                  saved.location.query == newLocation.query, saved.location.order == newLocation.order else { return nil }
            return saved.rows
        }
        if let catalogRevision, catalogRevision == store.revision, !loading, failedOffset == nil {
            previousCatalog = (location, catalogRevision, catalog)
        } else if cached != nil {
            previousCatalog = nil
        }
        loading = true
        trackIndices = .natural(count: 0, reversed: false)
        location = newLocation
        if case .queue = location.screen { table.allowsMultipleSelection = true }
        else { table.allowsMultipleSelection = false }
        preferredOrders[location.screen.viewKey] = location.order
        albumTracks = nil
        table.setAccessibilityLabel(newLocation.screen.heading)
        search.setAccessibilityLabel("Search " + newLocation.screen.heading)
        search.stringValue = location.query
        search.placeholderString = "Search " + (location.screen.columns.contains(.track) ? "tracks" : location.screen.columns[0].rawValue.lowercased() + "s")
        rebuildBreadcrumbs()
        configureColumns()
        reload(cached: cached)
    }

    private var columnKey: String { "columns." + location.screen.viewKey }
    private var columnOrderKey: String { "columnOrder." + location.screen.viewKey }

    private var orderedColumns: [CatalogOrder.Field] {
        let available = location.screen.availableColumns
        var remaining = Set(available)
        let saved = (store.defaults.stringArray(forKey: columnOrderKey) ?? [])
            .compactMap(CatalogOrder.Field.init(rawValue:))
            .filter { remaining.remove($0) != nil }
        return saved + available.filter(remaining.contains)
    }

    private var visibleColumns: [CatalogOrder.Field] {
        let order = orderedColumns
        let defaultColumns = location.screen.columns.map(\.rawValue)
        let shown = Set(store.defaults.stringArray(forKey: columnKey) ?? defaultColumns)
        let columns = order.filter { shown.contains($0.rawValue) }
        return columns.isEmpty ? order.filter { defaultColumns.contains($0.rawValue) } : columns
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        guard notification.object as? NSTableView === table else { return }
        let moved = table.tableColumns.map(\.identifier.rawValue)
        let visible = Set(moved)
        var newOrder = moved.makeIterator()
        // Keep hidden columns in their saved positions while reordering visible columns.
        let order = orderedColumns.map { field in
            let name = field.rawValue
            return visible.contains(name) ? newOrder.next() ?? name : name
        }
        store.defaults.set(order, forKey: columnOrderKey)
    }

    @objc private func showColumns(_ sender: NSButton) {
        columnMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.isFlipped ? sender.bounds.maxY : 0), in: sender)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let field = CatalogOrder.Field(rawValue: sender.title) else { return }
        var shown = visibleColumns
        if shown.contains(field) {
            guard shown.count > 1 else { return }
            shown.removeAll { $0 == field }
        } else {
            shown.append(field)
        }
        store.defaults.set(shown.map(\.rawValue), forKey: columnKey)
        configureColumns()
    }

    private func configureColumns() {
        let shown = visibleColumns
        columnMenu.removeAllItems()
        for field in location.screen.availableColumns {
            let item = columnMenu.addItem(withTitle: field.rawValue, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            let symbol: String = switch field {
            case .album: Catalog.albums.symbol
            case .track: Catalog.tracks.symbol
            case .artist, .albumArtist: Catalog.artists.symbol
            case .disc: "opticaldisc"
            case .number: "number"
            case .duration: "clock"
            case .position: "list.number"
            case .year: "calendar"
            case .recent: "calendar.badge.clock"
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.state = shown.contains(field) ? .on : .off
            item.isEnabled = shown.count > 1 || item.state == .off
        }
        columnMenu.autoenablesItems = false
        table.tableColumns.forEach(table.removeTableColumn)
        for field in shown {
            let name = field.rawValue
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            col.title = name
            col.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
            let numeric = ["Year", "No.", "Time", "Disc"].contains(name)
            col.width = numeric ? 52 : (name == "Artist" ? 175 : 225)
            col.minWidth = numeric ? 48 : 72
            col.resizingMask = numeric ? [] : [.autoresizingMask, .userResizingMask]
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        syncSortHeader()
        table.sizeToFit()
    }

    private func reload(debounce: Bool = false, cached: CatalogRows? = nil) {
        job?.cancel()
        loading = true
        pendingOffset = nil
        failedOffset = nil
        retry.isHidden = true
        catalogRevision = nil
        catalog = cached ?? CatalogRows()
        trackIndices = .natural(count: 0, reversed: false)
        displayedQueue = []
        if case .queue = location.screen { queueRevision = store.player.queueRevision }
        else { queueRevision = nil }
        table.deselectAll(nil)
        if cached != nil {
            catalogRevision = store.revision
            updateCount()
            finishReload(at: location.position)
            return
        }
        if case .queue = location.screen, location.query.isEmpty, location.order.field == .position {
            displayedQueue = store.player.queue
            trackIndices = .natural(count: displayedQueue.count, reversed: !location.order.ascending)
            updateCount()
            finishReload(at: location.position)
            return
        }
        table.reloadData()
        updateActions()
        status.stringValue = location.screen.catalogRequest?.kind == .tracks && location.order.field == .artist
            ? "Sorting tracks by artist…" : "Loading…"
        status.toolTip = nil
        let request = location
        let revision = store.revision
        job = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(200)) }
                if let catalogRequest = request.screen.catalogRequest {
                    let offset = request.position.firstRow
                    let page = try await store.catalog(catalogRequest.kind, query: request.query, offset: offset,
                                                       artist: catalogRequest.artist, order: request.order)
                    try Task.checkCancellation()
                    guard revision == store.revision else { return }
                    catalogRevision = revision
                    catalog.insert(page, at: offset, near: offset..<(offset + 1), selected: -1)
                } else if case .album(let album) = request.screen {
                    let tracks: [Track]
                    if let albumTracks { tracks = albumTracks }
                    else { tracks = try await store.tracks(for: album) }
                    try Task.checkCancellation()
                    guard revision == store.revision else { return }
                    albumTracks = tracks
                    let indices = try await request.order.sortedTrackIndices(count: tracks.count, matching: request.query,
                                                                             albumInTrackOrder: true) { (tracks[$0], album) }
                    try Task.checkCancellation()
                    guard revision == store.revision else { return }
                    trackIndices = indices
                } else {
                    let queue = store.player.queue
                    let indices = try await request.order.sortedTrackIndices(count: queue.count, matching: request.query) {
                        let entry = queue[position: $0]
                        return (entry.track, entry.album)
                    }
                    try Task.checkCancellation()
                    guard revision == store.revision else { return }
                    guard queueRevision == store.player.queueRevision else { return }
                    displayedQueue = queue
                    trackIndices = indices
                }
                window?.subtitle = store.section?.title ?? ""
                updateCount()
            } catch {
                guard !Task.isCancelled, revision == store.revision else { return }
                status.stringValue = error.localizedDescription
                status.toolTip = status.stringValue
                retry.isHidden = false
            }
            finishReload(at: request.position)
        }
    }

    private func finishReload(at position: TablePosition) {
        table.reloadData()
        restorePosition(position)
        loading = false
        loadVisibleRows()
        updateActions()
    }

    private func updateQueueBadge(_ count: Int) {
        let label = count.formatted()
        let description = count == 1 ? "1 track remaining" : "\(label) tracks remaining"
        tabs.setToolTip(description, forSegment: Self.queueTab)
        defer { tabs.invalidateIntrinsicContentSize() }
        guard count > 0 else {
            let icon = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            tabs.setImage(icon, forSegment: Self.queueTab)
            return
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 10, height: 15)
        let badge = NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.32, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7.5, yRadius: 7.5).fill()
            label.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                       withAttributes: attributes)
            return true
        }
        badge.accessibilityDescription = description
        tabs.setImage(badge, forSegment: Self.queueTab)
    }

    private func restorePosition(_ position: TablePosition) {
        if case .queue = location.screen {
            if !position.queueSelection.isEmpty {
                let selection = trackIndices.indices.filter { position.queueSelection.contains(displayedQueue[position: trackIndices[$0]].id) }
                table.selectRowIndexes(IndexSet(selection), byExtendingSelection: false)
            }
        } else if (0..<table.numberOfRows).contains(position.selectedRow) {
            table.selectRowIndexes(IndexSet(integer: position.selectedRow), byExtendingSelection: false)
        }
        guard let origin = position.origin, let scroll = table.enclosingScrollView else {
            table.scroll(.zero)
            return
        }
        scroll.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin = origin
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private var visibleRows: Range<Int> {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return 0..<0 }
        return range.location..<NSMaxRange(range)
    }

    private func loadVisibleRows(ifViewportChanged: Bool = false) {
        guard !loading, let request = location.screen.catalogRequest else { return }
        let visible = visibleRows
        if ifViewportChanged && visible == lastViewport { return }
        lastViewport = visible
        let needed = catalog.neededOffset(for: visible)
        guard needed != pendingOffset else { return }
        job?.cancel()
        pendingOffset = nil
        guard let offset = needed, offset != failedOffset else { return }
        pendingOffset = offset
        let revision = store.revision
        job = Task {
            do {
                let page = try await store.catalog(request.kind, query: location.query, offset: offset,
                                                   artist: request.artist, order: location.order)
                try Task.checkCancellation()
                guard revision == store.revision else { return }
                let oldCount = catalog.count
                catalog.insert(page, at: offset, near: visibleRows, selected: table.selectedRow)
                // Keep bounds notifications from starting another request during table updates.
                loading = true
                if oldCount != catalog.count { table.noteNumberOfRowsChanged() }
                let end = min(offset + page.rows.count, catalog.count)
                if offset < end {
                    table.reloadData(forRowIndexes: IndexSet(integersIn: offset..<end),
                                     columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
                }
                failedOffset = nil
                retry.isHidden = true
                updateCount()
                loading = false
                pendingOffset = nil
                updateActions()
                loadVisibleRows()
            } catch {
                guard !Task.isCancelled, revision == store.revision else { return }
                pendingOffset = nil
                failedOffset = offset
                status.stringValue = error.localizedDescription
                status.toolTip = status.stringValue
                retry.isHidden = false
            }
        }
    }

    private func updateCount() {
        let count = location.screen.catalogRequest == nil ? trackIndices.count : catalog.total
        if location.screen.catalogRequest != nil, store.section == nil {
            status.stringValue = "No library connected"
        } else if let count {
            status.stringValue = count == 0 ? (location.query.isEmpty ? "No items" : "No matches")
                : "\(count) " + (count == 1 ? "item" : "items")
        } else {
            status.stringValue = "\(catalog.count - 1)+ items"
        }
        status.toolTip = nil
    }

    private func row(at index: Int) -> MusicRow? {
        if location.screen.catalogRequest != nil { return catalog.cached[index] }
        guard trackIndices.indices.contains(index) else { return nil }
        let source = trackIndices[index]
        if case .album(let album) = location.screen, let albumTracks { return .track(albumTracks[source], album) }
        guard (0..<displayedQueue.count).contains(source) else { return nil }
        let entry = displayedQueue[position: source]
        return .track(entry.track, entry.album)
    }

    private func updateActions() {
        transport.canStartSelection = canStartSelection
    }

    private var canStartSelection: Bool {
        guard !loading else { return false }
        if let selected = row(at: table.selectedRow) {
            if case .artist = selected { return false }
            return true
        }
        if case .album = location.screen {
            return !trackIndices.isEmpty && albumTracks?.contains { $0.part != nil } == true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        location.screen.catalogRequest == nil ? trackIndices.count : catalog.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: column, owner: nil) as? LibraryCell ?? LibraryCell(frame: .zero)
        cell.identifier = column
        let field = cell.label
        let key = column.rawValue
        guard let kind = CatalogOrder.Field(rawValue: key) else { return nil }
        let position = trackIndices.indices.contains(index) ? trackIndices[index] : index
        let value = row(at: index)?.text(for: kind, position: position)
            ?? (column == table.tableColumns.first?.identifier ? "Loading…" : "")
        let numeric = key == "Time" || key == "Year" || key == "No." || kind == .disc || kind == .position
        let isCurrent = (0..<displayedQueue.count).contains(position) && displayedQueue[position: position].id == store.player.current?.id
        let weight: NSFont.Weight = isCurrent ? .bold : .regular
        field.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: weight) : .systemFont(ofSize: 12, weight: weight)
        field.textColor = numeric ? .secondaryLabelColor : .labelColor
        field.stringValue = value
        return cell
    }
    private var selectedQueueIDs: Set<UUID> {
        guard case .queue = location.screen else { return [] }
        return Set(table.selectedRowIndexes.compactMap { row in
            trackIndices.indices.contains(row) ? displayedQueue[position: trackIndices[row]].id : nil
        })
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .queue = location.screen, trackIndices.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(displayedQueue[position: trackIndices[row]].id.uuidString, forType: Self.queueDragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard case .queue = location.screen, !loading, info.draggingSource as? NSTableView === table,
              (0...trackIndices.count).contains(row) else { return [] }
        table.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard info.draggingSource as? NSTableView === table, dropOperation == .above else { return false }
        let ids = info.draggingPasteboard.pasteboardItems?.compactMap {
            $0.string(forType: Self.queueDragType).flatMap(UUID.init(uuidString:))
        } ?? []
        return moveQueueSelection(Set(ids), above: row)
    }

    func moveQueueSelection(_ selection: Set<UUID>, above row: Int) -> Bool {
        guard case .queue = location.screen, !loading, !selection.isEmpty,
              queueRevision == store.player.queueRevision, (0...trackIndices.count).contains(row) else { return false }
        let ordered = trackIndices.compactMap { index in
            let id = displayedQueue[position: index].id
            return selection.contains(id) ? id : nil
        }
        guard ordered.count == selection.count, let last = trackIndices.last else { return false }
        let boundary = row < trackIndices.count ? trackIndices[row] : last + 1
        location = currentLocation()
        location.position.queueSelection = selection
        location.order = CatalogOrder(field: .position)
        preferredOrders[location.screen.viewKey] = location.order
        syncSortHeader()
        store.player.moveQueuedEntries(ordered, to: boundary)
        reload()
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.query != query else { return }
        location.query = query
        location.position = TablePosition()
        reload(debounce: location.screen.catalogRequest != nil)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        window?.makeFirstResponder(table)
        if numberOfRows(in: table) > 0 { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return true
    }
    @objc private func changeTab() { selectTab(tabs.selectedSegment) }
    @objc func back() { if let last = history.popLast() { navigate(last) } }
    @objc private func retryLoading() {
        if failedOffset != nil {
            failedOffset = nil
            retry.isHidden = true
            updateCount()
            loadVisibleRows()
        } else {
            reload()
        }
    }
    private func syncSortHeader() {
        let order = location.order
        if table.tableColumns.contains(where: { $0.title == order.field.rawValue }) {
            table.sortDescriptors = [NSSortDescriptor(key: order.field.rawValue, ascending: order.ascending)]
        } else {
            table.sortDescriptors = []
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
              let field = CatalogOrder.Field(rawValue: key) else { return }
        applyOrder(CatalogOrder(field: field, ascending: descriptor.ascending))
    }

    private func applyOrder(_ order: CatalogOrder) {
        guard location.order != order, location.screen.availableColumns.contains(order.field) else { return }
        location.order = order
        preferredOrders[location.screen.viewKey] = order
        location.position = TablePosition()
        syncSortHeader()
        reload()
    }

    @objc func setOrder(_ sender: NSMenuItem) {
        guard location.screen.catalogRequest?.kind == .albums, let key = sender.representedObject as? String,
              let field = CatalogOrder.Field(rawValue: key) else { return }
        applyOrder(CatalogOrder(field: field, ascending: field != .recent))
    }
    @objc func refresh() {
        location = currentLocation()
        albumTracks = nil
        previousCatalog = nil
        store.invalidateTrackArtistIndex()
        reload()
    }
    @objc func find() { window?.makeFirstResponder(search); search.selectText(nil) }
    @objc func connect() {
        if window?.isVisible != true || window?.isMiniaturized == true {
            window?.deminiaturize(nil)
            showWindow(nil)
        }
        store.showConnection = true
    }
    @objc func toggle() {
        if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
        if store.player.current != nil {
            store.player.toggle()
        } else if canStartSelection {
            if case .album(let album) = row(at: table.selectedRow) {
                store.enqueue(.album(album), action: .replace)
            } else {
                act()
            }
        }
    }
    @objc func nextTrack() { store.player.next() }
    @objc func previousTrack() { store.player.previous() }
    private lazy var equalizerPanel = EqualizerPanel(equalizer: store.player.equalizer)
    @objc func showEqualizer() { equalizerPanel.showWindow(nil) }

    @objc func audioOutput() { if let window { transport.showOutputPicker(in: window) } }
    @objc func copyAirPlayDiagnostics() {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(store.player.airPlayDiagnostics.report, forType: .string)
    }
    @objc func clearQueue() { store.clearQueue() }

    private enum RowCommand: Int, CaseIterable {
        case append, replace, album, artistAlbums, artistTracks

        var title: String {
            switch self {
            case .append: "Append to Queue"
            case .replace: "Replace Queue"
            case .album: "Go to Album"
            case .artistAlbums: "Go to Artist’s Albums"
            case .artistTracks: "Go to Artist’s Tracks"
            }
        }

        var symbol: String {
            switch self {
            case .append: "text.badge.plus"
            case .replace: "arrow.triangle.2.circlepath"
            case .album: Catalog.albums.symbol
            case .artistAlbums: Catalog.artists.symbol
            case .artistTracks: Catalog.tracks.symbol
            }
        }

        func destination(for row: MusicRow) -> (title: String, screen: Screen)? {
            switch (self, row) {
            case (.album, .track(_, let album)) where !album.id.isEmpty:
                return ("Go to \(album.title)", .album(album))
            case (.artistAlbums, .album(let album)):
                return ("See all albums by \(album.artist)", .artist(id: album.artistID, name: album.artist))
            case (.artistAlbums, .track(let track, let album)):
                let id = track.artist == album.artist ? album.artistID : nil
                return ("Go to \(track.artist)", .artist(id: id, name: track.artist))
            case (.artistTracks, .artist(let id, let name, _)):
                return ("See all tracks by \(name)", .artistTracks(id: id, name: name))
            default: return nil
            }
        }
    }

    func addSelectionCommands(to menu: NSMenu) {
        for command in RowCommand.allCases {
            if command == .album { menu.addItem(.separator()) }
            add(command, title: command.title, to: menu, selection: nil)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Queue", action: #selector(removeFromQueue), keyEquivalent: "").target = self
    }

    private func add(_ command: RowCommand, title: String, to menu: NSMenu, selection: RowMenuSelection?) {
        let item = menu.addItem(withTitle: title, action: #selector(performRowCommand(_:)), keyEquivalent: "")
        item.target = self
        item.tag = command.rawValue
        item.representedObject = selection
        if let selection {
            // A discography link from an album uses the Albums tab symbol.
            let symbol = if case .album = selection.row, command == .artistAlbums { Catalog.albums.symbol } else { command.symbol }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    private func rowMenu(at index: Int) -> NSMenu? {
        guard !loading, let row = row(at: index) else { return nil }
        let selection = RowMenuSelection(row: row, albumTracks: albumTracks, revision: store.revision)
        let menu = NSMenu()
        if location.screen != .queue {
            for command in [RowCommand.append, .replace] {
                add(command, title: command.title, to: menu, selection: selection)
            }
            menu.addItem(.separator())
        }
        for command in [RowCommand.album, .artistAlbums, .artistTracks] {
            if let destination = command.destination(for: row) {
                add(command, title: destination.title, to: menu, selection: selection)
            }
        }
        return menu
    }

    private func commandSelection(_ item: NSMenuItem) -> RowMenuSelection? {
        if let selection = item.representedObject as? RowMenuSelection {
            return selection.revision == store.revision ? selection : nil
        }
        guard window?.isKeyWindow == true, !loading, table.numberOfSelectedRows == 1,
              let row = row(at: table.selectedRow) else { return nil }
        return RowMenuSelection(row: row, albumTracks: albumTracks, revision: store.revision)
    }

    @objc private func performRowCommand(_ item: NSMenuItem) {
        guard let selection = commandSelection(item), let command = RowCommand(rawValue: item.tag) else { return }
        switch command {
        case .append, .replace:
            store.enqueue(selection.row, action: command == .append ? .append : .replace, albumTracks: selection.albumTracks)
        default:
            if let screen = command.destination(for: selection.row)?.screen, screen != location.screen || !location.query.isEmpty {
                open(screen)
            }
        }
    }

    @objc private func removeFromQueue() {
        guard !loading, case .queue = location.screen else { return }
        store.player.removeQueuedEntries(selectedQueueIDs)
    }

    @objc func selectLibraryTab(_ sender: NSMenuItem) { selectTab(sender.tag) }

    @objc private func doubleClick() {
        if table.clickedRow >= 0 { act(at: table.clickedRow) }
    }
    private func act() { act(at: table.selectedRow) }
    private func act(at index: Int) {
        guard !loading else { return }
        if case .album(let album) = location.screen, index < 0,
           let tracks = albumTracks, tracks.contains(where: { $0.part != nil }) {
            store.enqueue(.album(album), action: .replace, albumTracks: tracks)
            return
        }
        guard let selected = row(at: index) else { return }
        switch selected {
        case .artist(let id, let name, _): open(.artist(id: id, name: name))
        case .album(let album): open(.album(album))
        case .track:
            if case .queue = location.screen {
                let id = displayedQueue[position: trackIndices[index]].id
                store.selectQueuedTrack(id)
            } else {
                store.enqueue(selected, action: .replace, albumTracks: albumTracks)
            }
        }
    }

    private func presentConnection(_ show: Bool) {
        guard let window else { return }
        if show, connection == nil {
            let sheet = NSWindow(contentViewController: ConnectionView(store: store))
            sheet.title = "Plex Connection"
            sheet.styleMask = [.titled]
            connection = sheet
            window.beginSheet(sheet)
        } else if !show, let connection {
            window.endSheet(connection)
            self.connection = nil
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performRowCommand(_:)):
            guard let command = RowCommand(rawValue: menuItem.tag), let selection = commandSelection(menuItem) else { return false }
            if command == .append || command == .replace { return location.screen != .queue }
            return command.destination(for: selection.row) != nil
        case #selector(removeFromQueue):
            return window?.isKeyWindow == true && location.screen == .queue && !loading && table.numberOfSelectedRows > 0
        case #selector(selectLibraryTab(_:)):
            menuItem.state = activeTab == menuItem.tag ? .on : .off
            return window?.isKeyWindow == true
        case #selector(setOrder(_:)):
            menuItem.state = (menuItem.representedObject as? String) == location.order.field.rawValue ? .on : .off
            return location.screen.catalogRequest?.kind == .albums
        case #selector(back): return !history.isEmpty
        case #selector(toggle): return (store.player.current != nil || canStartSelection) && window?.attachedSheet == nil
        case #selector(nextTrack): return store.player.hasNext && !(NSApp.keyWindow?.firstResponder is NSText)
        case #selector(previousTrack): return store.player.current != nil && !(NSApp.keyWindow?.firstResponder is NSText)
        case #selector(clearQueue): return store.canClearQueue
        default: return true
        }
    }
}
