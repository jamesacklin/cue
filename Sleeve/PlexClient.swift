import Foundation
import OSLog

private let connectionLog = Logger(subsystem: "org.sleeveplayer.Minimal", category: "PlexConnection")

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
    let offset: Int?
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

private struct MusicMetadata: Decodable {
    let ratingKey: PlexKey
    let title: String?
    let parentRatingKey: PlexKey?
    let parentTitle: String?
    let grandparentTitle: String?
    let originalTitle: String?
    let year: Int?
    let parentIndex: Int?
    let index: Int?
    let duration: Int?
    let Media: [MediaItem]?

    struct MediaItem: Decodable {
        let Part: [PartItem]?
        struct PartItem: Decodable { let key: String? }
    }

    init(xml: XMLElement) throws {
        func field(_ name: String) -> String? { xml.attribute(forName: name)?.stringValue }
        guard let id = field("ratingKey") else { throw MusicError("Plex returned an item without an identifier.") }
        ratingKey = PlexKey(id)
        title = field("title")
        parentRatingKey = field("parentRatingKey").map(PlexKey.init)
        parentTitle = field("parentTitle")
        grandparentTitle = field("grandparentTitle")
        originalTitle = field("originalTitle")
        year = field("year").flatMap(Int.init)
        parentIndex = field("parentIndex").flatMap(Int.init)
        index = field("index").flatMap(Int.init)
        duration = field("duration").flatMap(Int.init)
        Media = xml.elements(forName: "Media").map { media in
            MediaItem(Part: media.elements(forName: "Part").map {
                MediaItem.PartItem(key: $0.attribute(forName: "key")?.stringValue)
            })
        }
    }

