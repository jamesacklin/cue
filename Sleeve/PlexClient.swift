import Foundation
import OSLog

private let connectionLog = Logger(subsystem: "org.sleeveplayer.Sleeve", category: "PlexConnection")

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

private struct PlexEnvelope<Container: Decodable>: Decodable {
    let MediaContainer: Container
}

private struct SectionList: Decodable {
    let Directory: [LibrarySection]?
}

private struct MetadataPage<Row: Decodable>: Decodable {
    let Metadata: [Row]?
    let totalSize: Int?
}

// Plex can serialize database keys as either JSON numbers or strings.
private struct PlexKey: Decodable {
    let value: String
    init(_ value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else {
            value = String(try container.decode(Int.self))
        }
    }
}

private protocol PlexRow: Decodable {
    var ratingKey: PlexKey { get }
}

private struct AlbumRow: PlexRow {
    let ratingKey: PlexKey
    let title: String?
    struct Tag: Decodable { let tag: String? }
    let studio: String?
    let Collection: [Tag]?
    let Genre: [Tag]?
    let Style: [Tag]?
    let parentRatingKey: PlexKey?
    let parentTitle: String?
    let thumb: String?
    let year: Int?
    let addedAt: Int?
}

private extension AlbumRow {
    init(xml: XMLElement) throws {
        func attribute(_ name: String) -> String? { xml.attribute(forName: name)?.stringValue }
        guard let key = attribute("ratingKey") else { throw MusicError("An album listing is missing its Plex identifier.") }
        ratingKey = PlexKey(key)
        title = attribute("title")
        studio = attribute("studio")
        Style = xml.elements(forName: "Style").map { Tag(tag: $0.attribute(forName: "tag")?.stringValue) }
        Genre = xml.elements(forName: "Genre").map { Tag(tag: $0.attribute(forName: "tag")?.stringValue) }
        Collection = xml.elements(forName: "Collection").map { Tag(tag: $0.attribute(forName: "tag")?.stringValue) }
        parentRatingKey = attribute("parentRatingKey").map(PlexKey.init)
        parentTitle = attribute("parentTitle")
        thumb = attribute("thumb")
        year = attribute("year").flatMap(Int.init)
        addedAt = attribute("addedAt").flatMap(Int.init)
    }
}

private struct TrackRow: PlexRow {
    let ratingKey: PlexKey
    let title: String
    let grandparentTitle: String?
    let originalTitle: String?
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

