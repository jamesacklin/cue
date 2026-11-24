import SceneKit
import SwiftUI

enum MapDecade: Hashable {
    case all, years(Int), undated

    init(year: Int?) {
        self = year.map { .years($0 / 10 * 10) } ?? .undated
    }

    var title: String {
        switch self {
        case .all: "All decades"
        case .years(let start): "\(start)s"
        case .undated: "Undated"
        }
    }

    func matches(_ album: Album) -> Bool {
        self == .all || self == MapDecade(year: album.year)
    }
}

struct MapDestination: Equatable {
    let albumID: String
    let requestID = UUID()
}

struct TransitMap: View {
    let albums: [Album]
    let search: String
    let destination: MapDestination?
    let open: (Album) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imprintOrder: ImprintOrder?
    @State private var chronological: [Album] = []
    @State private var records: [Album] = []
    @State private var artistCounts: [String: Int] = [:]
    @State private var selectedID: String?
    @State private var decade = MapDecade.all
    @State private var decades: [MapDecade] = []

    @State private var route: String?
    @State private var renderedRoute: String?
    @State private var renderedImprint: String?
    @State private var routeName = ""
    @State private var imprint: String?
    @State private var overviewRequest = 0
    @State private var canResetView = false

    private var index: Int? { records.firstIndex { $0.id == selectedID } }
    private var selected: Album? { index.map { records[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            if !records.isEmpty, let imprintOrder {
                TransitScene(records: records, artistRoute: renderedRoute, imprint: renderedImprint, imprintOrder: imprintOrder, overviewRequest: overviewRequest,
                             destination: destination, focus: selected?.id, library: library, reduceMotion: reduceMotion,
                             cameraChanged: { canResetView = $0 }, choose: { id in
                                 selectedID = id
                             }, deselect: {
                                 selectedID = nil
                                 route = nil
                             }, followImprint: { imprint = $0 }, step: step, play: { id in
                                 if let album = records.first(where: { $0.id == id }) { library.playAlbum(album) }
                             }, inspect: { if let selected { open(selected) } })
                    .accessibilityLabel(selected.map { "Spatial album map, \($0.title), \($0.artist)" } ?? "Spatial album map")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 12) {
                    Spacer()
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0).accessibilityLabel("Previous station")
                    Text(selected == nil ? "\(records.count) albums" : "\((index ?? 0) + 1) / \(records.count)").font(.caption.monospacedDigit())
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == records.count - 1).accessibilityLabel("Next station")
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 10)
                Text("Scroll to zoom   ·   Drag to pan   ·   Years rise   ·   Imprints run across   ·   Scenes sit in depth   ·   Routes trace artist credits")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            } else if imprintOrder == nil && !albums.isEmpty {
                ProgressView("Mapping imprints…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(search.isEmpty ? "No albums" : "No matching albums", systemImage: "opticaldisc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .topTrailing) {
            if imprintOrder != nil {
                VStack(alignment: .trailing, spacing: 8) {
                    mapControls
                    if let selected, let imprintOrder {
                        AlbumMapInspector(album: selected,
                                          neighborhood: selected.imprint.flatMap { imprintOrder.neighborhood[$0] },
                                          artistCount: selected.routeID.flatMap { artistCounts[$0] } ?? 0,
                                          canFollow: route == nil && selected.routeID != nil,
                                          follow: { routeName = selected.artist; route = selected.routeID },
                                          open: { open(selected) })
                    }
                }.padding(.trailing, 12).padding(.top, records.isEmpty ? 12 : 38)
            }
        }
        .task {
            let result = await library.transitImprintOrder()
            if !Task.isCancelled { imprintOrder = result }
        }
        .onAppear {
            chronological = albums.sorted {
                if $0.year != $1.year { return ($0.year ?? Int.min) > ($1.year ?? Int.min) }
                if $0.artist != $1.artist { return $0.artist < $1.artist }
                return ($0.title, $0.id) < ($1.title, $1.id)
            }
            rebuild()
            if selectedID == nil { selectedID = records.first?.id }
        }
        .onChange(of: destination, initial: true) { _, target in
            if let target { selectedID = target.albumID }
        }
        .onChange(of: search) { _, _ in route = nil; rebuild() }
        .onChange(of: decade) { _, _ in rebuild(); overviewRequest += 1 }
        .onChange(of: route) { _, _ in rebuild() }
        .onChange(of: imprint) { _, next in
            rebuild()
            if next != nil { overviewRequest += 1 }
        }
    }

