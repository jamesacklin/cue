import AppKit
import Combine

private enum Screen {
    case catalog(Catalog), artist(id: String, name: String), album(Album), queue

    var catalogRequest: (kind: Catalog, artistID: String?)? {
        switch self {
        case .catalog(let kind): return (kind, nil)
        case .artist(let id, _): return (.albums, id)
        default: return nil
        }
    }

    var heading: String {
        switch self {
        case .catalog(let kind): kind.title
        case .artist(_, let name): name
        case .album(let album): album.title
        case .queue: "Queue"
        }
    }
    var columns: [String] {
        switch self {
        case .catalog(.artists): ["Artist"]
        case .artist, .catalog(.albums): ["Album", "Artist", "Year"]
        case .album: ["No.", "Track", "Artist", "Time"]
        case .catalog(.tracks): ["No.", "Track", "Artist", "Album", "Time"]
        case .queue: ["Track", "Artist", "Album", "Time"]
        }
    }
}

private struct Location {
    var screen: Screen
    var query = ""
    var firstVisibleRow = 0
    var order = CatalogOrder(field: .album)
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

private final class MusicTable: NSTableView {
    var openSelection: (() -> Void)?
    weak var searchField: NSSearchField?

    override func keyDown(with event: NSEvent) {
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
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let store: LibraryStore
    private let table = MusicTable()
    private let tabs = NSSegmentedControl(labels: Catalog.allCases.map(\.title) + ["Queue"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let breadcrumbs = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private lazy var transport = Transport(player: store.player, target: self, action: #selector(toggle))
    private let retry = NSButton()
    private let plex = NSButton()
    private var connection: NSWindow?
    private var location = Location(screen: .catalog(.albums))
    private var preferredOrders: [Catalog: CatalogOrder] = [:]
    private var history: [Location] = []
    private var rows: [MusicRow] = []
    private var albumTracks: [Track]?
    private var queueIndices: [Int] = []
    private var loading = false
    private var catalog = CatalogRows()
    private var pendingOffset: Int?
    private var failedOffset: Int?
    private var job: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(store: LibraryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Cue"
        window.contentMinSize = NSSize(width: 610, height: 300)
        window.center()
        build(window)
        store.player.setProgressVisible(window.occlusionState.contains(.visible))
        NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification, object: window)
            .sink { [weak window, weak player = store.player] _ in
                player?.setProgressVisible(window?.occlusionState.contains(.visible) == true)
            }.store(in: &subscriptions)
        store.$revision.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.selectTab(0)
        }.store(in: &subscriptions)
        store.$showConnection.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] show in
            self?.presentConnection(show)
        }.store(in: &subscriptions)
        store.player.$queue.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            if case .queue = self?.location.screen { self?.reload() }
        }.store(in: &subscriptions)
        store.player.$index.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            if case .queue = self?.location.screen { self?.table.reloadData() }
        }.store(in: &subscriptions)
        selectTab(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        window.contentView = root
        func bar(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.spacing = 8
            stack.edgeInsets = .init(top: 7, left: 12, bottom: 7, right: 12)
            root.addArrangedSubview(stack)
            stack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            return stack
        }
        func configure(_ button: NSButton, _ title: String, _ action: Selector) {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
        }
        tabs.target = self
        tabs.action = #selector(changeTab)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.widthAnchor.constraint(equalToConstant: 185).isActive = true
        configure(plex, "Connect to Plex…", #selector(connect))
        _ = bar([tabs, NSView(), search, plex])
        configure(backButton, "Back", #selector(back))
        breadcrumbs.spacing = 5
        breadcrumbs.detachesHiddenViews = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(retry, "Retry", #selector(retryLoading))
        _ = bar([backButton, breadcrumbs, NSView(), status, retry])
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClick)
        table.searchField = search
        table.openSelection = { [weak self] in self?.act() }
        let scroll = NSScrollView()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scroll.contentView)
            .sink { [weak self] _ in self?.loadVisibleRows() }.store(in: &subscriptions)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.addArrangedSubview(transport)
        transport.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.initialFirstResponder = table
    }

    private func selectTab(_ tab: Int) {
        tabs.selectedSegment = tab
        history = []
        navigate(newLocation(for: Catalog(rawValue: tab).map(Screen.catalog) ?? .queue))
    }
    private func open(_ screen: Screen) {
        location.firstVisibleRow = visibleRows.lowerBound
        history.append(location)
        navigate(newLocation(for: screen))
    }

    private func newLocation(for screen: Screen) -> Location {
        var result = Location(screen: screen)
        if let kind = screen.catalogRequest?.kind {
            result.order = preferredOrders[kind] ?? .standard(for: kind)
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
            button.contentTintColor = .linkColor
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
        location = newLocation
        if let kind = location.screen.catalogRequest?.kind {
            preferredOrders[kind] = location.order
        }
        albumTracks = nil
        search.stringValue = location.query
        search.placeholderString = "Search " + (location.screen.columns.contains("Track") ? "tracks" : location.screen.columns[0].lowercased() + "s")
        rebuildBreadcrumbs()
        table.tableColumns.forEach(table.removeTableColumn)
        for name in location.screen.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            col.title = name
            if name == "Artist", location.screen.catalogRequest?.kind == .tracks {
                col.headerToolTip = "Sort by Plex album artist"
            }
            if sortable(name) {
                col.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
            }
            let numeric = ["Year", "No.", "Time"].contains(name)
            col.width = numeric ? 52 : (name == "Artist" ? 175 : 225)
            col.minWidth = numeric ? 48 : 72
            col.resizingMask = numeric ? [] : [.autoresizingMask, .userResizingMask]
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        syncSortHeader()
        table.sizeToFit()
        reload()
    }

    private func reload(debounce: Bool = false) {
        job?.cancel()
        loading = true
        pendingOffset = nil
        failedOffset = nil
        retry.isHidden = true
        catalog = CatalogRows()
        rows = []
        queueIndices = []
        table.deselectAll(nil)
        table.reloadData()
        updateActions()
        status.stringValue = "Loading…"
        status.toolTip = nil
        let request = location
        let revision = store.revision
        job = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(200)) }
                let page: CatalogPage
                var positions: [Int] = []
                switch request.screen {
                case .catalog(let kind):
                    page = try await store.catalog(kind, query: request.query, offset: request.firstVisibleRow, artistID: nil, order: request.order)
                case .artist(let id, _):
                    page = try await store.catalog(.albums, query: request.query, offset: request.firstVisibleRow, artistID: id, order: request.order)
                case .album(let album):
                    let tracks: [Track]
                    if let albumTracks { tracks = albumTracks }
                    else { tracks = try await store.tracks(for: album) }
                    try Task.checkCancellation()
                    albumTracks = tracks
                    let visible = tracks.compactMap { track -> MusicRow? in
                        let row = MusicRow.track(track, album)
                        return row.matches(request.query) ? row : nil
                    }
                    page = CatalogPage(rows: visible, total: visible.count, next: nil)
                case .queue:
                    var visible: [MusicRow] = []
                    for (index, entry) in store.player.queue.enumerated() {
                        let row = MusicRow.track(entry.track, entry.album)
                        if row.matches(request.query) { visible.append(row); positions.append(index) }
                    }
                    page = CatalogPage(rows: visible, total: visible.count, next: nil)
                }
                try Task.checkCancellation()
                guard revision == store.revision else { return }
                queueIndices = positions
                if request.screen.catalogRequest != nil {
                    let offset = request.firstVisibleRow
                    catalog.insert(page, at: offset, near: offset..<(offset + 1), selected: -1)
                } else {
                    rows = page.rows
                }
                plex.title = store.server == nil ? "Connect to Plex…" : "Plex Connection…"
                updateCount()
            } catch {
                guard !Task.isCancelled, revision == store.revision else { return }
                rows = []
                queueIndices = []
                status.stringValue = error.localizedDescription
                status.toolTip = status.stringValue
                retry.isHidden = false
            }
            table.reloadData()
            let anchor = min(request.firstVisibleRow, numberOfRows(in: table) - 1)
            table.scroll(anchor > 0 ? table.rect(ofRow: anchor).origin : .zero)
            loading = false
            loadVisibleRows()
            updateActions()
        }
    }

    private var visibleRows: Range<Int> {
        let range = table.rows(in: table.visibleRect)
        guard range.length > 0 else { return 0..<0 }
        return range.location..<NSMaxRange(range)
    }

    private func loadVisibleRows() {
        guard !loading, let request = location.screen.catalogRequest else { return }
        let visible = visibleRows
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
                                                   artistID: request.artistID, order: location.order)
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
        let count = location.screen.catalogRequest == nil ? rows.count : catalog.total
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
        return rows.indices.contains(index) ? rows[index] : nil
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
            return !rows.isEmpty && albumTracks?.contains { $0.part != nil } == true
        }
        return false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        location.screen.catalogRequest == nil ? rows.count : catalog.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let column = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: column, owner: nil) as? LibraryCell ?? LibraryCell(frame: .zero)
        cell.identifier = column
        let field = cell.label
        let key = column.rawValue
        let value: String
        switch row(at: index) {
        case nil: value = column == table.tableColumns.first?.identifier ? "Loading…" : ""
        case .album(let album):
            switch key {
            case "Album": value = album.title
            case "Year": value = album.year.map(String.init) ?? ""
            default: value = album.artist
            }
        case .artist(_, let name): value = name
        case .track(let track, let album):
            switch key {
            case "Artist": value = track.artist
            case "Album": value = album.title
            case "Time": value = timeLabel(track.duration)
            case "No.": value = track.number <= 0 ? "" : (track.disc > 1 ? "\(track.disc).\(track.number)" : String(track.number))
            default: value = track.title
            }
        }
        let current = queueIndices.indices.contains(index) && queueIndices[index] == store.player.index
        field.font = .systemFont(ofSize: 12, weight: current ? .semibold : .regular)
        field.stringValue = value
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.query != query else { return }
        location.query = query
        location.firstVisibleRow = 0
        reload(debounce: true)
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
    private func sortable(_ column: String) -> Bool {
        switch location.screen.catalogRequest?.kind {
        case .albums: return column == "Album" || column == "Artist" || column == "Year"
        case .tracks: return column == "Album" || column == "Artist" || column == "Track"
        default: return false
        }
    }

    private func syncSortHeader() {
        let order = location.order
        if sortable(order.field.rawValue) {
            table.sortDescriptors = [NSSortDescriptor(key: order.field.rawValue, ascending: order.ascending)]
        } else {
            table.sortDescriptors = []
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, sortable(key),
              let field = CatalogOrder.Field(rawValue: key) else { return }
        applyOrder(CatalogOrder(field: field, ascending: descriptor.ascending))
    }

    private func applyOrder(_ order: CatalogOrder) {
        guard let kind = location.screen.catalogRequest?.kind, location.order != order else { return }
        location.order = order
        preferredOrders[kind] = order
        location.firstVisibleRow = 0
        syncSortHeader()
        reload()
    }

    @objc func setOrder(_ sender: NSMenuItem) {
        guard location.screen.catalogRequest?.kind == .albums, let key = sender.representedObject as? String,
              let field = CatalogOrder.Field(rawValue: key) else { return }
        applyOrder(CatalogOrder(field: field, ascending: field != .recent))
    }
    @objc func refresh() { albumTracks = nil; reload() }
    @objc func find() { window?.makeFirstResponder(search); search.selectText(nil) }
    @objc func connect() { store.showConnection = true }
    @objc func toggle() {
        if store.player.current != nil {
            store.player.toggle()
        } else if canStartSelection {
            if case .album(let album) = row(at: table.selectedRow) {
                store.playAlbum(album)
            } else {
                act()
            }
        }
    }
    @objc func nextTrack() { store.player.next() }
    @objc func previousTrack() { store.player.previous() }
    @objc func audioOutput() { if let window { showOutputPicker(for: store.player, in: window) } }
    @objc func clearQueue() { store.clearQueue() }
    @objc private func doubleClick() { if table.clickedRow >= 0 { act() } }
    @objc private func act() {
        guard !loading else { return }
        let index = table.selectedRow
        if case .album(let album) = location.screen, index < 0,
           let tracks = albumTracks, let first = tracks.first(where: { $0.part != nil }) {
            store.play(tracks, from: first.id, album: album)
            return
        }
        guard let selected = row(at: index) else { return }
        switch selected {
        case .artist(let id, let name): open(.artist(id: id, name: name))
        case .album(let album): open(.album(album))
        case .track(let track, let album):
            if case .queue = location.screen { store.selectQueuedTrack(queueIndices[index]) }
            else if let albumTracks { store.play(albumTracks, from: track.id, album: album) }
            else if !album.id.isEmpty { store.playAlbum(album, startingAt: track.id) }
            else { store.play([track], from: track.id, album: album) }
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
        case #selector(setOrder(_:)):
            menuItem.state = (menuItem.representedObject as? String) == location.order.field.rawValue ? .on : .off
            switch location.screen {
            case .artist, .catalog(.albums): return true
            default: return false
            }
        case #selector(back): return !history.isEmpty
        case #selector(toggle): return (store.player.current != nil || canStartSelection) && !(window?.firstResponder is NSTextView)
        case #selector(nextTrack): return store.player.hasNext
        case #selector(previousTrack), #selector(clearQueue): return store.player.current != nil
        default: return true
        }
    }
}
