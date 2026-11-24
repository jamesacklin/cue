import SceneKit
import XCTest
@testable import Sleeve

@MainActor
final class TransitMapTests: XCTestCase {
    func testSharedArtistOutranksGenreAndInputOrder() {
        func album(_ label: String, _ artist: String, _ genre: String) -> Album {
            Album(id: label, title: label, artist: artist, year: 2000, added: 0,
                  thumb: nil, imprint: label, genres: [genre])
        }
        let albums = [album("A", "Touring artist", "Ambient"), album("B", "Solo", "Ambient"),
                      album("Z", "Touring artist", "Rock")]
        XCTAssertEqual(ImprintOrder(albums: albums).lanes, ["A", "Z", "B"])
        XCTAssertEqual(ImprintOrder(albums: albums.reversed()).lanes, ["A", "Z", "B"])
    }

    func testGenreNeighborhoodsUseSecondaryStylesAndLeaveUntaggedLabelsUnassigned() {
        func record(_ label: String, genre: String, style: String) -> Album {
            Album(id: label, title: label, artist: label, year: 2020, added: 0, thumb: nil,
                  imprint: label, genres: [genre], styles: [style])
        }
        let albums = [record("A", genre: "Electronic", style: "Dub Techno"),
                      record("B", genre: "Electronic", style: "Power Electronics"),
                      record("C", genre: "Electronic", style: "  dub   techno "),
                      record("D", genre: "Electronic", style: "Power Electronics"),
                      record("E", genre: "", style: "")]
        let layout = ImprintOrder(albums: albums)
        XCTAssertEqual(layout.neighborhood["A"], layout.neighborhood["C"])
        XCTAssertEqual(layout.neighborhood["B"], layout.neighborhood["D"])
        XCTAssertNotEqual(layout.neighborhood["A"], layout.neighborhood["B"])
        XCTAssertTrue(layout.neighborhood["A"]?.lowercased().contains("dub techno") == true)
        XCTAssertNil(layout.neighborhood["E"])
        XCTAssertEqual(Set(layout.lanes), Set(["A", "B", "C", "D", "E"]))
        let shuffled = ImprintOrder(albums: albums.reversed())
        XCTAssertEqual(layout.lanes, shuffled.lanes)
        XCTAssertEqual(layout.neighborhood, shuffled.neighborhood)
    }

    func testDecadeFilterIncludesBothBoundariesAndHandlesUndatedAlbums() {
        let albums = [1989, 1990, 1999, 2000, nil].enumerated().map { i, year in
            Album(id: String(i), title: "Release", artist: "Band", year: year, added: 0, thumb: nil)
        }
        XCTAssertEqual(albums.filter(MapDecade.years(1990).matches).map(\.id), ["1", "2"])
        XCTAssertEqual(albums.filter(MapDecade.undated.matches).map(\.id), ["4"])
        XCTAssertEqual(albums.filter(MapDecade.all.matches), albums)
    }

