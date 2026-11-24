import AppKit
import Combine
import OSLog

@MainActor
final class LibraryStore: ObservableObject {
    private var firstPage: CatalogPage?
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

    let client: PlexClient
    let player = Player()
    private let log = Logger(subsystem: "org.sleeveplayer.Minimal", category: "PlexConnection")
    private var token: String?
    private var job: Task<Void, Never>?
    private var albumPlayback: Task<Void, Never>?
    private var didRestore = false
    private let defaults: UserDefaults

    init(client: PlexClient? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let id = defaults.string(forKey: "clientID") ?? UUID().uuidString
        defaults.set(id, forKey: "clientID")
        self.client = client ?? PlexClient(identifier: id)
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        do {
            token = try Credentials.plex.read()
            signedIn = token != nil
            log.notice("Restored account credential: \(self.signedIn, privacy: .public)")
            if signedIn { discover(restoreSelection: true) }
        } catch {
            connectionError = error.localizedDescription
            showConnection = true
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
        if server?.id != source.id || section?.id != selected.id { player.reset() }
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
        player.reset()
        connectionError = nil
        revision += 1
        showConnection = false
    }

    func tracks(for album: Album) async throws -> [Track] {
        guard let server else { return [] }
        return try await client.tracks(album: album, on: server)
    }

    func catalog(_ kind: Catalog, query: String, offset: Int, artistID: String?, order: AlbumOrder) async throws -> CatalogPage {
        if let server, let section {
            if kind == .albums, order == .title, query.isEmpty, offset == 0, artistID == nil, let firstPage {
                self.firstPage = nil
                return firstPage
            }
            firstPage = nil
            return try await client.page(kind, section: section, on: server, query: query, offset: offset, artistID: artistID, order: order)
        }
        return CatalogPage(rows: [], total: 0, next: nil)
    }

    func clearQueue() {
        albumPlayback?.cancel()
        albumPlayback = nil
        player.reset()
    }

    func selectQueuedTrack(_ index: Int) {
        albumPlayback?.cancel()
        albumPlayback = nil
        player.select(index)
    }

    func playAlbum(_ album: Album, startingAt id: String? = nil) {
        albumPlayback?.cancel()
        let requestedRevision = revision
        albumPlayback = Task {
            do {
                let tracks = try await tracks(for: album)
                guard !Task.isCancelled, revision == requestedRevision else { return }
                guard let first = tracks.first(where: { $0.part != nil }) else {
                    player.error = "There are no playable tracks on this album."
                    return
                }
                play(tracks, from: id ?? first.id, album: album)
            } catch {
                if !Task.isCancelled, revision == requestedRevision { player.error = error.localizedDescription }
            }
        }
    }

    func play(_ tracks: [Track], from id: String, album: Album) {
        albumPlayback?.cancel()
        albumPlayback = nil
        let entries = tracks.compactMap { track -> QueueEntry? in
            guard let url = try? server?.stream(for: track) else { return nil }
            return QueueEntry(track: track, album: album, url: url)
        }
        guard let index = entries.firstIndex(where: { $0.track.id == id }) else {
            player.error = "There is no playable file for this track."
            return
        }
        player.replace(entries, startingAt: index)
    }
}
