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
        switch url.path {
        case "/api/v2/pins":
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(value("strong"), "true")
            json = ["id": 8, "code": "sample-pin", "expiresIn": 5]
        case "/api/v2/pins/8":
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
            let row: [String: Any] = ["ratingKey": "\(offset + 1)", "title": "Record \(offset + 1)",
                                      "parentTitle": "The Band", "year": 2025]
            json = ["MediaContainer": ["totalSize": 2, "offset": offset, "Metadata": [row]]]
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
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
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
        let tracks = try await api.tracks(album: try XCTUnwrap(albums.first), on: server)
        XCTAssertEqual(tracks.map(\.title), ["Prelude", "Coda"])
        XCTAssertEqual(tracks.first?.duration, 94.5)
        XCTAssertEqual(tracks.first?.artist, "Guest")
        let url = try server.stream(for: tracks[0])
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "download", value: "0"), URLQueryItem(name: "X-Plex-Token", value: "fixture-server")])
        XCTAssertThrowsError(try server.stream(for: tracks[1]))
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
