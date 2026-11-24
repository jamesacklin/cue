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
            XCTAssertEqual(value("type"), "9")
            XCTAssertEqual(value("X-Plex-Container-Size"), "250")
            let offset = Int(value("X-Plex-Container-Start") ?? "")!
            var row: [String: Any] = ["ratingKey": "\(offset + 1)", "title": "Record \(offset + 1)",
                                      "parentTitle": "The Band", "year": 2025]
            if offset == 0 {
                row["parentRatingKey"] = 7
                row["ratingKey"] = 1
                row["Media"] = "unused in album listings"
                row["Style"] = [["tag": "Drone"]]
                row["Genre"] = [["tag": "Ambient"]]
                row["studio"] = "  Test Imprint  "
                row["Collection"] = [["tag": "Favorites"], ["tag": "Scene: Docklands"], ["tag": "Scene: "]]
            }
            if offset == 1 {
                let xml = #"<MediaContainer totalSize="2" size="1"><Directory type="album" ratingKey="2" title="Second" parentTitle="The Band" studio="Second label" year="1999"><Genre tag="Techno"/><Style tag="Dub Techno"/><Collection tag="Scene: Coast"/></Directory></MediaContainer>"#
                rawBody = Data((request.value(forHTTPHeaderField: "Accept") == "application/xml" ? xml : "{").utf8)
            }
            json = ["MediaContainer": ["totalSize": 2, "offset": offset, "Metadata": [row]]]
        case "/library/sections/6/all":
            json = ["MediaContainer": ["totalSize": 2, "Metadata": [
                ["ratingKey": "70", "studio": "One", "parentRatingKey": "90"],
                ["ratingKey": "71", "studio": "Two", "parentRatingKey": "91"]
            ]]]
        case "/library/metadata/70,71":
            json = ["MediaContainer": ["Metadata": [
                ["ratingKey": "71"], ["ratingKey": "70", "Style": [["tag": "Drone"]]]
            ]]]
        case "/library/metadata/91":
            json = ["MediaContainer": ["Metadata": [["ratingKey": "91", "Genre": [["tag": "Ambient"]]]]]]
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
        let albums = try await api.albums(section: section, on: server)
        XCTAssertEqual(albums.map(\.id), ["1", "2"])
        XCTAssertEqual(albums[0].routeID, "id:7")
        XCTAssertEqual(albums[0].imprint, "Test Imprint")
        XCTAssertEqual(albums[0].scenes, ["Docklands"])
        XCTAssertEqual(albums[0].styles, ["Drone"])
        XCTAssertEqual(albums[1].styles, ["Dub Techno"])
        XCTAssertEqual(albums[0].genres, ["Ambient"])
        XCTAssertEqual(albums[1].genres, ["Techno"])
        XCTAssertEqual(albums[1].imprint, "Second label")
        XCTAssertEqual(albums[1].scenes, ["Coast"])
        XCTAssertEqual(albums[1].year, 1999)
        let tracks = try await api.tracks(album: try XCTUnwrap(albums.first), on: server)
        XCTAssertEqual(tracks.map(\.title), ["Prelude", "Coda"])
        XCTAssertEqual(tracks.first?.duration, 94.5)
        XCTAssertEqual(tracks.first?.artist, "Guest")
        let url = try server.stream(for: tracks[0])
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "download", value: "0"), URLQueryItem(name: "X-Plex-Token", value: "fixture-server")])
        XCTAssertThrowsError(try server.stream(for: tracks[1]))
    }

    func testMissingTagsUseBatchedAlbumDetailsThenArtistFallback() async throws {
        let albums = try await client.albums(section: LibrarySection(key: "6", title: "Music", type: "artist"), on: server)
        XCTAssertEqual(albums.map(\.styles), [["Drone"], []])
        XCTAssertEqual(albums.map(\.artistTags), [[], ["Ambient"]])
        XCTAssertEqual(albums.map(\.genres), [[], []])
    }

    func testMediaKeysRemainOnSelectedServer() {
        for path in ["https://other.example/file", "//other.example/file", "/\\other.example/file"] {
            XCTAssertThrowsError(try server.url(for: path))
        }
    }

    func testAccessDeniedIsActionable() async {
        do {
            _ = try await client.albums(section: LibrarySection(key: "5", title: "Other", type: "artist"), on: server)
            XCTFail("Expected an access error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Reconnect"))
        }
    }
}
