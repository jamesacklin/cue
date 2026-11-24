import Foundation

struct PlexResource: Decodable, Identifiable {
    struct Connection: Decodable {
        let uri: URL
        let local: Bool
        let relay: Bool?
    }

    let clientIdentifier: String
    let name: String
    let provides: String
    let accessToken: String?
    let connections: [Connection]?
    var id: String { clientIdentifier }

    var endpoints: [URL] {
        (connections ?? []).filter { $0.uri.scheme == "https" }
            .sorted { rank($0) < rank($1) }.map(\.uri)
    }

    private func rank(_ connection: Connection) -> Int {
        if connection.relay == true { return 2 }
        return connection.local ? 0 : 1
    }
}

struct PlexServer {
    let id: String
    let name: String
    let base: URL
    let token: String

    // Keys received from PMS must stay on the server the listener selected.
    func url(for key: String) throws -> URL {
        guard key.hasPrefix("/"), !key.hasPrefix("//"), !key.contains("\\"),
              let url = URL(string: key, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else {
            throw MusicError("The server returned an invalid media address.")
        }
        return url
    }

    func stream(for track: Track) throws -> URL {
        guard let part = track.part else { throw MusicError("Plex has no playable file for this track.") }
        var components = URLComponents(url: try url(for: part), resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "X-Plex-Token" }
            + [URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let url = components.url else { throw MusicError("This track has an invalid address.") }
        return url
    }
}

private struct PlexEnvelope: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let Directory: [LibrarySection]?
        let Metadata: [MetadataItem]?
        let totalSize: Int?
        let offset: Int?
    }
}

private struct MetadataItem: Decodable {
    let ratingKey: String
    let title: String
    let parentTitle: String?
    let grandparentTitle: String?
    let originalTitle: String?
    let thumb: String?
    let year: Int?
    let addedAt: Int?
    let parentIndex: Int?
    let index: Int?
    let duration: Int?
    let Media: [MediaItem]?

    struct MediaItem: Decodable {
        let Part: [PartItem]?
        struct PartItem: Decodable { let key: String? }
    }
}

struct PlexPin: Decodable {
    let id: Int
    let code: String
    let expiresIn: Int?
    let authToken: String?
}

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let source = task.originalRequest?.url
        guard let url = request.url, url.scheme == source?.scheme, url.host == source?.host,
              url.port == source?.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}

struct PlexClient {
    let identifier: String
    let session: URLSession
    init(identifier: String, session: URLSession? = nil) {
        self.identifier = identifier
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    func request(_ url: URL, token: String? = nil) -> URLRequest {
        var result = URLRequest(url: url, timeoutInterval: 15)
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("Sleeve", forHTTPHeaderField: "X-Plex-Product")
        result.setValue(identifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        result.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        return result
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicError("Plex did not send a response.") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MusicError("Plex denied access. Reconnect to Plex to renew your sign-in.")
        case 404: throw MusicError("Plex could not find this item. Refresh the library and try again.")
        default: throw MusicError("Plex returned HTTP \(http.statusCode). Try again when the server is available.")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw MusicError("Plex sent an unreadable response. Check the server and retry.") }
    }

    func createPin() async throws -> PlexPin {
        var req = request(URL(string: "https://plex.tv/api/v2/pins?strong=true")!)
        req.httpMethod = "POST"
        return try await decode(req)
    }

    func authorizationURL(_ pin: PlexPin) -> URL {
        var fragment = URLComponents()
        fragment.queryItems = [
            URLQueryItem(name: "clientID", value: identifier),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: "Sleeve")
        ]
        return URL(string: "https://app.plex.tv/auth#?" + (fragment.percentEncodedQuery ?? ""))!
    }

    func poll(_ pin: PlexPin) async throws -> String {
        let expires = Date().addingTimeInterval(Double(pin.expiresIn ?? 300))
        while Date() < expires {
            try await Task.sleep(for: .seconds(1))
            let status: PlexPin = try await decode(request(URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!))
            if let token = status.authToken, !token.isEmpty { return token }
        }
        throw MusicError("The sign-in link expired. Start a new sign-in.")
    }

    func resources(token: String) async throws -> [PlexResource] {
        let url = URL(string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1")!
        let resources: [PlexResource] = try await decode(request(url, token: token))
        return resources.filter { $0.provides.split(separator: ",").contains("server") && $0.accessToken != nil }
    }

    func connect(_ resource: PlexResource) async throws -> (PlexServer, [LibrarySection]) {
        guard let token = resource.accessToken else { throw MusicError("This server did not grant access.") }
        for address in resource.endpoints {
            try Task.checkCancellation()
            let server = PlexServer(id: resource.id, name: resource.name, base: address, token: token)
            do {
                var req = request(try server.url(for: "/library/sections"), token: token)
                req.timeoutInterval = 4
                let response: PlexEnvelope = try await decode(req)
                return (server, (response.MediaContainer.Directory ?? []).filter { $0.type == "artist" })
            } catch { try Task.checkCancellation() }
        }
        throw MusicError("Couldn’t reach \(resource.name). Check that it’s online and accepts secure connections.")
    }

    private func items(_ path: String, on server: PlexServer,
                       query: [URLQueryItem] = []) async throws -> [MetadataItem] {
        let batchSize = 250
        var all: [MetadataItem] = []
        var seen = Set<String>()
        var start = 0
        while true {
            try Task.checkCancellation()
            let url = try server.url(for: path).appending(queryItems: query + [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(batchSize))
            ])
            let result: PlexEnvelope = try await decode(request(url, token: server.token))
            let page = result.MediaContainer
            let batch = page.Metadata ?? []
            if batch.isEmpty { break }
            let new = batch.filter { seen.insert($0.ratingKey).inserted }
            guard !new.isEmpty else { break }
            all.append(contentsOf: new)
            start += batch.count
            if let total = page.totalSize {
                if start >= total { break }
            } else if batch.count < batchSize { break }
        }
        return all
    }

    func albums(section: LibrarySection, on server: PlexServer) async throws -> [Album] {
        try await items("/library/sections/\(section.key)/all", on: server,
                        query: [URLQueryItem(name: "type", value: "9")]).map {
            Album(id: $0.ratingKey, title: $0.title, artist: $0.parentTitle ?? "Unknown Artist",
                  year: $0.year, added: $0.addedAt ?? 0, thumb: $0.thumb)
        }
    }

    func tracks(album: Album, on server: PlexServer) async throws -> [Track] {
        try await items("/library/metadata/\(album.id)/children", on: server).map {
            Track(id: $0.ratingKey, title: $0.title, artist: $0.originalTitle ?? $0.grandparentTitle ?? album.artist,
                  disc: $0.parentIndex ?? 1, number: $0.index ?? 0, duration: Double($0.duration ?? 0) / 1000,
                  part: $0.Media?.first?.Part?.first?.key)
        }.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }
}
