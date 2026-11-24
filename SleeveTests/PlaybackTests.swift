import AVFoundation
import XCTest
@testable import Sleeve

@MainActor
final class PlaybackTests: XCTestCase {
    func testEverySampleHasPlayableAudio() async throws {
        XCTAssertEqual(Sample.albums.count, 6)
        for album in Sample.albums {
            for track in Sample.tracks(for: album) {
                let asset = AVURLAsset(url: try XCTUnwrap(track.localFile))
                let playable = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration)
                XCTAssertTrue(playable)
                XCTAssertEqual(duration.seconds, track.duration, accuracy: 0.1)
            }
        }
    }

    func testAlbumPlaybackQueuesLatestRequestedAlbumFromFirstTrack() async throws {
        let store = LibraryStore()
        store.player.volume = 0
        defer { store.player.reset() }
        store.playAlbum(Sample.albums[0])
        let album = Sample.albums[1]
        store.playAlbum(album)
        try await wait { store.player.playing }
        XCTAssertEqual(store.player.queue.map(\.track.id), Sample.tracks(for: album).map(\.id))
        XCTAssertEqual(store.player.index, 0)
    }

    func testPlayingSeekingAndAutomaticAdvance() async throws {
        let player = Player()
        player.volume = 0
        defer { player.reset() }
        let album = Sample.albums[0]
        let entries = try Sample.tracks(for: album).map { track in
            QueueEntry(track: track, album: album, url: try XCTUnwrap(track.localFile))
        }
        player.replace(entries, startingAt: 0)
        try await wait { player.playing && player.elapsed > 0.2 }
        player.toggle()
        try await wait { !player.playing }
        player.seek(to: 23.3)
        player.toggle()
        try await wait { player.index == 1 && player.playing }
        XCTAssertEqual(player.current?.track.title, "The Upper Floor")
        player.previous()
        XCTAssertEqual(player.index, 0)
        player.next()
        XCTAssertFalse(player.hasNext)
        player.reset()
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.current)
    }

    private func wait(until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready() {
            guard Date() < deadline else { throw MusicError("Playback did not reach the expected state.") }
            try await Task.sleep(for: .milliseconds(80))
        }
    }
}
