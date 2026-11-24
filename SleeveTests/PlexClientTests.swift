import AppKit
import XCTest
@testable import Sleeve

private final class FixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var status = 200
        let json: Any
        var rawBody: Data?
        switch url.path {
        case "/api/v2/pins":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(value("strong"), "true")
            json = ["id": 8, "code": "sample-pin", "expiresIn": 5]
        case "/api/v2/pins/8":
            XCTAssertEqual(value("code"), "sample-pin")
            json = ["id": 8, "code": "sample-pin", "authToken": "fixture-account"]
        case "/api/v2/resources":
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "fixture-account")
            json = [
                ["name": "Stereo", "clientIdentifier": "server", "provides": "server",
                 "accessToken": "fixture-server", "connections": [
                    ["uri": "https://remote.example", "local": false],
                    ["uri": "https://relay.example", "local": false, "relay": true],
                    ["uri": "https://local.example", "local": true]
                 ]],
                ["name": "Player", "clientIdentifier": "player", "provides": "player"]
            ]
        case "/library/sections":
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "fixture-server")
            if url.host == "local.example" {
                status = 503
                json = [:]
            } else {
                json = ["MediaContainer": ["Directory": [
                    ["title": "Records", "key": "4", "type": "artist"],
                    ["title": "Films", "key": "1", "type": "movie"]
                ]]]
            }
        case "/library/sections/4/all":
            if value("album.title") == "large" {
                let start = Int(value("X-Plex-Container-Start")!)!
                let total = 100_003
                let reverse = value("sort") == "album.titleSort:desc"
                let rows = (start..<min(start + CatalogPage.capacity, total)).map { index in
                    let id = reverse ? total - 1 - index : index
                    return ["ratingKey": String(id), "title": "Large album \(id)"]
                }
                json = ["MediaContainer": ["totalSize": total, "offset": start, "Metadata": rows]]
                break
            }
            if value("type") == "9", value("sort") != "album.titleSort" {
                let sort = value("sort") ?? ""
                let rows: [[String: Any]] = [
                    ["ratingKey": "1", "title": "First", "parentTitle": "Zulu", "year": 2001],
                    ["ratingKey": "2", "title": "Second", "parentTitle": "Able", "year": 1995]
                ]
                let ordered: [[String: Any]]
                switch sort {
                case "album.year,album.titleSort,album.id", "album.year:desc,album.titleSort,album.id":
                    XCTAssertEqual(value("artist.id"), "44")
                    ordered = sort.hasPrefix("album.year:desc") ? rows : Array(rows.reversed())
                case "artist.titleSort,album.titleSort", "album.titleSort:desc": ordered = Array(rows.reversed())
                case "artist.titleSort:desc,album.titleSort": ordered = rows
                default: XCTFail("Unexpected album order: \(sort)"); ordered = rows
                }
                json = ["MediaContainer": ["totalSize": 2, "Metadata": ordered]]
                break
            }
            if value("type") == "8" {
                json = ["MediaContainer": ["totalSize": 1, "Metadata": [["ratingKey": "44", "title": "The Band"]]]]
                break
            }
            if value("type") == "10", value("track.title") == nil {
                let sort = value("sort") ?? ""
                let rows = [
                    ["ratingKey": "31", "index": 3, "parentIndex": 2, "title": "Echo", "parentTitle": "Amber",
                     "grandparentTitle": "Zulu"],
                    ["ratingKey": "32", "index": 1, "title": "Brass", "parentTitle": "Zinc", "grandparentTitle": "Able"]
                ]
                let firstIsEcho: Bool
                switch sort {
                case "titleSort", "album.titleSort:desc,album.id,track.absoluteIndex,track.index",
                     "artist.titleSort,album.titleSort,album.id,track.absoluteIndex,track.index": firstIsEcho = false
                case "album.titleSort,album.id,track.absoluteIndex,track.index",
                     "artist.titleSort:desc,album.titleSort,album.id,track.absoluteIndex,track.index": firstIsEcho = true
                default: XCTFail("Unexpected track order: \(sort)"); firstIsEcho = false
                }
                json = ["MediaContainer": ["totalSize": 2, "Metadata": firstIsEcho ? rows : Array(rows.reversed())]]
                break
            }
            if value("type") == "10" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Pms-Api-Version"), "1.0")
                let fields = Set((value("includeFields") ?? "").components(separatedBy: ","))
                XCTAssertTrue(Set(["ratingKey", "parentRatingKey", "size", "offset", "totalSize", "key"]).isSubset(of: fields))
                XCTAssertEqual(value("includeElements"), "Metadata,Media,Part")
                XCTAssertTrue(url.absoluteString.contains("%2B"))
                XCTAssertEqual(value("track.title"), "Blue + Gold & Silver")
                XCTAssertEqual(value("artist.title"), "Blue + Gold & Silver")
                XCTAssertEqual(value("album.title"), "Blue + Gold & Silver")
                XCTAssertEqual(value("X-Plex-Container-Start"), "0")
                json = ["MediaContainer": ["Metadata": [
                    ["ratingKey": 9, "title": "Gold", "parentRatingKey": 4, "parentTitle": "Blue", "grandparentTitle": "Duo"]
                ]]]
                break
            }
            XCTAssertEqual(value("type"), "9")
            XCTAssertEqual(value("X-Plex-Container-Size"), String(CatalogPage.capacity))
            let offset = Int(value("X-Plex-Container-Start") ?? "")!
            var row: [String: Any] = ["ratingKey": "\(offset + 1)", "title": "Record \(offset + 1)",
                                      "parentTitle": "The Band", "year": 2025]
            if offset == 0 {
                row["ratingKey"] = 1
            }
            if offset == 1 {
                let xml = #"<MediaContainer totalSize="2" size="1"><Directory type="album" ratingKey="2" title="Second" parentTitle="The Band" studio="Second label" year="1999"><Genre tag="Techno"/><Style tag="Dub Techno"/><Collection tag="Scene: Coast"/></Directory></MediaContainer>"#
                rawBody = Data((request.value(forHTTPHeaderField: "Accept") == "application/xml" ? xml : "{").utf8)
            }
            json = ["MediaContainer": ["totalSize": 2, "offset": offset, "Metadata": [row]]]
        case "/library/sections/8/all":
            let offset = Int(value("X-Plex-Container-Start") ?? "")!
            let size = Int(value("X-Plex-Container-Size") ?? "")!
            let total = 1_000_000
            XCTAssertEqual(value("type"), "8")
            let artists = (offset..<min(offset + size, total)).map {
                ["ratingKey": String($0), "title": "Artist \($0)"]
            }
            json = ["MediaContainer": ["totalSize": total, "offset": offset, "Metadata": artists]]
        case "/library/metadata/1/children":
            json = ["MediaContainer": ["Metadata": [
                ["ratingKey": "12", "title": "Coda", "parentIndex": 2, "index": 1],
                ["ratingKey": "11", "title": "Prelude", "parentIndex": 1, "index": 1,
                 "duration": 94500, "originalTitle": "Guest", "Media": [["Part": [["key": "/library/parts/11/file.m4a?download=0"]]]]]
            ]]]
        default:
            status = 401
            json = [:]
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"), "test-client")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                               headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: rawBody ?? (try! JSONSerialization.data(withJSONObject: json)))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PlexClientTests: XCTestCase {
    func testKeychainSavesUpdatesAndClearsAnIsolatedCredential() throws {
        let credentials = Credentials(service: "org.sleeveplayer.tests." + UUID().uuidString)
        defer { try? credentials.clear() }
        XCTAssertNil(try credentials.read())
        try credentials.save("fixture-one")
        XCTAssertEqual(try credentials.read(), "fixture-one")
        try credentials.save("fixture-two")
        XCTAssertEqual(try credentials.read(), "fixture-two")
        try credentials.clear()
        XCTAssertNil(try credentials.read())
    }

    private var client: PlexClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return PlexClient(identifier: "test-client", session: URLSession(configuration: config))
    }
    private let server = PlexServer(id: "server", name: "Stereo", base: URL(string: "https://remote.example")!, token: "fixture-server")

    func testBrowserSignInAndServerFallback() async throws {
        let api = client
        let pin = try await api.createPin()
        let browser = api.authorizationURL(pin)
        XCTAssertEqual(browser.host, "app.plex.tv")
        XCTAssertTrue(browser.fragment?.contains("clientID=test-client&code=sample-pin") == true)
        let token = try await api.poll(pin)
        let resources = try await api.resources(token: token)
        XCTAssertEqual(resources.map(\.name), ["Stereo"])
        let resource = try XCTUnwrap(resources.first)
        XCTAssertEqual(resource.endpoints.compactMap(\.host), ["local.example", "remote.example", "relay.example"])
        let (connected, sections) = try await api.connect(resource)
        XCTAssertEqual(connected.base.host, "remote.example")
        XCTAssertEqual(sections.map(\.key), ["4"])
    }

    func testPagedAlbumsDiscOrderingAndDirectPlay() async throws {
        let api = client
        let section = LibrarySection(key: "4", title: "Music", type: "artist")
        let page = try await api.page(.albums, section: section, on: server, query: "", offset: 0)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertEqual(page.next, 1)
        let next = try await api.page(.albums, section: section, on: server, query: "", offset: XCTUnwrap(page.next))
        XCTAssertNil(next.next)
        guard case .album(let first) = page.rows.first, case .album(let second) = next.rows.first else {
            return XCTFail("Expected album metadata")
        }
        XCTAssertEqual([first.id, second.id], ["1", "2"])
        XCTAssertEqual(second.year, 1999)
        let tracks = try await api.tracks(album: first, on: server)
        XCTAssertEqual(tracks.map(\.title), ["Prelude", "Coda"])
        XCTAssertEqual(tracks.first?.duration, 94.5)
        XCTAssertEqual(tracks.first?.artist, "Guest")
        let url = try server.stream(for: tracks[0])
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "download", value: "0"), URLQueryItem(name: "X-Plex-Token", value: "fixture-server")])
        XCTAssertThrowsError(try server.stream(for: tracks[1]))
    }

    func testSearchRequestsOneTrackPageWithAlbumContext() async throws {
        let page = try await client.page(.tracks, section: LibrarySection(key: "4", title: "Music", type: "artist"),
                                         on: server, query: "Blue + Gold & Silver", offset: 0)
        guard case .track(let track, let album) = page.rows.first else { return XCTFail("Expected a track") }
        XCTAssertEqual(track.title, "Gold")
        XCTAssertEqual(album.id, "4")
        XCTAssertEqual(album.artist, "Duo")
        XCTAssertNil(page.next)
    }

    @MainActor
    func testAlbumPlaybackQueuesLatestPlexAlbum() async throws {
        let name = "CuePlaybackTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = try await connectedStore(defaults: defaults)
        store.player.volume = 0
        defer { store.clearQueue() }
        store.playAlbum(Album(id: "2", title: "Second", artist: "The Band", year: nil))
        store.playAlbum(Album(id: "1", title: "First", artist: "The Band", year: nil))
        try await waitUntil { store.player.current != nil }
        XCTAssertEqual(store.player.queue.map(\.track.id), ["11"])
        XCTAssertEqual(store.player.index, 0)
    }

    @MainActor
    private func connectedStore(defaults: UserDefaults) async throws -> LibraryStore {
        let store = LibraryStore(client: client, defaults: defaults)
        store.choose(PlexResource(clientIdentifier: "server", name: "Stereo", provides: "server", accessToken: server.token,
                                  connections: [.init(uri: server.base, local: false, relay: nil)]))
        try await waitUntil { !store.sections.isEmpty }
        store.choose(try XCTUnwrap(store.sections.first))
        try await waitUntil { store.section != nil }
        return store
    }

    @MainActor
    func testTableScrollsThroughPlexResultsAndBack() async throws {
        let name = "CueScrollTest-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = try await connectedStore(defaults: defaults)
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let search = try XCTUnwrap(root.descendants(of: NSSearchField.self).first)
        search.stringValue = "large"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitUntil { table.numberOfRows == 100_003 }
        for index in [48, 53, 85_000, 100_002, 0] {
            table.scrollRowToVisible(index)
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            try await waitUntil {
                (table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Large album \(index)"
            }
            XCTAssertEqual(table.selectedRow, index)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "Album", ascending: false)]
        try await waitUntil { table.numberOfRows == 100_003 }
        table.scrollRowToVisible(85_001)
        try await waitUntil {
            let cell = table.view(atColumn: 0, row: 85_001, makeIfNecessary: true) as? NSTableCellView
            return cell?.textField?.stringValue == "Large album 15001"
        }
    }

    @MainActor
    func testSortHeadersAndBreadcrumbNavigation() async throws {
        let suite = "CueNavigation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try await connectedStore(defaults: defaults)
        let controller = LibraryWindow(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        let search = try XCTUnwrap(root.descendants(of: NSSearchField.self).first)
        func switchTab(_ tab: Catalog) {
            tabs.selectedSegment = tab.rawValue
            _ = tabs.sendAction(tabs.action, to: tabs.target)
        }
        func cell(_ column: String, row: Int = 0) -> NSTextField? {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(column))
            guard index >= 0, table.numberOfRows > row else { return nil }
            return (table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
        }
        func openFirst() {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            table.keyDown(with: event)
        }
        try await waitUntil { cell("Album")?.stringValue == "Record 1" }
        XCTAssertEqual(table.tableColumns.filter { $0.sortDescriptorPrototype != nil }.map(\.title), ["Album", "Artist", "Year"])
        for (key, ascending, title) in [("Artist", true, "Second"), ("Artist", false, "First"),
                                        ("Album", false, "Second"), ("Album", true, "Record 1")] {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            try await waitUntil { cell("Album")?.stringValue == title }
        }
        switchTab(.tracks)
        try await waitUntil { cell("Track")?.stringValue == "Brass" }
        for (key, ascending, title) in [("Album", true, "Echo"), ("Album", false, "Brass"),
                                        ("Artist", false, "Echo"), ("Artist", true, "Brass")] {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            try await waitUntil { cell("Track")?.stringValue == title }
        }
        XCTAssertEqual(cell("No.", row: 1)?.stringValue, "2.3")
        let label = try XCTUnwrap(cell("Track"))
        let container = try XCTUnwrap(label.superview)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.frame.midY, container.bounds.midY, accuracy: 0.5)
        XCTAssertEqual(label.alignment, .left)
        switchTab(.artists)
        search.stringValue = "Band"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitUntil { cell("Artist")?.stringValue == "The Band" }
        openFirst()
        try await waitUntil { cell("Album")?.stringValue == "Record 1" }
        table.sortDescriptors = [NSSortDescriptor(key: "Year", ascending: true)]
        try await waitUntil { cell("Year")?.stringValue == "1995" }
        table.sortDescriptors = [NSSortDescriptor(key: "Year", ascending: false)]
        try await waitUntil { cell("Year")?.stringValue == "2001" }
        openFirst()
        try await waitUntil { cell("Track")?.stringValue == "Prelude" }
        let artist = try XCTUnwrap(root.descendants(of: NSButton.self).first { $0.title == "The Band" })
        artist.performClick(nil)
        try await waitUntil { cell("Year")?.stringValue == "2001" }
        openFirst()
        try await waitUntil { cell("Track")?.stringValue == "Prelude" }
        let ancestor = try XCTUnwrap(root.descendants(of: NSButton.self).first { $0.title == "Artists" })
        ancestor.performClick(nil)
        try await waitUntil { cell("Artist")?.stringValue == "The Band" }
        XCTAssertEqual(search.stringValue, "Band")
        switchTab(.tracks)
        XCTAssertEqual(table.sortDescriptors.first?.key, "Artist")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, true)
    }

    @MainActor
    func testTypingFromTablesFocusesSearchAndFiltersFromTheFirstKey() async throws {
        let suite = "CueTyping-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = LibraryWindow(store: try await connectedStore(defaults: defaults))
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let search = try XCTUnwrap(root.descendants(of: NSSearchField.self).first)
        func press(_ text: String, code: UInt16) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                       characters: text, charactersIgnoringModifiers: text,
                                                       isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        try await waitUntil { table.numberOfRows == 2 }
        XCTAssertTrue(window.makeFirstResponder(table))
        for (letter, code) in [("l", UInt16(37)), ("a", 0), ("r", 15), ("g", 5), ("e", 14)] {
            try press(letter, code: code)
        }
        XCTAssertTrue(window.firstResponder === search.currentEditor())
        XCTAssertEqual(search.stringValue, "large")
        try await waitUntil { table.numberOfRows == 100_003 }

        // Returning to the results makes the next typed character start a fresh query.
        try press("\r", code: 36)
        XCTAssertTrue(window.firstResponder === table)
        try press("x", code: 7)
        XCTAssertEqual(search.stringValue, "x")
        try await waitUntil { table.numberOfRows == 2 }
        try press("\r", code: 36)
        try press("\r", code: 36)
        try await waitUntil { table.tableColumns.first?.title == "No." && table.numberOfRows == 2 }
        try press("u", code: 32)
        try await waitUntil { table.numberOfRows == 1 }
        let title = table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(title?.textField?.stringValue, "Prelude")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw MusicError("The expected library state did not arrive.") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    func testCatalogCacheHandlesShortBatchesAndUnknownTotals() {
        var cache = CatalogRows()
        func page(_ start: Int, _ size: Int, _ next: Int?) -> CatalogPage {
            CatalogPage(rows: (start..<(start + size)).map { .artist(id: String($0), name: "Artist \($0)") },
                        total: nil, next: next)
        }
        for offset in stride(from: 0, to: 600, by: 20) {
            cache.insert(page(offset, 20, offset + 20), at: offset, near: offset..<(offset + 8), selected: 0)
            XCTAssertEqual(cache.neededOffset(for: (offset + 15)..<(offset + 20)), offset + 20)
            XCTAssertLessThan(cache.cached.count, 100)
        }
        cache.insert(page(600, 0, nil), at: 600, near: 590..<601, selected: 0)
        XCTAssertEqual(cache.total, 600)
        XCTAssertNil(cache.neededOffset(for: 590..<600))
        XCTAssertEqual(cache.cached[0]?.title, "Artist 0")
        XCTAssertEqual(cache.neededOffset(for: 1..<20), 1)
    }

    func testLargeArtistCatalogLoadsOnlyRequestedSlice() async throws {
        let section = LibrarySection(key: "8", title: "Music", type: "artist")
        let page = try await client.page(.artists, section: section, on: server, query: "", offset: 500_000)
        XCTAssertEqual(page.total, 1_000_000)
        XCTAssertEqual(page.rows.count, CatalogPage.capacity)
        XCTAssertEqual(page.next, 500_000 + CatalogPage.capacity)
        XCTAssertEqual(page.rows.first?.title, "Artist 500000")
        let end = try await client.page(.artists, section: section, on: server, query: "", offset: 999_997)
        XCTAssertEqual(end.rows.count, 3)
        XCTAssertNil(end.next)
    }

    func testMediaKeysRemainOnSelectedServer() {
        for path in ["https://other.example/file", "//other.example/file", "/\\other.example/file"] {
            XCTAssertThrowsError(try server.url(for: path))
        }
    }

    func testAccessDeniedIsActionable() async {
        do {
            _ = try await client.page(.albums, section: LibrarySection(key: "5", title: "Other", type: "artist"), on: server, query: "", offset: 0)
            XCTFail("Expected an access error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reconnect"))
        }
    }
}
