import AppKit
import AVFoundation
import XCTest
@testable import Sleeve

@MainActor
final class PlaybackTests: XCTestCase {
    private func playbackEntries() throws -> [QueueEntry] {
        let url = try XCTUnwrap(Bundle(for: PlaybackTests.self).url(forResource: "playback-fixture", withExtension: "m4a"))
        let album = Album(id: "fixture", title: "Test album", artist: "Test artist", year: nil)
        return (1...2).map { index in
            let track = Track(id: String(index), title: "Track \(index)", artist: album.artist, disc: 1,
                              number: index, duration: 24, part: nil)
            return QueueEntry(track: track, album: album, url: url)
        }
    }

    func testDisconnectedCatalogIsEmpty() async throws {
        let store = LibraryStore()
        for kind in Catalog.allCases {
            let result = try await store.catalog(kind, query: "", offset: 0, artistID: nil, order: .standard(for: kind))
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertEqual(result.total, 0)
            XCTAssertNil(result.next)
        }
        XCTAssertTrue(store.player.queue.isEmpty)
    }

    func testPlayingSeekingAndAutomaticAdvance() async throws {
        let player = Player()
        player.volume = 0
        defer { player.reset() }
        let entries = try playbackEntries()
        player.replace(entries, startingAt: 0)
        try await wait { player.playing && player.elapsed > 0.2 }
        player.toggle()
        try await wait { !player.playing }
        player.seek(to: 23.3)
        player.toggle()
        try await wait { player.index == 1 && player.playing }
        XCTAssertEqual(player.current?.track.title, "Track 2")
        player.previous()
        XCTAssertEqual(player.index, 0)
        player.next()
        XCTAssertFalse(player.hasNext)
        player.reset()
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.current)
    }

    func testHiddenProgressKeepsPlayingAndResumesAtCurrentPosition() async throws {
        let player = Player()
        player.volume = 0
        defer { player.reset() }
        player.setProgressVisible(false)
        player.replace(try playbackEntries(), startingAt: 0)
        try await wait { player.audio.currentTime().seconds >= 1.2 }
        XCTAssertEqual(player.elapsed, 0)
        player.setProgressVisible(true)
        try await wait { player.elapsed >= 1 }
        XCTAssertTrue(player.playing)
    }

    func testFooterSeekBarFollowsPlaybackAndSeeking() async throws {
        let store = LibraryStore()
        store.player.volume = 0
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { store.player.reset(); controller.close() }
        let view = try XCTUnwrap(controller.window?.contentView)
        let slider = try XCTUnwrap(view.descendants(of: NSSlider.self).first { $0.accessibilityLabel() == "Playback position" })
        store.player.replace(try playbackEntries(), startingAt: 0)
        try await wait { slider.doubleValue > 0.2 }
        let first = slider.doubleValue
        try await wait { slider.doubleValue > first + 0.4 }
        XCTAssertTrue(slider.isEnabled)
        XCTAssertFalse(slider.isVertical)
        XCTAssertGreaterThan(slider.bounds.width, 80)
        XCTAssertEqual(slider.maxValue, 24, accuracy: 0.1)
        store.player.toggle()
        try await wait { !store.player.playing }
        slider.doubleValue = 12
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        try await wait { abs(store.player.audio.currentTime().seconds - 12) < 0.15 }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(slider.doubleValue, 12, accuracy: 0.15)
        store.player.toggle()
        try await wait { slider.doubleValue > 12.4 }
    }

    private func wait(until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready() {
            guard Date() < deadline else { throw MusicError("Playback did not reach the expected state.") }
            try await Task.sleep(for: .milliseconds(80))
        }
    }
}

extension NSView {
    func descendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { view in
            (view as? T).map { [$0] } ?? view.descendants(of: type)
        }
    }
}