    private var mapControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if canResetView && !records.isEmpty {
                    Button { overviewRequest += 1 } label: {
                        Label("Reset view", systemImage: "arrow.counterclockwise")
                    }.help("Fit the currently visible collection")
                }
                Menu {
                    Picker("Decade", selection: $decade) {
                        Text(MapDecade.all.title).tag(MapDecade.all)
                        ForEach(decades, id: \.self) { item in Text(verbatim: item.title).tag(item) }
                    }.pickerStyle(.inline)
                } label: {
                    Label { Text(verbatim: decade.title) } icon: { Image(systemName: "line.3.horizontal.decrease") }
                }.fixedSize().help("Filter by release decade")
            }
            if let imprint {
                Button { self.imprint = nil } label: {
                    Label(imprint, systemImage: "xmark.circle").lineLimit(1)
                }.help("Clear imprint filter")
            }
            if route != nil {
                Button { route = nil } label: {
                    Label(routeName, systemImage: "xmark.circle").lineLimit(1)
                }.help("Clear artist filter")
            }
        }
        .controlSize(.small)
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 238, alignment: .trailing)
    }

    private func rebuild() {
        let query = search
        let matching = imprint == nil && query.isEmpty ? chronological : chronological.filter { (imprint == nil || $0.imprint == imprint) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) || $0.imprint?.localizedCaseInsensitiveContains(query) == true) }
        var seen = Set<MapDecade>()
        let artistMatches = route.map { id in matching.filter { $0.routeID == id } } ?? matching
        decades = artistMatches.map { MapDecade(year: $0.year) }.filter { seen.insert($0).inserted }
        if decade != .all && !decades.contains(decade) { decades.append(decade) }
        records = decade == .all ? artistMatches : artistMatches.filter(decade.matches)
        renderedRoute = route
        renderedImprint = imprint
        artistCounts = records.reduce(into: [:]) { counts, record in
            if let id = record.routeID { counts[id, default: 0] += 1 }
        }
    }

    private func step(_ delta: Int) {
        guard !records.isEmpty else { return }
        let next = index.map { min(max(0, $0 + delta), records.count - 1) } ?? 0
        selectedID = records[next].id
    }
}

private struct AlbumMapInspector: View {
    let album: Album
    let neighborhood: String?
    let artistCount: Int
    let canFollow: Bool
    let follow: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Artwork(album: album).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.headline).lineLimit(2)
                    Text(album.artist).lineLimit(2)
                    if let year = album.year { Text(String(year)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if let label = album.imprint { field("Imprint", label) }
                if !album.scenes.isEmpty { field("Scene", album.scenes.joined(separator: ", ")) }
                if !album.genres.isEmpty { field("Genre", album.genres.joined(separator: ", ")) }
                if let neighborhood { field("Label cluster", neighborhood) }
                if artistCount > 0 { field("Artist route", albumCount(artistCount)) }
            }.font(.caption)
            HStack {
                if canFollow {
                    Button("Follow artist", action: follow)
                }
                Spacer()
                Button("Open album", action: open)
            }.controlSize(.small)
        }
        .padding(12).frame(width: 238, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.16)) }
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Album inspector")
    }

    private func field(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
    }
}

private struct TransitScene: NSViewRepresentable {
    let records: [Album]
    let artistRoute: String?
    let imprint: String?
    let imprintOrder: ImprintOrder
    let overviewRequest: Int
    let destination: MapDestination?
    let focus: String?
    let library: LibraryStore
    let reduceMotion: Bool
    let cameraChanged: (Bool) -> Void
    let choose: (String) -> Void
    let deselect: () -> Void
    let followImprint: (String) -> Void
    let step: (Int) -> Void
    let play: (String) -> Void
    let inspect: () -> Void

    func makeNSView(context: Context) -> RailView { RailView(frame: .zero) }

    func updateNSView(_ view: RailView, context: Context) {
        view.choose = choose
        view.deselect = deselect
        view.followImprint = followImprint
        view.step = step
        view.play = play
        view.inspect = inspect
        view.cameraChanged = { [weak view] available in
            // Camera updates can originate inside updateNSView. Publish after SwiftUI settles.
            DispatchQueue.main.async {
                guard let view, view.cameraChanged != nil, view.canResetCamera == available else { return }
                cameraChanged(available)
            }
        }
        view.reduceMotion = reduceMotion
        let artistChanged = view.artistRoute != artistRoute
        let clearedFilter = (view.artistRoute != nil && artistRoute == nil) || (view.imprint != nil && imprint == nil)
        view.imprint = imprint
        view.artistRoute = artistRoute
        let changed = view.records != records
        if changed {
            view.populate(records, library: library, imprintOrder: imprintOrder, keepingAnchor: artistChanged || clearedFilter ? focus : nil, preservingViewport: clearedFilter)
        }
        if let destination, destination.albumID == focus,
           destination.requestID != view.lastDestination {
            view.lastDestination = destination.requestID
            view.overviewRequest = overviewRequest
            view.frameStation(destination.albumID, animate: false, distance: 20)
            return
        }
        if changed && clearedFilter, let focus {
            if view.focus != focus { view.highlightStation(focus) }
        } else if let focus, (changed && !artistChanged) || view.focus != focus {
            let first = view.focus.isEmpty && changed
            view.frameStation(focus, overview: first && records.count <= 12, animate: !first && !changed)
            if first && records.count > 12 { view.showOverview() }
        }
        if focus == nil {
            view.clearSelection()
            if changed && !clearedFilter { view.showOverview() }
        }
        if view.overviewRequest != overviewRequest {
            view.overviewRequest = overviewRequest
            view.showOverview()
        }
    }