    func testArtistFilterCompactsLayoutWhileKeepingSelectedStationInView() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let library = LibraryStore()
        let all = Sample.albums
        let target = all[2]
        view.populate(all, library: library)
        view.frameStation(target.id, animate: false, distance: 20)
        view.zoom(by: 0.8, at: CGPoint(x: 560, y: 280))
        let map = try XCTUnwrap(view.subviews.compactMap { $0 as? TransitMinimap }.first)
        let aperture = map.aperture
        func station() throws -> SCNVector3 {
            let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: target.id, recursively: true))
            return view.projectPoint(node.worldPosition)
        }
        func coverWidth() throws -> CGFloat {
            let node = try XCTUnwrap(view.scene?.rootNode.childNode(withName: target.id, recursively: true))
            var edge = node.worldPosition
            edge.x += 1
            return view.projectPoint(edge).x - view.projectPoint(node.worldPosition).x
        }
        let before = try station()
        let initialWidth = try coverWidth()
        let artist = all.filter { $0.routeID == target.routeID }
        for visible in [artist, all] {
            view.populate(visible, library: library, keepingAnchor: target.id)
            XCTAssertEqual(view.stationCount, visible.count)
            XCTAssertEqual(view.focus, target.id)
            let after = try station()
            XCTAssertEqual(after.x, before.x, accuracy: 0.1)
            XCTAssertEqual(after.y, before.y, accuracy: 0.1)
            XCTAssertEqual(try coverWidth(), initialWidth, accuracy: 0.1)
            if visible.count < all.count { XCTAssertNotEqual(map.aperture.origin, aperture.origin) }
        }
    }

    func testClearingFilterKeepsFilteredOverviewScaleWithOrWithoutSelection() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let library = LibraryStore()
        let album = Sample.albums[2]
        let map = try XCTUnwrap(view.subviews.compactMap { $0 as? TransitMinimap }.first)
        for selection in [album.id, nil] {
            view.populate([album], library: library)
            view.showOverview()
            let before = map.aperture
            view.populate(Sample.albums, library: library, keepingAnchor: selection, preservingViewport: true)
            view.layout()
            XCTAssertEqual(view.stationCount, Sample.albums.count)
            XCTAssertEqual(map.aperture.width, before.width, accuracy: 0.01)
            XCTAssertEqual(map.aperture.height, before.height, accuracy: 0.01)
        }
    }

    func testMinimapTracksZoomAndOverview() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let library = LibraryStore()
        view.populate(Sample.albums, library: library)
        view.showOverview()
        let map = try XCTUnwrap(view.subviews.compactMap { $0 as? TransitMinimap }.first)
        let full = map.aperture
        view.zoom(by: 0.5, at: CGPoint(x: 600, y: 300))
        XCTAssertLessThan(map.aperture.width, full.width)
        XCTAssertGreaterThan(map.aperture.midX, full.midX)
        XCTAssertNil(map.hitTest(CGPoint(x: 4, y: 4)))
        view.showOverview()
        XCTAssertEqual(map.aperture, full)
    }

    func testOverviewImprintNamesAreClickableAndDoNotOverlap() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let library = LibraryStore()
        view.populate(Sample.albums, library: library)
        view.frameStation(Sample.albums[0].id, animate: false)
        view.showOverview()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(Set(buttons.map(\.title)), Set(Sample.albums.compactMap(\.imprint)))
        for (i, button) in buttons.enumerated() {
            XCTAssertFalse(buttons.dropFirst(i + 1).contains { $0.frame.intersects(button.frame) })
        }
        var followed: String?
        view.followImprint = { followed = $0 }
        let button = try XCTUnwrap(buttons.first)
        button.performClick(nil)
        XCTAssertEqual(followed, button.title)
    }

    func testClickHighlightsStationInPlaceAndDoubleClickPlaysIt() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let library = LibraryStore()
        view.populate(Sample.albums, library: library)
        view.frameStation(Sample.albums[1].id, animate: false)
        view.showOverview()
        _ = view.snapshot()
        let camera = try XCTUnwrap(view.pointOfView)
        let initialPosition = camera.simdPosition
        let initialFOV = camera.camera?.fieldOfView
        let target = Sample.albums[0].id
        let cover = try XCTUnwrap(view.scene?.rootNode.childNode(withName: target, recursively: true))
        let projected = view.projectPoint(cover.worldPosition)
        let point = view.convert(CGPoint(x: projected.x, y: projected.y), to: nil)
        var picked: String?
        var played: [String] = []
        view.choose = { picked = $0 }
        view.play = { played.append($0) }
        for count in [1, 1, 2] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
            view.mouseUp(with: event)
            XCTAssertEqual(view.focus, target)
            XCTAssertEqual(camera.simdPosition, initialPosition)
            XCTAssertEqual(camera.camera?.fieldOfView, initialFOV)
        }
        XCTAssertEqual(picked, target)
        XCTAssertEqual(played, [target])
    }

    func testBlankClickClearsFocusWithoutMovingCamera() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let library = LibraryStore()
        view.populate(Sample.albums, library: library)
        view.frameStation(Sample.albums[0].id, animate: false)
        _ = view.snapshot()
        let camera = view.pointOfView?.simdPosition
        var cleared = false
        view.deselect = { cleared = true }
        let point = view.convert(CGPoint(x: 8, y: 8), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        XCTAssertTrue(cleared)
        XCTAssertTrue(view.focus.isEmpty)
        XCTAssertEqual(view.pointOfView?.simdPosition, camera)
        view.frameStation(Sample.albums[1].id, animate: false)
        XCTAssertEqual(view.focus, Sample.albums[1].id)
    }

    func testRoundedTransferRetainsStationEndpointsAndFiniteGeometry() throws {
        let a = SIMD3<Float>(-30, 2, -5)
        for b in [SIMD3<Float>(25, 8, -1), SIMD3<Float>(4, 2, -5), SIMD3<Float>(-30, 8, -5)] {
            let corners = TransitStroke.transfer(from: a, to: b)
            XCTAssertEqual(corners.first, a)
            XCTAssertEqual(corners.last, b)
            var stroke = TransitStroke()
            stroke.append([a] + corners, width: 0.085, bend: 0.4)
            let geometry = stroke.geometry()
            let positions = try XCTUnwrap(geometry.sources(for: .vertex).first)
            XCTAssertGreaterThan(positions.vectorCount, corners.count * 3)
            let bounds = geometry.boundingBox
            XCTAssertTrue(bounds.min.x.isFinite && bounds.max.y.isFinite && bounds.max.z.isFinite)
        }
    }

    func testOffCenterZoomAndDragKeepTheGrabbedAlbumUnderThePointer() throws {
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let library = LibraryStore()
        let album = Sample.albums[0]
        view.populate(Sample.albums, library: library)
        view.frameStation(album.id, animate: false)
        let jacket = try XCTUnwrap(view.scene?.rootNode.childNode(withName: album.id, recursively: true))
        let corner = jacket.convertPosition(SCNVector3(0.6, 0.5, 0), to: nil)
        func screenPoint() -> CGPoint {
            _ = view.snapshot()
            let point = view.projectPoint(corner)
            return CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        }
        let cursor = screenPoint()
        view.zoom(by: 0.65, at: cursor)
        var projected = screenPoint()
        XCTAssertEqual(projected.x, cursor.x, accuracy: 1)
        XCTAssertEqual(projected.y, cursor.y, accuracy: 1)

        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let end = CGPoint(x: cursor.x + 65, y: cursor.y - 35)
        view.mouseDown(with: try mouse(.leftMouseDown, cursor))
        view.mouseDragged(with: try mouse(.leftMouseDragged, end))
        view.mouseUp(with: try mouse(.leftMouseUp, end))
        projected = screenPoint()
        XCTAssertEqual(projected.x, end.x, accuracy: 1)
        XCTAssertEqual(projected.y, end.y, accuracy: 1)
        XCTAssertEqual(view.focus, album.id)
    }

    func testWholeLibraryStaysMappedWhileOnlyNearbyJacketsAreMaterialized() {
        let albums = (0..<10_000).map { i in
            Album(id: String(i), title: "Record \(i)", artist: "Artist \(i % 457)",
                  year: 2025 - i / 200, added: 0, thumb: nil, imprint: "Label \(i % 80)")
        }
        let view = RailView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let library = LibraryStore()
        view.populate(albums, library: library)
        view.frameStation("0", animate: false)
        view.showOverview()
        XCTAssertEqual(view.stationCount, 10_000)
        XCTAssertEqual(view.jacketCount, 0)

        for id in ["11", "12", "4564", "9999"] {
            view.frameStation(id, animate: false)
            XCTAssertEqual(view.focus, id)
            XCTAssertGreaterThan(view.jacketCount, 0)
            XCTAssertLessThanOrEqual(view.jacketCount, 72)
            XCTAssertEqual(view.stationCount, 10_000)
        }

        view.populate(Sample.albums, library: library)
        view.frameStation(Sample.albums[0].id, animate: false)
        XCTAssertEqual(view.stationCount, 6)
        XCTAssertEqual(view.focus, Sample.albums[0].id)
    }
}
