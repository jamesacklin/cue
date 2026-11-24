import Foundation

struct LibrarySection: Decodable, Identifiable, Hashable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
}

struct Album: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: Int?
}

struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let disc: Int
    let number: Int
    let duration: Double
    let part: String?
    var localFile: URL? = nil
}

struct QueueEntry: Identifiable, Hashable {
    let id = UUID()
    let track: Track
    let album: Album
    let url: URL
}

struct MusicError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

enum Sample {
    private static let records = [
        ("Night Architecture", "Static Assembly", 2025, ["Blue Hour", "The Upper Floor"]),
        ("Soft Focus", "Vale", 2024, ["Petal Study", "Warm Light"]),
        ("Parallel Motion", "Axis Trio", 2025, ["Counterpoint", "In Transit"]),
        ("After Rain", "Mara Field", 2023, ["Understory", "Clearing"]),
        ("Contour", "Static Assembly", 2024, ["Isohyet", "Cross Section"]),
        ("Low Tide", "North Relay", 2022, ["Estuary", "Sea Glass"])
    ]

    static let albums: [Album] = records.enumerated().map { index, record in
        Album(id: "sample-\(index)", title: record.0, artist: record.1, year: record.2)
    }

    static func tracks(for album: Album) -> [Track] {
        guard let index = albums.firstIndex(where: { $0.id == album.id }) else { return [] }
        return records[index].3.enumerated().map { offset, title in
            let resource = "study-\(index)-\(offset)"
            return Track(id: resource, title: title, artist: album.artist, disc: 1,
                         number: offset + 1, duration: 24, part: nil,
                         localFile: Bundle.main.url(forResource: resource, withExtension: "m4a"))
        }
    }
}

enum AlbumOrder: Int, CaseIterable {
    case title, artist, recent
    var label: String { ["Album Title", "Artist Name", "Recently Added"][rawValue] }
    var plexSort: String { ["album.titleSort", "artist.titleSort,album.titleSort", "album.addedAt:desc"][rawValue] }
}

enum Catalog: Int, CaseIterable {
    case albums, artists, tracks
    var title: String { ["Albums", "Artists", "Tracks"][rawValue] }
    var plexType: String { ["9", "8", "10"][rawValue] }
}

enum MusicRow {
    case album(Album)
    case artist(id: String, name: String)
    case track(Track, Album)

    var title: String {
        switch self {
        case .album(let album): album.title
        case .artist(_, let name): name
        case .track(let track, _): track.title
        }
    }

    func matches(_ query: String) -> Bool {
        if query.isEmpty || title.localizedCaseInsensitiveContains(query) { return true }
        switch self {
        case .album(let album): return album.artist.localizedCaseInsensitiveContains(query)
        case .artist: return false
        case .track(let track, let album):
            return track.artist.localizedCaseInsensitiveContains(query) || album.title.localizedCaseInsensitiveContains(query)
        }
    }
}

struct CatalogPage {
    static let capacity = 100
    let rows: [MusicRow]
    let total: Int?
    let next: Int?
}

extension Sample {
    static func page(_ catalog: Catalog, query: String, offset: Int, artistID: String? = nil, order: AlbumOrder = .title) -> CatalogPage {
        let records = albums.filter { artistID == nil || $0.artist == artistID }
        let rows: [MusicRow]
        switch catalog {
        case .albums: rows = records.map(MusicRow.album)
        case .artists: rows = Set(records.map(\.artist)).map { .artist(id: $0, name: $0) }
        case .tracks: rows = records.flatMap { album in tracks(for: album).map { .track($0, album) } }
        }
        var filtered = rows.filter { $0.matches(query) }
        // The sample albums are stored in most-recently-added order.
        if catalog != .albums || order != .recent {
            filtered.sort { left, right in
                if catalog == .albums, order == .artist, case .album(let a) = left, case .album(let b) = right,
                   a.artist != b.artist { return a.artist.localizedStandardCompare(b.artist) == .orderedAscending }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
        }
        let slice = filtered.dropFirst(offset).prefix(CatalogPage.capacity)
        return CatalogPage(rows: Array(slice), total: filtered.count, next: slice.endIndex < filtered.count ? slice.endIndex : nil)
    }
}
