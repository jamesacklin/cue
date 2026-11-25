import AppKit
import Combine
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    enum QueueAction {
        case append, replace
    }

    private struct QueueRequest {
        let row: MusicRow
        let action: QueueAction
        let albumTracks: [Track]?
    }

    private var firstPage: CatalogPage?
    private var trackArtistIndex: TrackArtistIndex?
    @Published private(set) var server: PlexServer?
    @Published private(set) var section: LibrarySection?
    @Published private(set) var signedIn = false
    @Published private(set) var resources: [PlexResource] = []
    @Published private(set) var proposedServer: PlexServer?
    @Published private(set) var sections: [LibrarySection] = []
    @Published private(set) var activity: String?
    @Published var connectionError: String?
    @Published var showConnection = false
    @Published private(set) var revision = 0

    private lazy var client = PlexClient(identifier: clientID)
    private let clientID: String
    let player: Player
    private let log = Logger(subsystem: "org.cueplayer.Minimal", category: "PlexConnection")
    private var token: String?
    private var job: Task<Void, Never>?
    private var queueJob: Task<Void, Never>?
    private var queueRequests: [QueueRequest] = []
    private var didRestore = false
    let defaults: UserDefaults

    init(client: PlexClient? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        player = Player(defaults: defaults)
        if let saved = defaults.string(forKey: "clientID") { clientID = saved }
        else {
            clientID = UUID().uuidString
            defaults.set(clientID, forKey: "clientID")
        }
        if let client { self.client = client }
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        perform("Restoring account…") { [self] in
            let saved = try await Credentials.plex.readForRestoration()
            try Task.checkCancellation()
            token = saved
            signedIn = saved != nil
            log.notice("Restored account credential: \(self.signedIn, privacy: .public)")
            if signedIn {
                activity = "Finding servers…"
                try await loadResources(restoreSelection: true)
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        activity = nil
    }

    private func perform(_ label: String, work: @escaping () async throws -> Void) {
        cancel()
        activity = label
        connectionError = nil
        job = Task {
            do { try await work() }
            catch {
                guard !Task.isCancelled else { return }
                // Activity can include a server name. Keep only the phase in diagnostics.
                let phase = activity?.components(separatedBy: " ").first ?? "connection"
                log.error("Connection failed during \(phase, privacy: .public), code \((error as NSError).code, privacy: .public)")
                connectionError = error.localizedDescription
                showConnection = true
            }
            if !Task.isCancelled { activity = nil }
        }
    }

    func signIn() {
        perform("Opening Plex sign-in…") { [self] in
            let pin = try await client.createPin()
            try Task.checkCancellation()
            guard NSWorkspace.shared.open(client.authorizationURL(pin)) else {
                throw MusicError("Couldn’t open the browser. Check your default browser and try again.")
            }
            activity = "Waiting for browser sign-in…"
            let value = try await client.poll(pin)
            try Task.checkCancellation()
            activity = "Saving account credential…"
            try Credentials.plex.save(value)
            token = value
            signedIn = true
            activity = "Finding servers…"
            try await loadResources(restoreSelection: false)
        }
    }

    func discover(restoreSelection: Bool = false) {
        perform("Finding servers…") { try await self.loadResources(restoreSelection: restoreSelection) }
    }

    private func loadResources(restoreSelection: Bool) async throws {
        guard let token else { throw MusicError("Sign in to Plex to find your servers.") }
        let list = try await client.resources(token: token)
        try Task.checkCancellation()
        log.notice("Server discovery completed: \(list.count, privacy: .public) available")
        resources = list
        proposedServer = nil
        sections = []
        guard restoreSelection else { return }
        if let selected = list.first(where: { $0.id == defaults.string(forKey: "serverID") }) {
            try await loadSections(selected)
            if let target = sections.first(where: { $0.id == defaults.string(forKey: "sectionID") }),
               let proposedServer {
                try await loadAlbums(target, from: proposedServer)
                return
            }
        }
        showConnection = true
    }

    func choose(_ resource: PlexResource) {
        perform("Connecting to \(resource.name)…") { try await self.loadSections(resource) }
    }

    private func loadSections(_ resource: PlexResource) async throws {
        proposedServer = nil
        sections = []
        let (connected, libraries) = try await client.connect(resource)
        try Task.checkCancellation()
        proposedServer = connected
        log.notice("Connected to server: \(libraries.count, privacy: .public) music sections")
        sections = libraries
    }

    func choose(_ section: LibrarySection) {
        guard let proposedServer else { return }
        perform("Loading \(section.title)…") { try await self.loadAlbums(section, from: proposedServer) }
    }

    private func loadAlbums(_ selected: LibrarySection, from source: PlexServer) async throws {
        let records = try await client.page(.albums, section: selected, on: source, query: "", offset: 0)
        try Task.checkCancellation()
        cancelQueueRequests()
        if server?.id != source.id || section?.id != selected.id { player.reset() }
        invalidateTrackArtistIndex()
        server = source
        section = selected
        firstPage = records
        defaults.set(source.id, forKey: "serverID")
        defaults.set(selected.id, forKey: "sectionID")
        revision += 1
        showConnection = false
    }

    func signOut() {
        cancel()
        do { try Credentials.plex.clear() }
        catch { connectionError = error.localizedDescription; return }
        invalidateTrackArtistIndex()
        token = nil
        signedIn = false
        server = nil
        section = nil
        proposedServer = nil
        resources = []
        sections = []
        defaults.removeObject(forKey: "serverID")
        defaults.removeObject(forKey: "sectionID")
        firstPage = nil
        clearQueue()
        connectionError = nil
        revision += 1
        showConnection = false
    }

    func invalidateTrackArtistIndex() { trackArtistIndex = nil }

    func tracks(for album: Album) async throws -> [Track] {
        guard let server else { return [] }
        return try await client.tracks(album: album, on: server)
    }

    func catalog(_ kind: Catalog, query: String, offset: Int, artistID: String?, order: CatalogOrder) async throws -> CatalogPage {
        if let server, let section {
            if kind == .albums, order == .standard(for: .albums), query.isEmpty, offset == 0, artistID == nil, let firstPage {
                self.firstPage = nil
                return firstPage
            }
            firstPage = nil
            if kind == .tracks, order.field == .artist, trackArtistIndex == nil {
                trackArtistIndex = try TrackArtistIndex()
            }
            return try await client.page(kind, section: section, on: server, query: query, offset: offset,
                                         artistID: artistID, order: order, trackArtistIndex: artistID == nil ? trackArtistIndex : nil)
        }
        return CatalogPage(rows: [], total: 0, next: nil)
    }

    func clearQueue() {
        cancelQueueRequests()
        player.reset()
    }

    var canClearQueue: Bool { player.current != nil || queueJob != nil }

    func selectQueuedTrack(_ id: UUID) {
        guard let index = player.queue.firstIndex(where: { $0.id == id }) else { return }
        if queueRequests.first?.action == .replace {
            queueJob?.cancel()
            queueJob = nil
            queueRequests.removeFirst()
            loadQueueRequests()
        }
        player.select(index - player.queue.startIndex)
    }

    func enqueue(_ row: MusicRow, action: QueueAction, albumTracks: [Track]? = nil) {
        guard server != nil, section != nil else { return }
        if action == .replace { cancelQueueRequests() }
        queueRequests.append(QueueRequest(row: row, action: action, albumTracks: albumTracks))
        loadQueueRequests()
    }

    private func cancelQueueRequests() {
        queueJob?.cancel()
        queueJob = nil
        queueRequests.removeAll()
    }

    private func loadQueueRequests() {
        guard queueJob == nil, !queueRequests.isEmpty, let server, let section else { return }
        queueJob = Task {
            while let request = queueRequests.first {
                do {
                    let (entries, index) = try await Self.queueEntries(for: request, on: server, in: section, client: client)
                    try Task.checkCancellation()
                    if request.action == .append { player.append(entries) }
                    else { player.replace(entries, startingAt: index) }
                } catch {
                    guard !Task.isCancelled else { return }
                    player.error = error.localizedDescription
                }
                queueRequests.removeFirst()
            }
            queueJob = nil
        }
    }

    @concurrent
    private static func queueEntries(for request: QueueRequest, on server: PlexServer, in section: LibrarySection,
                                     client: PlexClient) async throws -> ([QueueEntry], Int) {
        func entries(_ tracks: [Track], album: Album) throws -> [QueueEntry] {
            try tracks.compactMap { track in
                try Task.checkCancellation()
                guard let url = try? server.stream(for: track) else { return nil }
                return QueueEntry(track: track, album: album, url: url)
            }
        }

        var result: [QueueEntry] = []
        switch request.row {
        case .track(let track, let album):
            let tracks: [Track]
            if request.action == .append || album.id.isEmpty { tracks = [track] }
            else if let cached = request.albumTracks { tracks = cached }
            else { tracks = try await client.tracks(album: album, on: server) }
            result = try entries(tracks, album: album)
            guard let index = result.firstIndex(where: { $0.track.id == track.id }) else {
                throw MusicError("There is no playable file for this track.")
            }
            return (result, index)
        case .album(let album):
            let tracks: [Track]
            if let cached = request.albumTracks { tracks = cached }
            else { tracks = try await client.tracks(album: album, on: server) }
            result = try entries(tracks, album: album)
        case .artist(let id, _, _):
            var offset = 0
            var seen = Set<String>()
            while true {
                let page = try await client.page(.albums, section: section, on: server, query: "", offset: offset, artistID: id)
                let count = seen.count
                for case .album(let album) in page.rows where seen.insert(album.id).inserted {
                    let tracks = try await client.tracks(album: album, on: server)
                    result.append(contentsOf: try entries(tracks, album: album))
                }
                guard let next = page.next, seen.count > count else { break }
                offset = next
            }
        }
        guard !result.isEmpty else {
            throw MusicError("There are no playable tracks in this selection.")
        }
        return (result, 0)
    }
}
