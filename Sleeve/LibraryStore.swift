import AppKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums = Sample.albums
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
    private var token: String?
    private var job: Task<Void, Never>?
    private var didRestore = false
    private let defaults = UserDefaults.standard

    init() {
        let id = defaults.string(forKey: "clientID") ?? UUID().uuidString
        defaults.set(id, forKey: "clientID")
        client = PlexClient(identifier: id)
    }

    func restore() {
        guard !didRestore else { return }
        didRestore = true
        do {
            token = try Credentials.plex.read()
            signedIn = token != nil
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
        sections = libraries
    }

    func choose(_ section: LibrarySection) {
        guard let proposedServer else { return }
        perform("Loading \(section.title)…") { try await self.loadAlbums(section, from: proposedServer) }
    }

    func refresh() {
        guard let server, let section else { return }
        perform("Refreshing albums…") { try await self.loadAlbums(section, from: server) }
    }

    private func loadAlbums(_ selected: LibrarySection, from source: PlexServer) async throws {
        let records = try await client.albums(section: selected, on: source)
        try Task.checkCancellation()
        if server?.id != source.id || section?.id != selected.id { player.reset() }
        server = source
        section = selected
        albums = records
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
        albums = Sample.albums
        player.reset()
        CoverCache.shared.removeAllObjects()
        connectionError = nil
        revision += 1
        showConnection = false
    }

    func tracks(for album: Album) async throws -> [Track] {
        if let server { return try await client.tracks(album: album, on: server) }
        return Sample.tracks(for: album)
    }

    func play(_ tracks: [Track], from id: String, album: Album) {
        let entries = tracks.compactMap { track -> QueueEntry? in
            guard let url = track.localFile ?? (try? server?.stream(for: track)) else { return nil }
            return QueueEntry(track: track, album: album, url: url)
        }
        guard let index = entries.firstIndex(where: { $0.track.id == id }) else {
            player.error = "There is no playable file for this track."
            return
        }
        player.replace(entries, startingAt: index)
    }
}