    private func responseData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MusicError("Plex did not send a response.") }
        if http.statusCode >= 400 { connectionLog.error("Plex request returned HTTP \(http.statusCode, privacy: .public)") }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw MusicError("Plex denied access. Reconnect to Plex to renew your sign-in.")
        case 404: throw MusicError("Plex could not find this item. Refresh the library and try again.")
        default: throw MusicError("Plex returned HTTP \(http.statusCode). Try again when the server is available.")
        }
        return data
    }

    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        try decodeJSON(T.self, from: await responseData(request))
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch let error as DecodingError {
            let path: [CodingKey]
            switch error {
            case let .keyNotFound(key, context): path = context.codingPath + [key]
            case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
                path = context.codingPath
            @unknown default: path = []
            }
            let field = path.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            let location = field.isEmpty ? "JSON document" : field
            connectionLog.error("Response decoding failed at \(location, privacy: .public)")
            throw MusicError("Sleeve couldn’t read Plex’s \(location).")
        }
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
            let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!
                .appending(queryItems: [URLQueryItem(name: "code", value: pin.code)])
            let status: PlexPin = try await decode(request(url))
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
                let response: PlexEnvelope<SectionList> = try await decode(req)
                return (server, (response.MediaContainer.Directory ?? []).filter { $0.type == "artist" })
            } catch {
                try Task.checkCancellation()
                let code = (error as NSError).code
                connectionLog.error("Music section request failed with error code \(code, privacy: .public)")
            }
        }
        throw MusicError("Couldn’t reach \(resource.name). Check that it’s online and accepts secure connections.")
    }

    private func albumPage(_ request: URLRequest) async throws -> MetadataPage<AlbumRow> {
        let data = try await responseData(request)
        if let page = try? JSONDecoder().decode(PlexEnvelope<MetadataPage<AlbumRow>>.self, from: data) {
            return page.MediaContainer
        }
        // Some PMS listings contain metadata the server cannot serialize as valid JSON.
        var xmlRequest = request
        xmlRequest.setValue("application/xml", forHTTPHeaderField: "Accept")
        let xml = try await responseData(xmlRequest)
        let document = try XMLDocument(data: xml, options: .nodeLoadExternalEntitiesNever)
        guard let root = document.rootElement(), root.name == "MediaContainer" else {
            throw MusicError("Plex returned an unexpected album list in both JSON and XML.")
        }
        let rows = try root.elements(forName: "Directory").map(AlbumRow.init(xml:))
        let total = (root.attribute(forName: "totalSize")?.stringValue).flatMap(Int.init)
        guard !rows.isEmpty || root.attribute(forName: "size")?.stringValue == "0" else {
            throw MusicError("Plex returned an album page without album entries.")
        }
        connectionLog.notice("Read album page using XML fallback: \(rows.count, privacy: .public) albums")
        return MetadataPage(Metadata: rows, totalSize: total)
    }

    private func items<Row: PlexRow>(_ path: String, on server: PlexServer,
                       query: [URLQueryItem] = [], pageFor: (URLRequest) async throws -> MetadataPage<Row>) async throws -> [Row] {
        let batchSize = 250
        var all: [Row] = []
        var seen = Set<String>()
        var start = 0
        while true {
            try Task.checkCancellation()
            let url = try server.url(for: path).appending(queryItems: query + [
                URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                URLQueryItem(name: "X-Plex-Container-Size", value: String(batchSize))
            ])
            let page = try await pageFor(request(url, token: server.token))
            let batch = page.Metadata ?? []
            if batch.isEmpty { break }
            let new = batch.filter { seen.insert($0.ratingKey.value).inserted }
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
        var albums = try await items("/library/sections/\(section.key)/all", on: server,
                        query: [URLQueryItem(name: "type", value: "9"),
                                URLQueryItem(name: "includeOptionalElements", value: "Genre,Style")], pageFor: albumPage).map {
            let scenes = ($0.Collection ?? []).compactMap { entry -> String? in
                guard let tag = entry.tag, tag.lowercased().hasPrefix("scene:") else { return nil }
                let name = tag.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            let imprint = $0.studio?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Album(id: $0.ratingKey.value, title: $0.title ?? "Untitled album", artist: $0.parentTitle ?? "Unknown Artist",
                  year: $0.year, added: $0.addedAt ?? 0, thumb: $0.thumb, artistID: $0.parentRatingKey?.value,
                  imprint: imprint == "" ? nil : imprint, scenes: Set(scenes).sorted(),
                  genres: ($0.Genre ?? []).compactMap(\.tag), styles: ($0.Style ?? []).compactMap(\.tag))
        }
        let missing = albums.indices.filter {
            albums[$0].imprint != nil && albums[$0].genres.isEmpty && albums[$0].styles.isEmpty
        }
        let details = try await tagDetails(for: missing.map { albums[$0].id }, on: server)
        for i in missing {
            if let row = details[albums[i].id] {
                albums[i].genres = (row.Genre ?? []).compactMap(\.tag)
                albums[i].styles = (row.Style ?? []).compactMap(\.tag)
            }
        }
        let untagged = missing.filter {
            albums[$0].genres.isEmpty && albums[$0].styles.isEmpty &&
            albums[$0].artist.caseInsensitiveCompare("Various Artists") != .orderedSame
        }
        let artists = try await tagDetails(for: untagged.compactMap { albums[$0].artistID }, on: server)
        for i in untagged {
            if let id = albums[i].artistID, let row = artists[id] {
                albums[i].artistTags = ((row.Genre ?? []) + (row.Style ?? [])).compactMap(\.tag)
            }
        }
        return albums
    }

    private func tagDetails(for keys: [String], on server: PlexServer) async throws -> [String: AlbumRow] {
        let keys = Set(keys.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }).sorted()
        var byID: [String: AlbumRow] = [:]
        for start in stride(from: 0, to: keys.count, by: 100) {
            try Task.checkCancellation()
            let ids = keys[start..<min(start + 100, keys.count)]
            let url = try server.url(for: "/library/metadata/" + ids.joined(separator: ",")).appending(queryItems: [
                URLQueryItem(name: "includeElements", value: "Genre,Style")
            ])
            do {
                let page = try await albumPage(request(url, token: server.token))
                for row in page.Metadata ?? [] { byID[row.ratingKey.value] = row }
            } catch {
                try Task.checkCancellation()
                // Genre enrichment is optional. A failed batch must not discard the library.
                connectionLog.notice("Could not enrich one album metadata batch")
            }
        }
        return byID
    }

    func tracks(album: Album, on server: PlexServer) async throws -> [Track] {
        try await items("/library/metadata/\(album.id)/children", on: server) { request in
            let envelope: PlexEnvelope<MetadataPage<TrackRow>> = try await decode(request)
            return envelope.MediaContainer
        }.map {
            Track(id: $0.ratingKey.value, title: $0.title, artist: $0.originalTitle ?? $0.grandparentTitle ?? album.artist,
                  disc: $0.parentIndex ?? 1, number: $0.index ?? 0, duration: Double($0.duration ?? 0) / 1000,
                  part: $0.Media?.first?.Part?.first?.key)
        }.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }
}
