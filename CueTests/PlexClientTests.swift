import AppKit
import XCTest
@testable import Cue

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
        case "/api/v2/resources" where request.value(forHTTPHeaderField: "X-Plex-Token") == "expired-account":
            status = 401
            json = [:]
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
            if let name = value("artist.title=") {
                XCTAssertEqual(name, "Guest")
                XCTAssertEqual(value("type"), "9")
                json = ["MediaContainer": ["totalSize": 1, "Metadata": [
                    ["ratingKey": "2", "title": "Guest album", "parentTitle": "Guest"]
                ]]]
                break
            }
            if value("type") == "10", value("artist.id") == "44" {
                json = ["MediaContainer": ["totalSize": 1, "Metadata": [
                    ["ratingKey": "11", "title": "Band track", "parentTitle": "Record 1", "parentRatingKey": "1",
                     "grandparentTitle": "The Band", "grandparentRatingKey": 44, "originalTitle": "Guest"]
                ]]]
                break
            }
            if value("artist.title") == "column fixture" {
                let metadata: [String: Any] = ["ratingKey": "51", "title": value("sort") ?? "",
                    "index": 7, "parentIndex": 2, "duration": 123000, "parentYear": 1996,
                    "originalTitle": "Guest", "grandparentTitle": "Ensemble", "addedAt": 1700000000]
                json = ["MediaContainer": ["totalSize": 1, "Metadata": [metadata]]]
                break
            }
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
            if value("type") == "9", value("sort") != "album.titleSort",
               value("sort") != "artist.titleSort,album.year,album.titleSort,album.id" {
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
                case "album.titleSort:desc": ordered = Array(rows.reversed())
                case "artist.titleSort:desc,album.year,album.titleSort,album.id": ordered = rows
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
                                      "parentTitle": "The Band", "parentRatingKey": 44, "year": 2025]
            if offset == 0 {
                row["ratingKey"] = 1
            }
            if offset == 1 {
                let xml = #"<MediaContainer totalSize="2" size="1"><Directory type="album" ratingKey="2" title="Second" parentRatingKey="44" parentTitle="The Band" studio="Second label" year="1999"><Genre tag="Techno"/><Style tag="Dub Techno"/><Collection tag="Scene: Coast"/></Directory></MediaContainer>"#
                rawBody = Data((request.value(forHTTPHeaderField: "Accept") == "application/xml" ? xml : "{").utf8)
            }
            json = ["MediaContainer": ["totalSize": 2, "offset": offset, "Metadata": [row]]]
        case "/library/sections/12/all":
            // Two Plex batches. The earliest performer appears in the last batch.
            XCTAssertEqual(value("sort"), "titleSort")
            XCTAssertNil(value("track.title"))
            let start = Int(value("X-Plex-Container-Start")!)!
            let size = Int(value("X-Plex-Container-Size")!)!
            let total = 521
            let metadata = (start..<min(total, start + size)).map { n -> [String: Any] in
                var row: [String: Any] = ["ratingKey": String(n), "title": "Cut \(n)", "grandparentTitle": "Various Artists",
                    "parentTitle": "Compilation", "parentRatingKey": "record", "index": n + 1,
                    "originalTitle": "Performer \(total - n)"]
                if n == 0 { row.removeValue(forKey: "originalTitle"); row["grandparentTitle"] = "Middle Band" }
                if n == 1 { row["originalTitle"] = "  "; row["grandparentTitle"] = "Soloist" }
                return row
            }
            json = ["MediaContainer": ["Metadata": metadata, "offset": start, "totalSize": total]]
        case "/library/sections/8/all":
            let offset = Int(value("X-Plex-Container-Start") ?? "")!
            let size = Int(value("X-Plex-Container-Size") ?? "")!
            let total = 1_000_000
            XCTAssertEqual(value("type"), "8")
            let artists = (offset..<min(offset + size, total)).map {
                ["ratingKey": String($0), "title": "Artist \($0)"]
            }
            json = ["MediaContainer": ["totalSize": total, "offset": offset, "Metadata": artists]]
        case "/library/metadata/1/children", "/library/metadata/15001/children":
            json = ["MediaContainer": ["Metadata": [
                ["ratingKey": "12", "title": "Coda", "parentIndex": 2, "index": 1],
                ["ratingKey": "11", "title": "Prelude", "parentIndex": 1, "index": 1,
                 "duration": 94500, "originalTitle": "Guest", "Media": [["Part": [["key": "/library/parts/11/file.m4a?download=0"]]]]]
            ]]]
        case "/library/metadata/unpaged/children":
            XCTAssertEqual(value("X-Plex-Container-Start"), "0", "The first response contains the entire album")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", "Use the XML already delivered")
            let tracks = (1...125).map { #"<Track ratingKey="\#($0)" title="Track \#($0)" index="\#($0)"/>"# }.joined()
            rawBody = Data(("<MediaContainer size=\"125\">" + tracks + "</MediaContainer>").utf8)
            json = [:]
        case "/media/missing", "/media/forbidden", "/media/expired", "/media/offline", "/media/busy":
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertNil(value("X-Plex-Token"))
            XCTAssertEqual(value("download"), "0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "fixture-server")
            if url.path == "/media/offline" {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            status = ["/media/missing": 404, "/media/forbidden": 403, "/media/expired": 401, "/media/busy": 503][url.path]!
            json = [:]
        case "/library/metadata/2/children":
            json = ["MediaContainer": ["Metadata": [
                ["ratingKey": "22", "title": "Two", "index": 2, "Media": [["Part": [["key": "/library/parts/22/file.m4a"]]]]],
                ["ratingKey": "21", "title": "One", "index": 1, "Media": [["Part": [["key": "/library/parts/21/file.m4a"]]]]]
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
        let credentials = Credentials(service: "org.cueplayer.tests." + UUID().uuidString)
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
        XCTAssertEqual([first.artistID, second.artistID], ["44", "44"])
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

    func testAlbumConsumesUnpagedXMLInOneRequest() async throws {
        let album = Album(id: "unpaged", title: "Fixture", artist: "Band", year: nil)
        let tracks = try await client.tracks(album: album, on: server)
        XCTAssertEqual(tracks.map(\.number), Array(1...125))
    }

    func testDefaultCatalogSortRequests() async throws {
        let section = LibrarySection(key: "4", title: "Records", type: "artist")
        let cases: [(Catalog, String?, String)] = [
            (.albums, nil, "artist.titleSort,album.year,album.titleSort,album.id"),
            (.artists, nil, "artist.titleSort"),
            (.albums, "44", "album.year,album.titleSort,album.id"),
            (.tracks, nil, "titleSort")
        ]
        let api = client
        for (catalog, artistID, expected) in cases {
            let page = try await api.page(catalog, section: section, on: server, query: "column fixture", offset: 0,
                                          artist: artistID.map(ArtistFilter.id))
            XCTAssertEqual(page.rows.first?.title, expected)
        }
    }

    func testOptionalColumnsRequestPlexSortAndDisplayMetadata() async throws {
        let section = LibrarySection(key: "4", title: "Records", type: "artist")
        let cases: [(Catalog, CatalogOrder.Field, Bool, String)] = [
            (.artists, .recent, false, "artist.addedAt:desc"),
            (.albums, .recent, true, "album.addedAt"),
            (.tracks, .duration, false, "track.duration:desc,album.id,track.absoluteIndex,track.index"),
            (.tracks, .disc, true, "track.absoluteIndex,album.id,track.index"),
            (.tracks, .number, false, "track.absoluteIndex:desc,track.index:desc,album.id"),
            (.tracks, .year, true, "album.year,album.titleSort,album.id,track.absoluteIndex,track.index"),
            (.tracks, .albumArtist, true, "artist.titleSort,album.titleSort,album.id,track.absoluteIndex,track.index")
        ]
        let api = client
        for (catalog, field, ascending, expected) in cases {
            let page = try await api.page(catalog, section: section, on: server, query: "column fixture", offset: 0,
                                          order: CatalogOrder(field: field, ascending: ascending))
            let row = try XCTUnwrap(page.rows.first)
            XCTAssertEqual(row.title, expected)
            if catalog == .tracks {
                XCTAssertEqual(row.text(for: .year, position: 0), "1996")
                XCTAssertEqual(row.text(for: .disc, position: 0), "2")
                XCTAssertEqual(row.text(for: .number, position: 0), "2.7")
                XCTAssertEqual(row.text(for: .duration, position: 0), "2:03")
                XCTAssertEqual(row.text(for: .artist, position: 0), "Guest")
                XCTAssertEqual(row.text(for: .albumArtist, position: 0), "Ensemble")
            } else {
                let date = Date(timeIntervalSince1970: 1700000000).formatted(date: .abbreviated, time: .omitted)
                XCTAssertEqual(row.text(for: .recent, position: 0), date)
            }
        }
    }

    func testTrackArtistSortAcrossPlexPagesAndCompilationSearch() async throws {
        let api = client
        let index = try TrackArtistIndex()
        let library = LibrarySection(key: "12", title: "Various", type: "artist")
        func page(_ offset: Int, ascending: Bool = true, query: String = "") async throws -> CatalogPage {
            try await api.page(.tracks, section: library, on: server, query: query, offset: offset,
                               order: CatalogOrder(field: .artist, ascending: ascending), trackArtistIndex: index)
        }
        let first = try await page(0)
        XCTAssertEqual(first.total, 521)
        XCTAssertEqual(first.next, 50)
        XCTAssertEqual(first.rows.prefix(3).map(\.title), ["Cut 0", "Cut 520", "Cut 519"])
        let second = try await page(50)
        XCTAssertEqual(second.rows.first?.text(for: .artist, position: 50), "Performer 50")
        let last = try await page(520)
        XCTAssertNil(last.next)
        XCTAssertEqual(last.rows.first?.text(for: .artist, position: 520), "Soloist")
        let reverse = try await page(0, ascending: false)
        XCTAssertEqual(reverse.rows.prefix(3).map(\.title), ["Cut 1", "Cut 2", "Cut 3"])
        let filtered = try await page(0, query: "pErFoRmEr 519")
        XCTAssertEqual(filtered.rows.map(\.title), ["Cut 2"])
        XCTAssertEqual(filtered.rows.first?.text(for: .albumArtist, position: 0), "Various Artists")
        let empty = try await page(0, query: "no such performer")
        XCTAssertEqual(empty.total, 0)
        XCTAssertNil(empty.next)
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
        store.enqueue(.album(Album(id: "2", title: "Second", artist: "The Band", year: nil)), action: .replace)
        store.enqueue(.album(Album(id: "1", title: "First", artist: "The Band", year: nil)), action: .replace)
        try await waitUntil { store.player.current != nil }
        XCTAssertEqual(store.player.current?.track.id, "11")
        XCTAssertEqual(store.player.queue.map(\.track.id), ["11"])
    }

    @MainActor
    func testLibraryRowMenusQueueTheClickedAlbumArtistAndTrack() async throws {
        let name = "CueQueueMenu-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = try await connectedStore(defaults: defaults)
        store.player.volume = 0
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { store.clearQueue(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        func waitFor(_ name: String, _ condition: () -> Bool) async -> Bool {
            do {
                try await waitUntil(condition)
                return true
            } catch {
                XCTFail("Timed out waiting for \(name). Rows: \(table.numberOfRows), queued: \(store.player.queue.map(\.track.id))")
                return false
            }
        }
        func menu(at row: Int) throws -> NSMenu {
            let menu = try contextMenu(for: table, row: row)
            XCTAssertEqual(menu.items.prefix(2).map(\.title), ["Append to Queue", "Replace Queue"])
            XCTAssertTrue(menu.items[2].isSeparatorItem)
            return menu
        }

        guard await waitFor("albums", { table.numberOfRows == 2 }) else { return }
        try menu(at: 0).performActionForItem(at: 1)
        guard await waitFor("first album playback", { store.player.current?.track.id == "11" }) else { return }
        tabs.selectedSegment = Catalog.artists.rawValue
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        guard await waitFor("artists", { table.numberOfRows == 1 }) else { return }
        let artist = try menu(at: 0)
        artist.performActionForItem(at: 0)
        artist.performActionForItem(at: 0)
        guard await waitFor("two artist appends", { store.player.queue.count == 7 }) else { return }
        XCTAssertEqual(store.player.current?.track.id, "11")
        XCTAssertEqual(store.player.queue.map(\.track.id), ["11", "21", "22", "11", "21", "22", "11"])

        // Open the second album using the keyboard, then append just its second track.
        tabs.selectedSegment = Catalog.albums.rawValue
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        guard await waitFor("second album", {
            guard table.numberOfRows == 2 else { return false }
            return (table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Second"
        }) else { return }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        guard await waitFor("album tracks", { table.tableColumns.first?.title == "No." && table.numberOfRows == 2 }) else { return }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let track = try menu(at: 1)
        track.performActionForItem(at: 0)
        guard await waitFor("single track append", { store.player.queue.count == 8 }) else { return }
        XCTAssertEqual(store.player.queue.last?.track.id, "22")
        track.performActionForItem(at: 1)
        guard await waitFor("replacement track playback", { store.player.current?.track.id == "22" }) else { return }
        XCTAssertEqual(store.player.queue.map(\.track.id), ["22"])

        tabs.selectedSegment = Catalog.allCases.count
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        try await waitUntil { table.numberOfRows == 1 }
        let queuedTrack = try contextMenu(for: table, row: 0)
        XCTAssertEqual(queuedTrack.items.map(\.title), ["Go to Second", "Go to The Band"])
        queuedTrack.performActionForItem(at: 0)
        try await waitUntil { table.tableColumns.first?.title == "No." && table.numberOfRows == 2 }
        controller.back()
        try await waitUntil { table.numberOfRows == 1 && table.allowsMultipleSelection }
        XCTAssertEqual(store.player.queue.map(\.track.id), ["22"])
    }

    @MainActor
    private func contextMenu(for table: NSTableView, row: Int) throws -> NSMenu {
        let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: row).midY), to: nil)
        let window = try XCTUnwrap(table.window)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(table.menu(for: event))
        for item in menu.items where !item.isSeparatorItem { XCTAssertNotNil(item.image, item.title) }
        return menu
    }

    @MainActor
    func testContextMenuNavigationUsesTheClickedRowsParents() async throws {
        let suite = "CueNavigationMenus-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try await connectedStore(defaults: defaults)
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        func firstTitle(_ column: String) -> String? {
            let index = table.column(withIdentifier: .init(column))
            guard index >= 0, table.numberOfRows > 0 else { return nil }
            return (table.view(atColumn: index, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
        }
        func follow(_ title: String) throws {
            let menu = try contextMenu(for: table, row: 0)
            let item = try XCTUnwrap(menu.item(withTitle: title))
            menu.performActionForItem(at: menu.index(of: item))
        }

        try await waitUntil { firstTitle("Album") == "Record 1" }
        try follow("See all albums by The Band")
        try await waitUntil { firstTitle("Album") == "Second" }
        controller.back()
        try await waitUntil { firstTitle("Album") == "Record 1" }
        tabs.selectedSegment = Catalog.artists.rawValue
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        try await waitUntil { firstTitle("Artist") == "The Band" }
        try follow("See all tracks by The Band")
        try await waitUntil { firstTitle("Track") == "Band track" }
        table.sortDescriptors = [NSSortDescriptor(key: "Artist", ascending: true)]
        try await waitUntil { firstTitle("Track") == "Band track" }
        let trackMenu = try contextMenu(for: table, row: 0)
        XCTAssertEqual(trackMenu.items.suffix(2).map(\.title), ["Go to Record 1", "Go to Guest"])
        try follow("Go to Record 1")
        try await waitUntil { firstTitle("Track") == "Prelude" }
        controller.back()
        try await waitUntil { firstTitle("Track") == "Band track" }
        try follow("Go to Guest")
        try await waitUntil { firstTitle("Album") == "Guest album" }
        XCTAssertNil(store.player.current)
        XCTAssertTrue(store.player.queue.isEmpty)
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

        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        let window = try XCTUnwrap(controller.window)
        let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
        func tab(_ index: Int) {
            tabs.selectedSegment = index
            _ = tabs.sendAction(tabs.action, to: tabs.target)
        }
        let target = 85_001
        table.scroll(NSPoint(x: 0, y: table.rect(ofRow: target - 3).minY + 7))
        table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        let origin = clip.bounds.origin
        func assertParentRestored() async throws {
            try await waitUntil { table.numberOfRows == 100_003 && table.selectedRow == target }
            XCTAssertEqual(search.stringValue, "large")
            XCTAssertEqual(table.sortDescriptors.first?.ascending, false)
            XCTAssertEqual(clip.bounds.origin.y, origin.y, accuracy: 0.5)
            try await waitUntil {
                (table.view(atColumn: 0, row: target, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Large album 15001"
            }
        }
        tab(3)
        try await waitUntil { table.tableColumns.first?.title == "Track" }
        tab(0)
        XCTAssertEqual(table.numberOfRows, 100_003, "The cached viewport is available immediately")
        try await assertParentRestored()
        controller.refresh()
        XCTAssertEqual(table.numberOfRows, 0, "Refresh discards the cached viewport")
        try await assertParentRestored()
        func openSelection() throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            table.keyDown(with: event)
        }
        try openSelection()
        try await waitUntil { table.tableColumns.first?.title == "No." && table.numberOfRows == 2 }
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        tab(2)
        tab(0)
        try await waitUntil { table.tableColumns.first?.title == "No." && table.selectedRow == 1 }
        controller.back()
        try await assertParentRestored()
        try openSelection()
        let parent = try XCTUnwrap(root.descendants(of: NSButton.self).first { $0.title == "Albums" })
        parent.performClick(nil)
        try await assertParentRestored()
    }

    @MainActor
    func testTrackColumnsFitTheViewportOnTabChangesAndResize() throws {
        let suite = "CueColumnWidth-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["No.", "Track", "Artist", "Album", "Time", "Disc", "Year", "Album Artist"], forKey: "columns.Tracks")
        let store = LibraryStore(defaults: defaults)
        let controller = LibraryWindow(store: store)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        scroll.scrollerStyle = .legacy
        controller.showWindow(nil)

        tabs.selectedSegment = Catalog.tracks.rawValue
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        XCTAssertEqual(table.numberOfColumns, 8)

        for width: CGFloat in [760, window.contentMinSize.width, 980, window.contentMinSize.width, 760] {
            window.setContentSize(NSSize(width: width, height: 420))
            root.layoutSubtreeIfNeeded()
            let columnEnd = table.rect(ofColumn: table.numberOfColumns - 1).maxX
            XCTAssertEqual(columnEnd, scroll.contentView.bounds.width, accuracy: 1, "Window width \(width)")
            XCTAssertTrue(scroll.horizontalScroller?.isHidden == true,
                          "Window width \(width), document width \(table.frame.width), column edge \(columnEnd)")
            XCTAssertEqual(table.tableColumns[0].width, 52)
        }

        let resized = try XCTUnwrap(table.tableColumn(withIdentifier: .init("Track")))
        let requestedWidth = resized.width + 28
        resized.width = requestedWidth
        NotificationCenter.default.post(name: NSTableView.columnDidResizeNotification, object: table,
                                        userInfo: ["NSTableColumn": resized])
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(resized.width, requestedWidth, accuracy: 1)
        XCTAssertEqual(table.rect(ofColumn: table.numberOfColumns - 1).maxX, scroll.contentView.bounds.width, accuracy: 1,
                       "Column widths: \(table.tableColumns.map(\.width))")
        XCTAssertTrue(scroll.horizontalScroller?.isHidden == true)
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
        XCTAssertEqual(table.sortDescriptors.first?.key, "Artist")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(table.tableColumns.filter { $0.sortDescriptorPrototype != nil }.map(\.title), ["Album", "Artist", "Year"])
        for (key, ascending, title) in [("Artist", false, "First"), ("Artist", true, "Record 1"),
                                        ("Album", false, "Second"), ("Album", true, "Record 1")] {
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            try await waitUntil { cell("Album")?.stringValue == title }
        }
        switchTab(.tracks)
        try await waitUntil { cell("Track")?.stringValue == "Brass" }
        XCTAssertEqual(table.sortDescriptors.first?.key, "Track")
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
        XCTAssertEqual(table.sortDescriptors.first?.key, "Artist")
        openFirst()
        try await waitUntil { cell("Year")?.stringValue == "1995" }
        XCTAssertEqual(table.sortDescriptors.first?.key, "Year")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, true)
        table.sortDescriptors = [NSSortDescriptor(key: "Year", ascending: false)]
        try await waitUntil { cell("Year")?.stringValue == "2001" }
        openFirst()
        try await waitUntil { cell("Track")?.stringValue == "Prelude" }
        XCTAssertEqual(table.sortDescriptors.first?.key, "No.")
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
    func testTitlebarAppearanceTracksWindowFocusNotifications() throws {
        let controller = LibraryWindow(store: LibraryStore())
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        controller.showWindow(nil)
        defer { controller.close() }
        let content = try XCTUnwrap(window.contentView)
        let strip = try XCTUnwrap(content.subviews.first { !($0 is NSStackView) })
        func capture(_ name: String) throws -> CGFloat {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let rep = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
            strip.cacheDisplay(in: strip.bounds, to: rep)
            let x = rep.pixelsWide / 2
            func luminance(at y: Int) throws -> CGFloat {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
            let attachment = XCTAttachment(data: try XCTUnwrap(rep.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return try abs(luminance(at: 2) - luminance(at: rep.pixelsHigh - 3))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            let focused = try capture("Cue-focused-" + appearance.rawValue)
            if !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                XCTAssertGreaterThan(focused, 0.03)
            }
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertLessThan(try capture("Cue-inactive-" + appearance.rawValue), 0.005)
        }
    }

    @MainActor
    func testToolbarOpensAndDismissesPlexConnectionAtMinimumWidth() async throws {
        let controller = LibraryWindow(store: LibraryStore())
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        controller.showWindow(nil)
        defer { controller.close() }
        let item = try XCTUnwrap(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == "CuePlexConnection" })
        let content = try XCTUnwrap(window.contentView)
        let library = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first)
        window.layoutIfNeeded()
        XCTAssertLessThan(library.frame.maxY, content.bounds.maxY)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(item.isBordered)
        XCTAssertNil(item.view)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        try await waitUntil { window.attachedSheet != nil }
        let done = try XCTUnwrap(window.attachedSheet?.contentView?.descendants(of: NSButton.self).first { $0.title == "Done" })
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.defaultButtonCell === done.cell)
        XCTAssertEqual(sheet.effectiveAppearance.name, window.effectiveAppearance.name)
        sheet.contentViewController?.cancelOperation(nil)
        try await waitUntil { window.attachedSheet == nil }
    }

    @MainActor
    func testToolbarShowsServerNameAfterLibraryIsValidated() async throws {
        let suite = "CueConnectionToolbar-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(client: client, defaults: defaults)
        let controller = LibraryWindow(store: store)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(window.contentMinSize)
        controller.showWindow(nil)
        defer { controller.close() }

        let item = try XCTUnwrap(window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == "CuePlexConnection" })
        let disconnectedIcon = item.image
        XCTAssertNotNil(disconnectedIcon)
        XCTAssertEqual(item.title, "Connect to Plex…")

        let name = "Stereo in the living room and a very long Plex server name for the toolbar"
        store.choose(PlexResource(clientIdentifier: "server", name: name, provides: "server", accessToken: server.token,
                                  connections: [.init(uri: server.base, local: false, relay: nil)]))
        try await waitUntil { !store.sections.isEmpty }
        XCTAssertEqual(item.title, "Connect to Plex…")

        store.choose(try XCTUnwrap(store.sections.first))
        try await waitUntil { item.label == name }
        XCTAssertTrue(name.hasPrefix(String(item.title.dropLast())))
        XCTAssertTrue(item.title.hasSuffix("…"))
        XCTAssertEqual(item.toolTip, "Connected to \(name)")
        XCTAssertNotNil(item.image)
        XCTAssertFalse(item.image === disconnectedIcon)
        window.layoutIfNeeded()
        XCTAssertTrue(window.toolbar?.visibleItems?.contains(item) == true)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        try await waitUntil { window.attachedSheet != nil }
        let done = try XCTUnwrap(window.attachedSheet?.contentView?.descendants(of: NSButton.self).first { $0.title == "Done" })
        done.performClick(nil)
        try await waitUntil { window.attachedSheet == nil }
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

    func testMediaFailureChecksOnlyHeadersAndDistinguishesRecoveryActions() async throws {
        let api = client
        for (path, expected) in [("missing", PlexFailure.missing), ("forbidden", .forbidden),
                                 ("expired", .unauthorized), ("offline", .disconnected), ("busy", .unavailable)] {
            let url = try server.url(for: "/media/\(path)?download=0&X-Plex-Token=fixture-server")
            let failure = await api.mediaFailure(at: url)
            XCTAssertEqual(failure, expected)
        }
    }

    @MainActor
    func testExpiredAccountCanSignInAgainAndRestoreExistingQueue() async throws {
        let suite = "CueReauth-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let credentials = Credentials(service: suite)
        defer { try? credentials.clear(); defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(client: client, defaults: defaults, credentials: credentials)
        store.choose(PlexResource(clientIdentifier: "server", name: server.name, provides: "server", accessToken: server.token,
                                  connections: [.init(uri: server.base, local: false, relay: nil)]))
        try await waitUntil { !store.sections.isEmpty }
        store.choose(try XCTUnwrap(store.sections.first))
        try await waitUntil { store.section != nil }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-fixture", withExtension: "m4a"))
        let track = Track(id: "11", title: "Prelude", artist: "Guest", disc: 1, number: 1, duration: 24, part: "/media/11")
        let album = Album(id: "1", title: "Album", artist: "Guest", year: nil)
        let entry = QueueEntry(track: track, album: album, url: file)
        defer { store.clearQueue() }
        store.player.volume = 0
        store.player.append([entry])
        store.player.pause()

        try credentials.save("expired-account")
        store.restore()
        try await waitUntil { store.needsSignIn && store.activity == nil }
        XCTAssertTrue(store.showConnection)
        XCTAssertEqual(store.player.current?.id, entry.id)
        store.signIn { $0.host == "app.plex.tv" }
        try await waitUntil { store.activity == nil && !store.showConnection }
        XCTAssertFalse(store.needsSignIn)
        XCTAssertEqual(store.section?.id, "4")
        XCTAssertEqual(store.player.queue, [entry])
        XCTAssertFalse(store.player.playing)
        XCTAssertEqual(try credentials.read(), "fixture-account")
        let stale = QueueEntry(track: track, album: album, url: try server.url(for: "/media/11?X-Plex-Token=stale"))
        XCTAssertEqual(store.player.mediaURL?(stale), try store.server?.stream(for: track))
    }

    func testAccessDeniedIsActionable() async {
        do {
            _ = try await client.page(.albums, section: LibrarySection(key: "5", title: "Other", type: "artist"), on: server, query: "", offset: 0)
            XCTFail("Expected an access error")
        } catch {
            XCTAssertEqual(error as? PlexFailure, .unauthorized)
        }
    }
}
