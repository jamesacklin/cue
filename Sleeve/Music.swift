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
    let added: Int
    let thumb: String?
    var sampleArt: String? = nil
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
        Album(id: "sample-\(index)", title: record.0, artist: record.1, year: record.2,
              added: records.count - index, thumb: nil, sampleArt: "cover-\(index)")
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
