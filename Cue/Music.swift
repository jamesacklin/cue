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
    var addedAt: Int? = nil
    var artistID: String? = nil
}

enum ArtistFilter: Equatable {
    case id(String), name(String)
}

struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let disc: Int
    let number: Int
    let duration: Double
    let part: String?
}

struct QueueEntry: Identifiable, Hashable {
    let id = UUID()
    let track: Track
    let album: Album
    let url: URL
}

extension ArraySlice where Element == QueueEntry {
    // Table positions are zero-based even after playback advances the slice.
    subscript(position offset: Int) -> QueueEntry { self[startIndex + offset] }
}

struct MusicError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func timeLabel(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    let remainder = value % 60
    return "\(value / 60):\(remainder < 10 ? "0" : "")\(remainder)"
}

struct CatalogOrder: Equatable {
    enum Field: String {
        case album = "Album", artist = "Artist", track = "Track", year = "Year", recent = "Date Added"
        case disc = "Disc", number = "No.", duration = "Time", albumArtist = "Album Artist", position = "Queue Position"
    }
    let field: Field
    var ascending = true

    static func standard(for catalog: Catalog, withinArtist: Bool = false) -> Self {
        switch catalog {
        case .albums: Self(field: withinArtist ? .year : .artist)
        case .artists: Self(field: .artist)
        case .tracks: Self(field: .track)
        }
    }

    func plexSort(for catalog: Catalog, withinArtist: Bool) -> String {
        let primary: String
        switch field {
        case .album: primary = "album.titleSort"
        case .artist:
            precondition(catalog != .tracks, "Track artists are sorted by their displayed credit")
            primary = "artist.titleSort"
        case .albumArtist: primary = "artist.titleSort"
        case .track: primary = "titleSort"
        case .year: primary = "album.year"
        case .recent: primary = catalog == .artists ? "artist.addedAt" : "album.addedAt"
        case .disc, .number: primary = "track.absoluteIndex"
        case .duration: primary = "track.duration"
        case .position: preconditionFailure("Queue positions are sorted locally")
        }
        let direction = ascending ? "" : ":desc"
        if catalog == .albums && field == .artist && !withinArtist {
            return primary + direction + ",album.year,album.titleSort,album.id"
        }
        var keys = [primary + direction]
        if field == .number { keys.append("track.index" + direction) }
        if field == .year || ((field == .artist || field == .albumArtist) && catalog != .artists) {
            keys.append("album.titleSort")
        }
        if catalog == .tracks && field != .track {
            keys.append("album.id")
            if field != .disc && field != .number { keys.append("track.absoluteIndex") }
            if field != .number { keys.append("track.index") }
        } else if field == .year {
            keys.append("album.id")
        }
        return keys.joined(separator: ",")
    }
}

/// Natural order needs only a count, even for a very large queue.
enum TrackIndices: RandomAccessCollection {
    case natural(count: Int, reversed: Bool)
    case ordered([Int])

    var startIndex: Int { 0 }
    var endIndex: Int {
        switch self {
        case .natural(let count, _): count
        case .ordered(let indices): indices.count
        }
    }
    subscript(position: Int) -> Int {
        switch self {
        case .natural(let count, let reversed): reversed ? count - 1 - position : position
        case .ordered(let indices): indices[position]
        }
    }
}

