import AppKit
import Combine

private enum Screen {
    case catalog(Catalog), artist(id: String, name: String), album(Album), queue

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
        case .catalog(.tracks), .queue: ["Track", "Artist", "Album", "Time"]
        }
    }
}

private struct Location {
    var screen: Screen
    var query = ""
    var offset = 0
    var previousOffsets: [Int] = []
}

private final class MusicTable: NSTableView {
    var openSelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    private let store: LibraryStore
    private let table = MusicTable()
    private let tabs = NSSegmentedControl(labels: Catalog.allCases.map(\.title) + ["Queue"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let heading = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let earlier = NSButton()
    private let later = NSButton()
    private let primary = NSButton()
    private let retry = NSButton()
    private let plex = NSButton()
    private var connection: NSWindow?
    private var location = Location(screen: .catalog(.albums))
    private var order = AlbumOrder.title
    private var history: [Location] = []
    private var rows: [MusicRow] = []
    private var albumTracks: [Track]?
    private var queueIndices: [Int] = []
    private var loading = false
    private var nextOffset: Int?
    private var job: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(store: LibraryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Minimal Player"
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
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(primary, "Open Album", #selector(act))
        _ = bar([backButton, heading, NSView(), primary])
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
        table.openSelection = { [weak self] in self?.act() }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(earlier, "Previous Page", #selector(previousPage))
        configure(later, "Next Page", #selector(nextPage))
        configure(retry, "Retry", #selector(refresh))
        _ = bar([status, retry, NSView(), earlier, later])
        let divider = NSBox()
        divider.boxType = .separator
        root.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let transport = Transport(player: store.player)
        root.addArrangedSubview(transport)
        transport.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        window.initialFirstResponder = table
    }

    private func selectTab(_ tab: Int) {
        tabs.selectedSegment = tab
        history = []
        navigate(Location(screen: Catalog(rawValue: tab).map(Screen.catalog) ?? .queue))
    }
    private func open(_ screen: Screen) {
        history.append(location)
        navigate(Location(screen: screen))
    }
    private func navigate(_ newLocation: Location) {
        location = newLocation
        albumTracks = nil
        search.stringValue = location.query
        search.placeholderString = "Search " + (location.screen.columns.contains("Track") ? "tracks" : location.screen.columns[0].lowercased() + "s")
        if case .catalog = location.screen { heading.stringValue = store.section?.title ?? "Sample library" }
        else { heading.stringValue = location.screen.heading }
        heading.toolTip = heading.stringValue
        backButton.isHidden = history.isEmpty
        table.tableColumns.forEach(table.removeTableColumn)
        for name in location.screen.columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            col.title = name
            let numeric = ["Year", "No.", "Time"].contains(name)
            col.width = numeric ? 52 : (name == "Artist" ? 175 : 225)
            col.minWidth = numeric ? 48 : 72
            col.resizingMask = numeric ? [] : [.autoresizingMask, .userResizingMask]
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.sizeToFit()
        reload()
    }

    private func reload(debounce: Bool = false) {
        job?.cancel()
        if !debounce {
            rows = []
            queueIndices = []
            table.reloadData()
        }
        if !loading || !debounce {
            loading = true
            nextOffset = nil
            retry.isHidden = true
            table.deselectAll(nil)
            updateActions()
            status.stringValue = "Loading…"
        }
        let request = location
        let revision = store.revision
        job = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(200)) }
                let page: CatalogPage
                var positions: [Int] = []
                switch request.screen {
                case .catalog(let kind):
                    page = try await store.catalog(kind, query: request.query, offset: request.offset, artistID: nil, order: order)
                case .artist(let id, _):
                    page = try await store.catalog(.albums, query: request.query, offset: request.offset, artistID: id, order: order)
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
                rows = page.rows
                nextOffset = page.next
                plex.title = store.server == nil ? "Connect to Plex…" : "Plex Connection…"
                let count: String
                if rows.isEmpty {
                    count = request.query.isEmpty ? "No items" : "No matches"
                } else if request.offset > 0 || page.next != nil {
                    count = "\(request.offset + 1)–\(request.offset + rows.count)" + (page.total.map { " of \($0)" } ?? "")
                } else {
                    count = "\(rows.count) " + (rows.count == 1 ? "item" : "items")
                }
                status.stringValue = count
                status.toolTip = nil
            } catch {
                guard !Task.isCancelled, revision == store.revision else { return }
                rows = []
                queueIndices = []
                status.stringValue = error.localizedDescription
                status.toolTip = status.stringValue
                retry.isHidden = false
            }
            loading = false
            table.deselectAll(nil)
            table.reloadData()
            table.scroll(.zero)
            updateActions()
        }
    }

    private func updateActions() {
        earlier.isHidden = location.previousOffsets.isEmpty && nextOffset == nil
        later.isHidden = earlier.isHidden
        earlier.isEnabled = !location.previousOffsets.isEmpty
        later.isEnabled = nextOffset != nil
        switch location.screen {
        case .catalog(.artists): primary.title = "Open Artist"
        case .artist, .catalog(.albums): primary.title = "Open Album"
        case .album: primary.title = table.selectedRow < 0 ? "Play Album" : "Play Track"
        default: primary.title = "Play Track"
        }
        primary.isEnabled = !loading && (rows.indices.contains(table.selectedRow) || (primary.title == "Play Album" && !rows.isEmpty))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard rows.indices.contains(index), let column = tableColumn?.identifier else { return nil }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: column, owner: nil) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = column
            field.lineBreakMode = .byTruncatingTail
            field.allowsExpansionToolTips = true
        }
        let key = column.rawValue
        let value: String
        switch rows[index] {
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
            case "No.": value = track.disc > 1 ? "\(track.disc).\(track.number)" : String(track.number)
            default: value = track.title
            }
        }
        let current = queueIndices.indices.contains(index) && queueIndices[index] == store.player.index
        field.font = .systemFont(ofSize: 12, weight: current ? .semibold : .regular)
        field.stringValue = value
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard location.query != query else { return }
        location.query = query
        location.offset = 0
        location.previousOffsets = []
        reload(debounce: true)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        window?.makeFirstResponder(table)
        if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        return true
    }
    @objc private func changeTab() { selectTab(tabs.selectedSegment) }
    @objc func back() { if let last = history.popLast() { navigate(last) } }
    @objc private func previousPage() {
        guard let previous = location.previousOffsets.popLast() else { return }
        location.offset = previous
        reload()
    }
    @objc private func nextPage() {
        guard let nextOffset else { return }
        location.previousOffsets.append(location.offset)
        location.offset = nextOffset
        reload()
    }
    @objc func setOrder(_ sender: NSMenuItem) {
        guard let selected = AlbumOrder(rawValue: sender.tag) else { return }
        order = selected
        location.previousOffsets = []
        location.offset = 0
        reload()
    }
    @objc func refresh() { albumTracks = nil; reload() }
    @objc func find() { window?.makeFirstResponder(search); search.selectText(nil) }
    @objc func connect() { store.showConnection = true }
    @objc func toggle() { store.player.toggle() }
    @objc func nextTrack() { store.player.next() }
    @objc func previousTrack() { store.player.previous() }
    @objc func audioOutput() { if let window { showOutputPicker(for: store.player, in: window) } }
    @objc func clearQueue() { store.clearQueue() }
    @objc private func doubleClick() { if table.clickedRow >= 0 { act() } }
    @objc private func act() {
        guard !loading else { return }
        let index = table.selectedRow
        if case .album(let album) = location.screen, index < 0,
           let tracks = albumTracks, let first = tracks.first(where: { $0.localFile != nil || $0.part != nil }) {
            store.play(tracks, from: first.id, album: album)
            return
        }
        guard rows.indices.contains(index) else { return }
        switch rows[index] {
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
            menuItem.state = menuItem.tag == order.rawValue ? .on : .off
            switch location.screen {
            case .artist, .catalog(.albums): return true
            default: return false
            }
        case #selector(back): return !history.isEmpty
        case #selector(toggle): return store.player.current != nil && window?.firstResponder is NSTextView == false
        case #selector(nextTrack): return store.player.hasNext
        case #selector(previousTrack), #selector(clearQueue): return store.player.current != nil
        default: return true
        }
    }
}
