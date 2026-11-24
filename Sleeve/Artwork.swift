import AppKit
import SwiftUI

enum CoverCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    @MainActor static func load(_ album: Album, library: LibraryStore) async -> NSImage? {
        guard let server = library.server, let path = album.thumb,
              (try? server.url(for: path)) != nil else { return nil }
        let key = [server.id, path].joined(separator: "|") as NSString
        if let cached = CoverCache.shared.object(forKey: key) { return cached }
        guard let url = try? server.url(for: "/photo/:/transcode").appending(queryItems: [
            URLQueryItem(name: "url", value: path), URLQueryItem(name: "width", value: "480"),
            URLQueryItem(name: "height", value: "480"), URLQueryItem(name: "minSize", value: "1")
        ]) else { return nil }
        var req = library.client.request(url, token: server.token)
        req.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await library.client.session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = NSImage(data: data), !Task.isCancelled else { return nil }
        CoverCache.shared.setObject(image, forKey: key, cost: 480 * 480 * 4)
        return image
    }
}

struct Artwork: View {
    let album: Album
    @EnvironmentObject private var library: LibraryStore
    @State private var remote: NSImage?
    private var cacheKey: String { [library.server?.id, album.thumb].compactMap { $0 }.joined(separator: "|") }

    var body: some View {
        Rectangle().fill(.secondary.opacity(0.09))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let name = album.sampleArt, let sample = NSImage(named: name) {
                    Image(nsImage: sample).resizable().scaledToFill()
                } else if let remote {
                    Image(nsImage: remote).resizable().scaledToFill()
                } else {
                    Image(systemName: "opticaldisc").resizable().scaledToFit()
                        .scaleEffect(0.40).foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
            .task(id: cacheKey) {
                remote = nil
                remote = await CoverCache.load(album, library: library)
            }
    }
}

extension Color {
    static let sleeveAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.63, blue: 0.30, alpha: 1)
            : NSColor(red: 0.62, green: 0.26, blue: 0.06, alpha: 1)
    })
}

struct RecordMark: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.sleeveAccent)
            ForEach([0.78, 0.65, 0.52], id: \.self) { ratio in
                Circle().stroke(.background.opacity(0.55), lineWidth: 0.8).scaleEffect(ratio)
            }
            Circle().fill(.background).scaleEffect(0.31)
            Circle().fill(Color.sleeveAccent).scaleEffect(0.09)
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}