    func row(_ catalog: Catalog, parent: Album?) -> MusicRow {
        switch catalog {
        case .artists: return .artist(id: ratingKey.value, name: title ?? "Unknown Artist")
        case .albums:
            return .album(Album(id: ratingKey.value, title: title ?? "Untitled album",
                                artist: parentTitle ?? "Unknown Artist", year: year))
        case .tracks:
            let album = parent ?? Album(id: parentRatingKey?.value ?? "", title: parentTitle ?? "Unknown album",
                                        artist: grandparentTitle ?? "Unknown Artist", year: nil)
            let track = Track(id: ratingKey.value, title: title ?? "Untitled track",
                              artist: originalTitle ?? grandparentTitle ?? album.artist, disc: parentIndex ?? 1,
                              number: index ?? 0, duration: Double(duration ?? 0) / 1000, part: Media?.first?.Part?.first?.key)
            return .track(track, album)
        }
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    func request(_ url: URL, token: String? = nil) -> URLRequest {
        var result = URLRequest(url: url, timeoutInterval: 15)
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        result.setValue("Cue", forHTTPHeaderField: "X-Plex-Product")
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
            throw MusicError("Cue couldn’t read Plex’s \(location).")
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
            URLQueryItem(name: "context[device][product]", value: "Cue")
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

    private func metadata(_ request: URLRequest, kind: Catalog) async throws -> MetadataPage<MusicMetadata> {
        let data = try await responseData(request)
        if let page = try? JSONDecoder().decode(PlexEnvelope<MetadataPage<MusicMetadata>>.self, from: data) {
            return page.MediaContainer
        }
        // Some servers have library entries that cannot be serialized as valid JSON.
        var xmlRequest = request
        xmlRequest.setValue("application/xml", forHTTPHeaderField: "Accept")
        let document = try XMLDocument(data: await responseData(xmlRequest), options: .nodeLoadExternalEntitiesNever)
        guard let root = document.rootElement(), root.name == "MediaContainer" else {
            throw MusicError("Plex returned an unreadable list.")
        }
        let rows = try root.elements(forName: kind == .tracks ? "Track" : "Directory").map(MusicMetadata.init(xml:))
        guard !rows.isEmpty || root.attribute(forName: "size")?.stringValue == "0" else {
            throw MusicError("Plex returned an unexpected library entry.")
        }
        func integer(_ name: String) -> Int? { root.attribute(forName: name)?.stringValue.flatMap(Int.init) }
        return MetadataPage(Metadata: rows, totalSize: integer("totalSize"), offset: integer("offset"))
    }

    func page(_ kind: Catalog, section: LibrarySection, on server: PlexServer, query: String, offset: Int,
              artistID: String? = nil, order: CatalogOrder? = nil) async throws -> CatalogPage {
        let sort = (order ?? .standard(for: kind)).plexSort(for: kind)
        var filters = [URLQueryItem(name: "type", value: kind.plexType), URLQueryItem(name: "sort", value: sort)]
        if let artistID { filters.append(URLQueryItem(name: "artist.id", value: artistID)) }
        if !query.isEmpty {
            // PMS combines fields with AND unless they are grouped explicitly with OR.
            let fields: [String]
            switch kind {
            case .artists: fields = ["artist.title"]
            case .albums: fields = ["album.title", "artist.title"]
            case .tracks: fields = ["track.title", "album.title", "artist.title"]
            }
            filters.append(URLQueryItem(name: "push", value: "1"))
            for (index, field) in fields.enumerated() {
                if index > 0 { filters.append(URLQueryItem(name: "or", value: "1")) }
                filters.append(URLQueryItem(name: field, value: query))
            }
            filters.append(URLQueryItem(name: "pop", value: "1"))
        }
        return try await readPage(kind, path: "/library/sections/\(section.key)/all", on: server,
                                  filters: filters, offset: offset)
    }

    private func readPage(_ kind: Catalog, path: String, on server: PlexServer, filters: [URLQueryItem],
                          offset: Int, parent: Album? = nil) async throws -> CatalogPage {
        // Request only the fields used in text rows and the first playable media part.
        let fields: String
        switch kind {
        case .artists: fields = "ratingKey,title"
        case .albums: fields = "ratingKey,title,parentTitle,year"
        case .tracks: fields = "ratingKey,title,parentRatingKey,parentTitle,grandparentTitle,originalTitle,parentIndex,index,duration,key"
        }
        let size = CatalogPage.capacity
        let url = try server.url(for: path).appending(queryItems: filters + [
            URLQueryItem(name: "includeFields", value: "size,offset,totalSize," + fields),
            URLQueryItem(name: "includeElements", value: kind == .tracks ? "Metadata,Media,Part" : "Metadata"),
            URLQueryItem(name: "X-Plex-Container-Start", value: String(offset)),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(size))
        ])
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        // PMS decodes query parameters as form data, where a literal plus means a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var pageRequest = request(components.url!, token: server.token)
        pageRequest.setValue("1.0", forHTTPHeaderField: "X-Plex-Pms-Api-Version")
        let result = try await metadata(pageRequest, kind: kind)
        try Task.checkCancellation()
        let batch = result.Metadata ?? []
        // Older endpoints may ignore pagination and return the complete list.
        let start = result.offset ?? (batch.count > size ? 0 : offset)
        guard start <= offset else { throw MusicError("Plex skipped part of this listing. Refresh and try again.") }
        let slice = batch.dropFirst(offset - start).prefix(size)
        let end = offset + slice.count
        let total = result.totalSize ?? (batch.count > size ? start + batch.count : nil)
        let more = !slice.isEmpty && (total.map { end < $0 } ?? (slice.count == size))
        return CatalogPage(rows: slice.map { $0.row(kind, parent: parent) }, total: total, next: more ? end : nil)
    }

    func tracks(album: Album, on server: PlexServer) async throws -> [Track] {
        var tracks: [Track] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            let page = try await readPage(.tracks, path: "/library/metadata/\(album.id)/children", on: server,
                                          filters: [], offset: offset, parent: album)
            let count = tracks.count
            for case .track(let track, _) in page.rows where seen.insert(track.id).inserted { tracks.append(track) }
            guard let next = page.next, tracks.count > count else { break }
            offset = next
        }
        return tracks.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
    }
}