    static func dismantleNSView(_ view: RailView, coordinator: ()) {
        view.cameraChanged = nil
        view.cancelImages()
    }
}

final class TransitMinimap: NSView {
    struct Drawing {
        let atlas: NSImage
        let extent: CGRect
    }

    var drawing: Drawing? {
        didSet {
            isHidden = drawing == nil
            needsDisplay = true
        }
    }
    private(set) var aperture = CGRect.zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func populate(stops: [SCNVector3], width: Float, height: Float) {
        let extent = CGRect(x: CGFloat(-width / 2), y: -0.5, width: CGFloat(width), height: CGFloat(height))
        let size = CGSize(width: 184, height: 106)
        let marks = NSBezierPath()
        for stop in stops {
            let x = (CGFloat(stop.x) - extent.minX) / extent.width * size.width
            let y = (CGFloat(stop.y) - extent.minY) / extent.height * size.height
            marks.appendOval(in: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3))
        }
        let overview = NSImage(size: size, flipped: false) { _ in
            NSColor(white: 0.76, alpha: 1).setFill()
            marks.fill()
            return true
        }
        drawing = stops.isEmpty ? nil : Drawing(atlas: overview, extent: extent)
    }

    func show(aperture: CGRect) {
        guard self.aperture != aperture else { return }
        self.aperture = aperture
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawing, !aperture.isEmpty else { return }
        let extent = drawing.extent
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor(srgbRed: 0.035, green: 0.067, blue: 0.105, alpha: 0.96).setFill()
        panel.fill()
        NSColor(white: 0.52, alpha: 0.65).setStroke()
        panel.stroke()

        // Include empty space beyond the stations so the camera stays locatable even off-map.
        let domain = extent.union(aperture)
        let plot = bounds.insetBy(dx: 7, dy: 7)
        func project(_ rect: CGRect) -> CGRect {
            CGRect(x: plot.minX + (rect.minX - domain.minX) / domain.width * plot.width,
                   y: plot.minY + (rect.minY - domain.minY) / domain.height * plot.height,
                   width: rect.width / domain.width * plot.width,
                   height: rect.height / domain.height * plot.height)
        }
        drawing.atlas.draw(in: project(extent))
        let footprint = project(aperture)
        // Keep the locator legible when a wide library compresses a single lane below one pixel.
        let lens = NSBezierPath(rect: footprint.insetBy(dx: -max(0, 5 - footprint.width) / 2,
                                                       dy: -max(0, 5 - footprint.height) / 2))
        let accent = NSColor.systemOrange
        accent.withAlphaComponent(0.11).setFill()
        lens.fill()
        accent.setStroke()
        lens.lineWidth = 1.4
        lens.stroke()
    }
}

// A face-on camera preserves horizontal order within each depth plane.
private struct StationStrip {
    typealias Entry = (id: String, position: SIMD3<Float>)
    let entries: [Entry]

