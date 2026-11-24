import Foundation
import OSLog

struct ImprintOrder {
    let lanes: [String]
    let neighborhood: [String: String]
    private typealias Vector = [String: Double]

    init(albums: [Album]) {
        var tagsByLabel: [String: Vector] = [:]
        var spelling: [String: String] = [:]
        var labelsByArtist: [String: Set<String>] = [:]
        var sizes: [String: Int] = [:]
        for album in albums {
            guard let label = album.imprint else { continue }
            sizes[label, default: 0] += 1
            if let artist = album.routeID, album.artist.caseInsensitiveCompare("Various Artists") != .orderedSame {
                labelsByArtist[artist, default: []].insert(label)
            }
            var tags = Set<String>()
            let direct = album.genres + album.styles
            let weight = direct.isEmpty ? 0.5 : 1.0
            for value in direct.isEmpty ? album.artistTags : direct {
                let display = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !display.isEmpty else { continue }
                let key = display.lowercased()
                spelling[key] = min(display, spelling[key] ?? display)
                tags.insert(key)
            }
            // Split one album's vote across its tags so dense tagging doesn't dominate.
            for tag in tags {
                tagsByLabel[label, default: [:]][tag, default: 0] += weight / Double(tags.count)
            }
        }
        let seeds = sizes.keys.sorted {
            sizes[$0] == sizes[$1] ? $0 < $1 : sizes[$0, default: 0] > sizes[$1, default: 0]
        }
        var df: [String: Int] = [:]
        for tags in tagsByLabel.values {
            for tag in tags.keys { df[tag, default: 0] += 1 }
        }
        let profiles = tagsByLabel.mapValues { tags in
            var weighted = Vector()
            for (tag, count) in tags {
                let idf = 1 + log(Double(1 + tagsByLabel.count) / Double(1 + df[tag, default: 0]))
                weighted[tag] = count * idf
            }
            return Self.normalized(weighted)
        }
        let (groups, centers) = Self.cluster(seeds.filter { profiles[$0] != nil }, profiles)
        let names = centers.map { center in
            center.keys.sorted {
                let a = Self.rank(center[$0, default: 0]), b = Self.rank(center[$1, default: 0])
                return a == b ? $0 < $1 : a > b
            }.prefix(3).map { spelling[$0] ?? $0 }.joined(separator: " · ")
        }
        neighborhood = groups.mapValues { names[$0] }

        var artistsByLabel: [String: [String]] = [:]
        for (artist, linked) in labelsByArtist where linked.count > 1 {
            for label in linked { artistsByLabel[label, default: []].append(artist) }
        }
        var members: [Int: Set<String>] = [:]
        for (label, group) in groups { members[group, default: []].insert(label) }
        // Walk nearby centroids when starting a fresh chain, so neighboring
        // groups can still share a boundary even without an artist crossover.
        var pending = Set(groups.values)
        var clusteredSeeds: [String] = []
        var group = seeds.lazy.compactMap { groups[$0] }.first
        while let current = group {
            pending.remove(current)
            clusteredSeeds += seeds.filter { groups[$0] == current }
            group = pending.min { a, b in
                let left = Self.rank(Self.dot(centers[current], centers[a]))
                let right = Self.rank(Self.dot(centers[current], centers[b]))
                return left == right ? a < b : left > right
            }
        }
        var remaining = Set(seeds)
        var order: [String] = []
        // Start tagged neighborhoods first. Preserve strong roster bridges even across clusters.
        for seed in clusteredSeeds + seeds.filter({ groups[$0] == nil }) where remaining.contains(seed) {
            var next: String? = seed
            while let label = next {
                order.append(label)
                remaining.remove(label)
                if let group = groups[label] { members[group]?.remove(label) }
                var roster: [String: Int] = [:]
                for artist in artistsByLabel[label] ?? [] {
                    let linked = labelsByArtist[artist] ?? []
                    let weight = max(1, 1024 / (linked.count - 1))
                    for other in linked where remaining.contains(other) { roster[other, default: 0] += weight }
                }
                let candidates = roster.isEmpty ? (groups[label].flatMap { members[$0] } ?? []) : Set(roster.keys)
                var best: (artist: Int, affinity: Int, name: String)?
                next = nil
                for other in candidates {
                    let score = roster[other, default: 0]
                    let affinity = Self.rank(Self.dot(profiles[label] ?? [:], profiles[other] ?? [:]))
                    if let best {
                        if score < best.artist { continue }
                        if score == best.artist && affinity < best.affinity { continue }
                        if score == best.artist && affinity == best.affinity && other >= best.name { continue }
                    }
                    best = (score, affinity, other)
                    next = other
                }
            }
        }
        lanes = order
        let logger = Logger(subsystem: "org.sleeveplayer.Sleeve", category: "ImprintMap")
        logger.notice("Clustered \(groups.count, privacy: .public) of \(sizes.count, privacy: .public) imprints into \(Set(groups.values).count, privacy: .public) genre neighborhoods")

    }

    private static func normalized(_ v: Vector) -> Vector {
        let length = sqrt(v.values.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? v.mapValues { $0 / length } : [:]
    }

    private static func dot(_ a: Vector, _ b: Vector) -> Double {
        a.reduce(0) { $0 + $1.value * b[$1.key, default: 0] }
    }

    // Quantization stabilizes ties across dictionary iteration orders.
    private static func rank(_ score: Double) -> Int { Int((score * 1_000_000).rounded()) }

    private static func cluster(_ labels: [String], _ profiles: [String: Vector]) -> ([String: Int], [Vector]) {
        guard let first = labels.first, let initial = profiles[first] else { return ([:], []) }
        let target = min(labels.count, 18, max(2, Int(sqrt(Double(labels.count) / 2).rounded())))
        var centers = [initial]
        var nearest = Array(repeating: -1, count: labels.count)
        while centers.count < target {
            let last = centers[centers.count - 1]
            for i in labels.indices {
                nearest[i] = max(nearest[i], rank(dot(profiles[labels[i]] ?? [:], last)))
            }
            guard let i = nearest.indices.min(by: { nearest[$0] < nearest[$1] }), nearest[i] < 999_999 else { break }
            centers.append(profiles[labels[i]] ?? [:])
        }

        // Lloyd iterations on the unit sphere: assign by cosine, sum profiles, normalize.
        var groups: [String: Int] = [:]
        for _ in 0..<24 {
            var changed = false
            var sums = Array(repeating: Vector(), count: centers.count)
            for label in labels {
                guard let v = profiles[label] else { continue }
                var best = 0, bestScore = -1
                for i in centers.indices {
                    let score = rank(dot(v, centers[i]))
                    if score > bestScore { best = i; bestScore = score }
                }
                if groups[label] != best { changed = true }
                groups[label] = best
                for (tag, weight) in v { sums[best][tag, default: 0] += weight }
            }
            if !changed { break }
            for i in centers.indices where !sums[i].isEmpty { centers[i] = normalized(sums[i]) }
        }
        return (groups, centers)
    }
}