extension CatalogOrder {
    /// Album tracks arrive in disc/track order. Queue offsets distinguish duplicate tracks.
    @concurrent
    func sortedTrackIndices(count: Int, matching query: String, albumInTrackOrder: Bool = false,
                            entry: @Sendable (Int) -> (Track, Album)) async throws -> TrackIndices {
        let alreadyOrdered = field == .position || (albumInTrackOrder && field == .number && ascending)
        if alreadyOrdered && query.isEmpty { return .natural(count: count, reversed: !ascending) }
        var indices: [Int]
        if query.isEmpty {
            indices = Array(0..<count)
        } else {
            indices = try (0..<count).filter { index in
                if index.isMultiple(of: 128) { try Task.checkCancellation() }
                let (track, album) = entry(index)
                return MusicRow.track(track, album).matches(query)
            }
        }
        if alreadyOrdered {
            if !ascending { indices.reverse() }
            return .ordered(indices)
        }
        var comparisons = 0
        try indices.sort { left, right in
            comparisons += 1
            if comparisons.isMultiple(of: 256) { try Task.checkCancellation() }
            let (a, b) = ascending ? (entry(left), entry(right)) : (entry(right), entry(left))
            switch field {
            case .disc: return a.0.disc < b.0.disc
            case .number: return (a.0.disc, a.0.number) < (b.0.disc, b.0.number)
            case .duration: return a.0.duration < b.0.duration
            case .year: return (a.1.year ?? 0) < (b.1.year ?? 0)
            default:
                let lhs = MusicRow.track(a.0, a.1).text(for: field, position: left)
                let rhs = MusicRow.track(b.0, b.1).text(for: field, position: right)
                return lhs != rhs && lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        }
        return .ordered(indices)
    }
}

enum Catalog: Int, CaseIterable {
    case albums, artists, tracks
    var title: String { ["Albums", "Artists", "Tracks"][rawValue] }
    var symbol: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "person.2"
        case .tracks: "music.note"
        }
    }
    var plexType: String { ["9", "8", "10"][rawValue] }
}

enum MusicRow {
    case album(Album)
    case artist(id: String, name: String, addedAt: Int? = nil)
    case track(Track, Album)

    var title: String {
        switch self {
        case .album(let album): album.title
        case .artist(_, let name, _): name
        case .track(let track, _): track.title
        }
    }

    func text(for field: CatalogOrder.Field, position: Int) -> String {
        switch self {
        case .artist(_, let name, let addedAt):
            return field == .recent ? Self.dateLabel(addedAt) : name
        case .album(let album):
            switch field {
            case .artist: return album.artist
            case .year: return album.year.map(String.init) ?? ""
            case .recent: return Self.dateLabel(album.addedAt)
            default: return album.title
            }
        case .track(let track, let album):
            switch field {
            case .artist: return track.artist
            case .albumArtist: return album.artist
            case .album: return album.title
            case .year: return album.year.map(String.init) ?? ""
            case .duration: return timeLabel(track.duration)
            case .disc: return String(track.disc)
            case .number:
                guard track.number > 0 else { return "" }
                return track.disc > 1 ? "\(track.disc).\(track.number)" : String(track.number)
            case .position: return String(position + 1)
            default: return track.title
            }
        }
    }

    private static func dateLabel(_ timestamp: Int?) -> String {
        guard let timestamp else { return "" }
        return Date(timeIntervalSince1970: Double(timestamp)).formatted(date: .abbreviated, time: .omitted)
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
    static let capacity = 50
    let rows: [MusicRow]
    let total: Int?
    let next: Int?
}

/// Absolute table indexes stay stable as metadata moves into and out of memory.
struct CatalogRows {
    private(set) var cached: [Int: MusicRow] = [:]
    private(set) var count = 0
    private(set) var total: Int?

    mutating func insert(_ page: CatalogPage, at offset: Int, near visible: Range<Int>, selected: Int) {
        let end = offset + page.rows.count
        if page.next == nil {
            total = min(page.total ?? end, end)
        } else if let reported = page.total {
            total = reported
        }
        // Without a total, one extra row lets scrolling discover the next batch.
        count = total ?? max(count, end + 1)
        let margin = CatalogPage.capacity
        let keep = max(0, visible.lowerBound - margin)..<(visible.upperBound + margin)
        cached = cached.filter { $0.key < count && (keep.contains($0.key) || $0.key == selected) }
        for (index, row) in page.rows.enumerated() where offset + index < count {
            cached[offset + index] = row
        }
    }

    func neededOffset(for visible: Range<Int>) -> Int? {
        guard !visible.isEmpty, visible.lowerBound < count else { return nil }
        // Start the next request just before the user reaches an unloaded row.
        let wanted = visible.lowerBound..<min(count, visible.upperBound + 8)
        guard let missing = wanted.first(where: { cached[$0] == nil }) else { return nil }
        let start = missing - missing % CatalogPage.capacity
        return (start...missing).first { cached[$0] == nil }
    }
}