    func withinX(_ lower: Float, _ upper: Float) -> ArraySlice<Entry> {
        func boundary(_ x: Float, inclusive: Bool) -> Int {
            var lo = 0
            var hi = entries.count
            while lo < hi {
                let mid = (lo + hi) / 2
                let value = entries[mid].position.x
                if value < x || (inclusive && value == x) { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        return entries[boundary(lower, inclusive: false)..<boundary(upper, inclusive: true)]
    }
}

final class RailView: SCNView {
    var choose: (String) -> Void = { _ in }
    var deselect: () -> Void = {}
    var followImprint: (String) -> Void = { _ in }
    private typealias Lane = (name: String, center: Float, span: Float, textWidth: CGFloat)
    private struct CachedMap {
        let albums: [Album]
        let rails: SCNNode
        let stops: SCNNode
        let stations: [String: SIMD3<Float>]
        let strips: [Float: StationStrip]
        let records: [String: Album]
        let routes: [String: [SIMD3<Float>]]
        let lanes: [Lane]
        let years: [(String, SIMD3<Float>)]
        let width: Float
        let height: Float
        let minimumZ: Float
        let minimap: TransitMinimap.Drawing?
    }

    // Keep the parent maps of the artist and imprint filters, excluding covers and camera state.
    private var parents: [CachedMap] = []
    private var railGeometry = SCNNode()
    private var stopGeometry = SCNNode()
    private var imprintLanes: [Lane] = []
    private var imprintButtons: [String: NSButton] = [:]
    var play: (String) -> Void = { _ in }
    var inspect: () -> Void = {}
    var step: (Int) -> Void = { _ in }
    var artistRoute: String?
    var imprint: String?
    private(set) var records: [Album] = []
    private(set) var focus = ""
    private let minimap = TransitMinimap(frame: .zero)
    private let cameraNode = SCNNode()
    private var world = SCNNode()
    private var strips: [Float: StationStrip] = [:]
    private var yearNodes: [String: SCNNode] = [:]
    private static let coverCategory = 2
    private var stations: [String: SIMD3<Float>] = [:]
    var overviewRequest = 0
    var lastDestination: UUID?
    private weak var library: LibraryStore?
    private var jackets: [String: SCNNode] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var recordByID: [String: Album] = [:]
    private var routes: [String: [SIMD3<Float>]] = [:]
    private var routeNode = SCNNode()
    private var yearLabels: [(String, SIMD3<Float>)] = []
    private var labels = SCNNode()
    private var mapWidth: Float = 1
    private var mapHeight: Float = 1
    var cameraChanged: ((Bool) -> Void)?
    var canResetCamera: Bool { !overview }
    private var lastReportedOverview: Bool?
    private var overview = false
    private var minimumZ: Float = 0
    private let halfFOV = tan(Float(47 * Double.pi / 360))
    var stationCount: Int { stations.count }
    var jacketCount: Int { jackets.count }
    private var marker = SCNNode()
    private var aim = SIMD3<Float>.zero
    var reduceMotion = false
    private var pressedStation: String?
    private var distance: Float = 15
    private var down = CGPoint.zero
    private var dragged = false
    private var grabDepth: Float = 0
    private var lastDrag = CGPoint.zero
    private let ink = NSColor(srgbRed: 0.035, green: 0.067, blue: 0.105, alpha: 1)
    private let routeInk = NSColor(srgbRed: 0.78, green: 0.81, blue: 0.83, alpha: 1)

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = SCNScene()
        scene?.background.contents = ink
        antialiasingMode = .multisampling4X
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.projectionDirection = .vertical
        cameraNode.camera?.fieldOfView = 47
        cameraNode.camera?.zFar = 250
        scene?.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        minimap.setAccessibilityElement(true)
        minimap.setAccessibilityRole(.image)
        minimap.setAccessibilityLabel("Transit minimap and current viewport")
        addSubview(minimap)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func cancelImages() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }

    private func node(_ geometry: SCNGeometry, _ color: Any, at p: SIMD3<Float>, parent: SCNNode? = nil) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = color
        geometry.materials = [material]
        let n = SCNNode(geometry: geometry)
        n.simdPosition = p
        (parent ?? world).addChildNode(n)
        return n
    }

    // One draw call per layer, regardless of the number of albums.
    private func mesh(_ vertices: [SCNVector3], primitive: SCNGeometryPrimitiveType, color: NSColor) -> SCNNode {
        guard !vertices.isEmpty else { return SCNNode() }
        let element = SCNGeometryElement(indices: (0..<vertices.count).map(Int32.init), primitiveType: primitive)
        if primitive == .point {
            element.pointSize = 0.42
            element.minimumPointScreenSpaceRadius = 9
            element.maximumPointScreenSpaceRadius = 20
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
        return node(geometry, color, at: .zero)
    }

    @discardableResult
    private func lettering(_ value: String, size: CGFloat, color: NSColor, at pos: SIMD3<Float>, parent: SCNNode? = nil) -> SCNNode {
        let text = SCNText(string: value, extrusionDepth: 0)
        text.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        text.flatness = 0.3
        let n = node(text, color, at: pos, parent: parent)
        n.simdScale = SIMD3(repeating: Float(size / 10))
        return n
    }

    func populate(_ albums: [Album], library: LibraryStore, imprintOrder: ImprintOrder? = nil,
                  keepingAnchor anchor: String? = nil, preservingViewport: Bool = false) {
        var landmark = anchor
        if preservingViewport {
            overview = false
            if landmark.flatMap({ stations[$0] }) == nil {
                // A cleared selection still has a geographical reference: the stop nearest the camera center.
                func offset(_ point: SIMD3<Float>) -> Float {
                    let x = point.x * world.simdScale.x - aim.x
                    let y = point.y - aim.y
                    return x * x + y * y
                }
                landmark = stations.min { offset($0.value) < offset($1.value) }?.key
            }
        }
        let previousPosition = landmark.flatMap { stations[$0] }
        let scale = world.simdScale
        if !preservingViewport {
            cancelImages()
            jackets.removeAll()
        }
        let restored = parents.firstIndex { $0.albums.count == albums.count && $0.albums == albums }
            .map { parents.remove(at: $0) }
        if albums.count < records.count && !records.isEmpty {
            let parent = CachedMap(albums: records, rails: railGeometry, stops: stopGeometry, stations: stations,
                                   strips: strips, records: recordByID, routes: routes, lanes: imprintLanes,
                                   years: yearLabels, width: mapWidth, height: mapHeight, minimumZ: minimumZ,
                                   minimap: minimap.drawing)
            parents.append(parent)
            if parents.count > 2 { parents.removeFirst() }
            railGeometry.removeFromParentNode()
            stopGeometry.removeFromParentNode()
        }
        records = albums
        world.removeFromParentNode()
        world = SCNNode()
        world.simdScale = scale
        scene?.rootNode.addChildNode(world)
        self.library = library
        yearNodes.removeAll()
        if let restored {
            railGeometry = restored.rails
            stopGeometry = restored.stops
            world.addChildNode(railGeometry)
            world.addChildNode(stopGeometry)
            stations = restored.stations
            strips = restored.strips
            recordByID = restored.records
            routes = restored.routes
            imprintLanes = restored.lanes
            yearLabels = restored.years
            mapWidth = restored.width
            mapHeight = restored.height
            minimumZ = restored.minimumZ
            minimap.drawing = restored.minimap
        } else {
            buildGeometry(albums, imprintOrder: imprintOrder)
        }
        for (id, jacket) in jackets {
            if let position = stations[id] {
                jacket.simdPosition = position
                world.addChildNode(jacket)
            } else {
                tasks.removeValue(forKey: id)?.cancel()
                jackets.removeValue(forKey: id)
            }
        }
        labels = SCNNode()
        world.addChildNode(labels)
        let ring = SCNTorus(ringRadius: 0.35, pipeRadius: 0.016)
        marker = node(ring, routeInk, at: .zero)
        marker.eulerAngles.x = .pi / 2

        if let landmark, let previousPosition, let current = stations[landmark] {
            if let anchor { highlightStation(anchor) }
            if overview {
                showOverview()
            } else {
                if preservingViewport {
                    let ratio = unitsPerPoint(at: current.z, distance: distance)
                        / unitsPerPoint(at: previousPosition.z, distance: distance)
                    let scale = world.simdScale.x
                    aim.x = current.x * scale - (previousPosition.x * scale - aim.x) * ratio
                    aim.y = current.y - (previousPosition.y - aim.y) * ratio
                } else {
                    let delta = current - previousPosition
                    aim += SIMD3(delta.x * world.simdScale.x, delta.y, delta.z)
                }
                updateCamera()
            }
        } else if preservingViewport {
            updateCamera()
        }
    }

    private func buildGeometry(_ albums: [Album], imprintOrder: ImprintOrder?) {
        stations.removeAll()
        routes.removeAll()
        yearLabels.removeAll()
        recordByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        let groups = Dictionary(grouping: albums, by: \.year)
        let years = groups.keys.sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }
        let byImprint = Dictionary(grouping: albums, by: \.imprint)
        let order = imprintOrder ?? ImprintOrder(albums: albums)
        let imprints: [String?] = order.lanes.filter { byImprint[$0] != nil }.map(Optional.some) + (byImprint[nil] == nil ? [] : [nil])
        let scenes = Set(albums.compactMap { $0.scenes.first }).sorted()
        let planes = Dictionary(uniqueKeysWithValues: scenes.enumerated().map { ($1, $0) })
        var centers: [String?: Float] = [:]
        var width: Float = 0
        imprintLanes.removeAll()
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        for imprint in imprints {
            let perYear = Dictionary(grouping: byImprint[imprint] ?? [], by: \.year)
            let span = Float(perYear.values.map(\.count).max() ?? 1) * 2.8
            centers[imprint] = width + span / 2
            if let imprint {
                let size = (imprint as NSString).size(withAttributes: [.font: font]).width
                imprintLanes.append((imprint, width + span / 2, span, min(180, ceil(size) + 18)))
            }
            width += span + 0.9
        }
        let middle = (width - 0.9) / 2
        for i in imprintLanes.indices { imprintLanes[i].center -= middle }
        imprintLanes.sort {
            let a = byImprint[$0.name]?.count ?? 0
            let b = byImprint[$1.name]?.count ?? 0
            return a == b ? $0.name < $1.name : a > b
        }
        let axisX = -middle - 0.5
        var rails = TransitStroke()
        var dots: [SCNVector3] = []
        var spineExtents: [Float: ClosedRange<Float>] = [:]
        minimumZ = 0
        for (level, year) in years.enumerated() {
            let y = Float(level) * 3.3
            let hub = SIMD3<Float>(axisX, y, -1)
            let row = groups[year] ?? []
            let counts = Dictionary(grouping: row, by: \.imprint).mapValues(\.count)
            var slots: [String?: Int] = [:]
            yearLabels.append((year.map(String.init) ?? "Undated", hub))
            for record in row {
                let slot = slots[record.imprint, default: 0]
                slots[record.imprint] = slot + 1
                let count = counts[record.imprint] ?? 1
                let x = (centers[record.imprint] ?? middle) - middle + (Float(slot) - Float(count - 1) / 2) * 2.8
                let plane = record.scenes.first.flatMap { planes[$0] } ?? scenes.count
                let z = -8 * Float(plane) / Float(plane + 4)
                minimumZ = min(minimumZ, z)
                let stop = SIMD3<Float>(x, y + 0.30, z)
                spineExtents[z] = (spineExtents[z]?.lowerBound ?? stop.y)...stop.y
                dots.append(SCNVector3(stop))
                stations[record.id] = stop + [0,1.08,0]
                if let artist = record.routeID { routes[artist, default: []].append(stop) }
            }
        }
        let entries = stations.map { (id: $0.key, position: $0.value) }
        strips = Dictionary(grouping: entries, by: { $0.position.z }).mapValues { entries in
            StationStrip(entries: entries.sorted { $0.position.x < $1.position.x })
        }
        mapWidth = max(width, 6)
        mapHeight = max(Float(years.count) * 3.3, 5)
        minimap.populate(stops: dots, width: mapWidth, height: mapHeight)
        for (z, extent) in spineExtents {
            rails.append([[axisX,extent.lowerBound,z], [axisX,extent.upperBound,z]], width: 0.052, bend: 0)
        }
        railGeometry = node(rails.geometry(), routeInk.withAlphaComponent(0.52), at: .zero)
        stopGeometry = mesh(dots, primitive: .point, color: routeInk)
    }

    func frameStation(_ id: String, overview landing: Bool = false, animate: Bool = true, distance detailDistance: Float = 8) {
        guard let position = stations[id] else { return }
        overview = false
        world.simdScale = SIMD3(repeating: 1)
        highlightStation(id)
        aim = landing ? SIMD3(0, position.y + 2, 0) : position
        distance = landing ? 14 : detailDistance
        updateCamera(duration: animate && !reduceMotion ? 0.36 : 0)
    }

    func highlightStation(_ id: String) {
        guard let position = stations[id] else { return }
        focus = id
        marker.isHidden = false
        marker.simdPosition = position - [0,1.08,0]
        routeNode.removeFromParentNode()
        routeNode = SCNNode()
        world.addChildNode(routeNode)
        let stops = recordByID[id]?.routeID.flatMap { routes[$0] } ?? [marker.simdPosition]
        if stops.count > 1 {
            var stroke = TransitStroke()
            for (a, b) in zip(stops, stops.dropFirst()) {
                stroke.append(TransitStroke.transfer(from: a, to: b), width: 0.11, bend: 0.40)
            }
            let line = node(stroke.geometry(), NSColor.white, at: .zero, parent: routeNode)
            line.renderingOrder = 1
        }
        let lights = mesh(stops.map(SCNVector3.init), primitive: .point, color: .white)
        lights.geometry?.firstMaterial?.readsFromDepthBuffer = false
        lights.geometry?.element(at: 0).minimumPointScreenSpaceRadius = 12
        lights.renderingOrder = 2
        routeNode.addChildNode(lights)
    }

    func clearSelection() {
        focus = ""
        marker.isHidden = true
        routeNode.removeFromParentNode()
        pressedStation = nil
    }

    func showOverview() {
        guard !stations.isEmpty else { return }
        overview = true
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Fit the label and time axes independently in the overview. Detailed
        // views always use the original station coordinates and square jackets.
        let aspect = Float(bounds.width / bounds.height)
        world.simdScale.x = min(1, mapHeight * aspect / mapWidth)
        aim = SIMD3(0, mapHeight / 2 - 0.5, 0)
        distance = overviewDistance
        updateCamera()
    }

    override func layout() {
        super.layout()
        guard !stations.isEmpty else { return }
        if overview { showOverview() } else { updateCamera() }
    }

    private func updateCamera(duration: Double = 0) {
        if lastReportedOverview != overview {
            lastReportedOverview = overview
            cameraChanged?(canResetCamera)
        }
        let depth = max(14, distance + aim.z)
        let halfHeight = distance * halfFOV
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cameraNode.camera?.zFar = Double(depth - minimumZ + 20)
        cameraNode.camera?.fieldOfView = CGFloat(2 * atan(halfHeight / (depth - aim.z)) * 180 / .pi)
        cameraNode.simdPosition = SIMD3(aim.x, aim.y, depth)
        SCNTransaction.commit()
        if bounds.width > 0 && bounds.height > 0 {
            let width = min(184, bounds.width * 0.26, bounds.height * 0.38)
            let height = width * 106 / 184
            let inset: CGFloat = 12
            minimap.frame = CGRect(x: bounds.maxX - width - inset,
                                   y: isFlipped ? bounds.maxY - height - inset : bounds.minY + inset,
                                   width: width, height: height)
            let units = CGFloat(unitsPerPoint(at: 0, distance: distance))
            let scale = CGFloat(world.simdScale.x)
            let w = bounds.width * units / scale
            let h = bounds.height * units
            minimap.show(aperture: CGRect(x: CGFloat(aim.x) / scale - w / 2, y: CGFloat(aim.y) - h / 2,
                                          width: w, height: h))
        }
        updateDetail(depth: depth, halfHeight: halfHeight)
    }

    // A fixed-size screen label stays readable while its lane expands beneath it.
    private func updateImprintLabels() {
        let units = CGFloat(unitsPerPoint(at: 0, distance: distance))
        let scale = CGFloat(world.simdScale.x) / units
        var occupied: [NSRect] = []
        var visible = Set<String>()
        for lane in imprintLanes {
            let center = bounds.midX + CGFloat(lane.center) * scale - CGFloat(aim.x) / units
            let halfSpan = CGFloat(lane.span) * scale / 2
            guard center + halfSpan >= 0, center - halfSpan <= bounds.width else { continue }
            let x = max(4, min(bounds.width - lane.textWidth - 4, center - lane.textWidth / 2))
            let y = isFlipped ? 6 : bounds.height - 29
            let rect = NSRect(x: x, y: y, width: lane.textWidth, height: 23)
            guard !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -4, dy: 0)) }) else { continue }
            occupied.append(rect)
            visible.insert(lane.name)
            let button: NSButton
            if let existing = imprintButtons[lane.name] {
                button = existing
            } else {
                button = NSButton(title: lane.name, target: self, action: #selector(selectImprint(_:)))
                button.bezelStyle = .accessoryBarAction
                button.font = .systemFont(ofSize: 11, weight: .medium)
                button.lineBreakMode = .byTruncatingTail
                button.toolTip = "Follow " + lane.name + " through the years"
                button.appearance = NSAppearance(named: .darkAqua)
                imprintButtons[lane.name] = button
                addSubview(button)
            }
            if button.frame != rect { button.frame = rect }
        }
        for name in Set(imprintButtons.keys).subtracting(visible) {
            imprintButtons.removeValue(forKey: name)?.removeFromSuperview()
        }
    }

    @objc private func selectImprint(_ sender: NSButton) {
        followImprint(sender.title)
    }

    private func updateDetail(depth: Float, halfHeight: Float) {
        guard bounds.height > 0 else { return }
        let aspect = Float(bounds.width / bounds.height)
        updateImprintLabels()
        let atDepth = halfHeight / (depth - aim.z)
        var nearby: [(id: String, score: Float)] = []
        if world.simdScale.x > 0.98 && distance < max(34, Float(bounds.height) / 8) {
            for (z, strip) in strips {
                let h = (depth - z) * atDepth
                guard Float(bounds.height) / h > 22 else { continue }
                let halfWidth = h * aspect + 1.2
                let scale = world.simdScale.x
                for (id, p) in strip.withinX((aim.x - halfWidth) / scale, (aim.x + halfWidth) / scale) {
                    let dy = abs(p.y - aim.y)
                    guard dy < h + 1.2 else { continue }
                    let dx = p.x * scale - aim.x
                    nearby.append((id, dx * dx + dy * dy))
                }
            }
        }
        let visible = Set(nearby.sorted { $0.score < $1.score }.prefix(72).map(\.id))
        for id in Set(jackets.keys).subtracting(visible) {
            tasks.removeValue(forKey: id)?.cancel()
            jackets.removeValue(forKey: id)?.removeFromParentNode()
        }
        for id in visible where jackets[id] == nil {
            guard let record = recordByID[id], let p = stations[id], let library else { continue }
            let group = SCNNode()
            group.simdPosition = p
            world.addChildNode(group)
            jackets[id] = group
            let cover = node(SCNPlane(width: 1.74, height: 1.74), NSColor.darkGray, at: .zero, parent: group)
            cover.name = id
            cover.categoryBitMask = Self.coverCategory
            lettering(String(record.artist.prefix(24)), size: 0.205, color: .white, at: [-0.87,0.93,0], parent: group)
            if let name = record.sampleArt, let image = NSImage(named: name) {
                cover.geometry?.firstMaterial?.diffuse.contents = image
            } else if record.thumb != nil {
                tasks[id] = Task { @MainActor [weak cover] in
                    if let image = await CoverCache.load(record, library: library), !Task.isCancelled {
                        cover?.geometry?.firstMaterial?.diffuse.contents = image
                    }
                }
            }
        }
        var shownYears = Set<String>()
        let stride = max(1, Int(ceil(32 * Double(halfHeight * 2) / (3.3 * max(1, Double(bounds.height))))))
        for (i,label) in yearLabels.enumerated() where i.isMultiple(of: stride) {
            let h = depth * atDepth
            guard abs(label.1.y - aim.y) < h + 1 else { continue }
            let units = 2 * h / Float(bounds.height)
            let x = (aim.x - h * aspect + 12 * units) / world.simdScale.x
            let size = CGFloat(13 * units)
            let year = label.0
            let text = yearNodes[year] ?? lettering(year, size: size, color: .white, at: .zero, parent: labels)
            yearNodes[year] = text
            text.isHidden = false
            text.renderingOrder = 10
            text.geometry?.firstMaterial?.readsFromDepthBuffer = false
            text.geometry?.firstMaterial?.writesToDepthBuffer = false
            text.simdPosition = [x, label.1.y + 0.08, 0]
            text.simdScale = [Float(size / 10) / world.simdScale.x, Float(size / 10), Float(size / 10)]
            shownYears.insert(year)
        }
        for (year, node) in yearNodes where !shownYears.contains(year) { node.isHidden = true }
    }

    // Pick batched stations in screen space, even when there is no cover node.
    private func nearestStation(to point: CGPoint) -> String? {
        var best: String?
        var limit: CGFloat = 12 * 12
        for (z, strip) in strips {
            // Convert the pick radius to a lane interval once per plane, then verify
            // candidates with SceneKit's projection to preserve exact hit distances.
            let half = CGFloat(mapWidth / 2 * world.simdScale.x)
            let left = projectPoint(SCNVector3(-half, 0, CGFloat(z))).x
            let right = projectPoint(SCNVector3(half, 0, CGFloat(z))).x
            guard right > left else { continue }
            let units = CGFloat(mapWidth) / (right - left)
            let x = (point.x - left) * units - CGFloat(mapWidth) / 2
            for (id, p) in strip.withinX(Float(x - 13 * units), Float(x + 13 * units)) {
                let screen = projectPoint(SCNVector3(p.x * world.simdScale.x, p.y - 1.08, p.z))
                let dx = screen.x - point.x, dy = screen.y - point.y
                let d = dx * dx + dy * dy
                if d < limit { best = id; limit = d }
            }
        }
        return best
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        down = convert(event.locationInWindow, from: nil)
        lastDrag = down
        grabDepth = depthUnderCursor(down)
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - down.x, p.y - down.y) > 3 { dragged = true }
        guard dragged else { return }
        let units = unitsPerPoint(at: grabDepth, distance: distance)
        aim.x -= Float(p.x - lastDrag.x) * units
        aim.y -= Float(p.y - lastDrag.y) * units * (isFlipped ? -1 : 1)
        lastDrag = p
        overview = false
        updateCamera()
    }
    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = coverHit(at: p)?.node.name ?? nearestStation(to: p)
        let previous = pressedStation
        pressedStation = hit
        if let id = hit {
            if focus != id {
                highlightStation(id)
                choose(id)
            }
            if event.clickCount == 2, previous == id { play(id) }
        } else {
            clearSelection()
            deselect()
        }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.012 : 0.16)
        guard delta != 0 else { return }
        zoom(by: exp(-max(-1, min(1, delta))), at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 / max(0.25, 1 + Float(event.magnification)), at: convert(event.locationInWindow, from: nil))
    }

    private var overviewDistance: Float { max(12, mapHeight * 1.13 / (2 * halfFOV)) }

    private func coverHit(at point: CGPoint) -> SCNHitTestResult? {
        guard !jackets.isEmpty else { return nil }
        return hitTest(point, options: [.categoryBitMask: Self.coverCategory,
                                        .searchMode: SCNHitTestSearchMode.closest.rawValue]).first
    }

    private func depthUnderCursor(_ point: CGPoint) -> Float {
        let cover = coverHit(at: point)
        if let cover { return Float(cover.worldCoordinates.z) }
        if let id = nearestStation(to: point), let p = stations[id] { return p.z }
        return aim.z
    }

    private func unitsPerPoint(at plane: Float, distance: Float) -> Float {
        let cameraZ = max(14, distance + aim.z)
        return 2 * distance * halfFOV / Float(max(1, bounds.height)) * (cameraZ - plane) / (cameraZ - aim.z)
    }

    func zoom(by factor: Float, at point: CGPoint) {
        let next = min(max(34, overviewDistance), max(3, distance * factor))
        guard next != distance, bounds.width > 0, bounds.height > 0 else { return }
        let plane = depthUnderCursor(point)
        let pixel = SIMD2(Float(point.x - bounds.midX), Float(point.y - bounds.midY) * (isFlipped ? -1 : 1))
        let oldOffset = pixel * unitsPerPoint(at: plane, distance: distance)
        let localX = (aim.x + oldOffset.x) / world.simdScale.x
        let localY = aim.y + oldOffset.y

        // Expand compressed imprint lanes continuously as we leave the overview.
        let fitScale = min(1, mapHeight * Float(bounds.width / bounds.height) / mapWidth)
        let detailDistance = min(24, overviewDistance * 0.55)
        let blend = min(1, max(0, log(next / detailDistance) / log(overviewDistance / detailDistance)))
        let scale = pow(fitScale, blend)
        let newOffset = pixel * unitsPerPoint(at: plane, distance: next)
        aim.x = localX * scale - newOffset.x
        aim.y = localY - newOffset.y
        world.simdScale.x = scale
        distance = next
        overview = false
        updateCamera()
    }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 126, 124: step(1)
        case 125, 123: step(-1)
        case 36: if !focus.isEmpty { inspect() }
        case 53: showOverview()
        case 24, 27:
            zoom(by: event.keyCode == 24 ? 0.85 : 1.18, at: CGPoint(x: bounds.midX, y: bounds.midY))
        default: super.keyDown(with: event)
        }
    }
}
