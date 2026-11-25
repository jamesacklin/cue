import AppKit
import MediaPlayer
import AVFoundation
import AVKit
import XCTest
@testable import Cue

@MainActor
final class PlaybackTests: XCTestCase {
    private func playbackEntries(duration: Double = 24) throws -> [QueueEntry] {
        let url = try XCTUnwrap(Bundle(for: PlaybackTests.self).url(forResource: "playback-fixture", withExtension: "m4a"))
        let album = Album(id: "fixture", title: "Test album", artist: "Test artist", year: nil)
        return (1...2).map { index in
            let track = Track(id: String(index), title: "Track \(index)", artist: album.artist, disc: 1,
                              number: index, duration: duration, part: nil)
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

    func testAirPlayDiagnosticsCapturePlaybackAndOmitSensitiveErrorDetails() async throws {
        let store = LibraryStore()
        let player = store.player
        player.volume = 0
        let controller = LibraryWindow(store: store)
        defer { player.reset(); controller.close() }
        let view = try XCTUnwrap(controller.window?.contentView)
        let transport = try XCTUnwrap(view.descendants(of: Transport.self).first)
        let picker = try XCTUnwrap(view.descendants(of: AVRoutePickerView.self).first)
        let playbackMenu = NSApp.mainMenu?.item(withTitle: "Playback")?.submenu
        XCTAssertEqual(playbackMenu?.item(withTitle: "Copy AirPlay Diagnostics")?.action,
                       #selector(LibraryWindow.copyAirPlayDiagnostics))

        let entries = try playbackEntries()
        player.replace(entries, startingAt: 0)
        try await wait { player.airPlayDiagnostics.report.contains("Playback state: playing") }
        transport.routePickerViewWillBeginPresentingRoutes(picker)
        transport.routePickerViewDidEndPresentingRoutes(picker)
        let url = "https://private-server.example/file?X-Plex-Token=private-token"
        let inner = NSError(domain: url, code: -123, userInfo: [NSLocalizedDescriptionKey: "private-device"])
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSURLErrorFailingURLStringErrorKey: url,
            NSUnderlyingErrorKey: inner
        ])
        player.airPlayDiagnostics.recordFailure("Fixture playback failure", error: error)
        player.reset()

        let report = player.airPlayDiagnostics.report
        XCTAssertTrue(report.contains("Audio player created"))
        XCTAssertTrue(report.contains("Route picker opened (transport)"))
        XCTAssertTrue(report.contains("Route picker closed (transport)"))
        XCTAssertTrue(report.contains("Fixture playback failure: NSURLErrorDomain (-1001)"))
        XCTAssertTrue(report.contains("Underlying error: other domain (-123)"))
        XCTAssertTrue(report.contains("Audio player released"))
        for sensitive in [url, "private-device", entries[0].url.absoluteString, entries[0].track.title] {
            XCTAssertFalse(report.contains(sensitive))
        }
    }

    func testPlayingSeekingAndAutomaticAdvance() async throws {
        let player = Player()
        player.volume = 0
        defer { player.reset() }
        let entries = try playbackEntries()
        player.append(entries)
        XCTAssertEqual(player.queue, entries[...])
        try await wait { player.playing && player.elapsed > 0.2 }
        player.toggle()
        try await wait { !player.playing }
        XCTAssertEqual(player.queue, entries[...])
        player.seek(to: 23.3)
        player.toggle()
        try await wait { player.current?.id == entries[1].id && player.playing }
        XCTAssertEqual(player.queue, [entries[1]])
        XCTAssertEqual(player.current?.track.title, "Track 2")
        XCTAssertFalse(player.hasNext)
        player.previous()
        XCTAssertEqual(player.current?.id, entries[0].id)
        XCTAssertEqual(player.queue, entries[...])
        player.next()
        XCTAssertEqual(player.queue, entries[...])
        player.seek(to: 23.4)
        try await wait { player.current?.id == entries[0].id }
        XCTAssertEqual(player.queue, [entries[0]])
        player.seek(to: 23.4)
        try await wait { player.queue.isEmpty }
        XCTAssertFalse(player.hasNext)
        player.resume()
        XCTAssertEqual(player.queue, [entries[0]])
        player.reset()
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.current)
    }

    func testEqualizerPanelBeforePlayback() throws {
        let suite = "CueEQPanel-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = Player(defaults: defaults)
        let controller = EqualizerPanel(equalizer: player.equalizer)
        controller.showWindow(nil)
        defer { controller.close() }
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        let sliders = view.descendants(of: NSSlider.self)
        XCTAssertEqual(sliders.count, 10)
        for slider in sliders {
            XCTAssertTrue(view.bounds.contains(slider.convert(slider.bounds, to: view)))
        }
        let slider = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "1 kHz" })
        slider.doubleValue = 0.5
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        XCTAssertEqual(player.equalizer.gains[5], 4)
        let buttons = view.descendants(of: NSButton.self)
        try XCTUnwrap(buttons.first { $0.title == "Enable equalizer" }).performClick(nil)
        XCTAssertTrue(player.equalizer.enabled)
        try XCTUnwrap(buttons.first { $0.title == "Reset to Flat" }).performClick(nil)
        XCTAssertEqual(slider.doubleValue, 0)
        XCTAssertNil(player.routePlayer.value)
    }

    func testEqualizerDuringPlaybackAndTrackChanges() async throws {
        let suite = "CueEQ-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = Player(defaults: defaults)
        player.volume = 0
        defer { player.reset() }
        player.replace(try playbackEntries(), startingAt: 0)
        let item = try XCTUnwrap(player.audio.currentItem)
        XCTAssertNil(item.audioMix)
        let eq = player.equalizer
        eq.setGain(-8, band: 3)
        eq.setEnabled(true)
        try await wait { item.audioMix != nil && player.elapsed > 0.2 }
        eq.setEnabled(false)
        XCTAssertTrue(item === player.audio.currentItem)
        XCTAssertEqual(eq.gains[3], -8)
        eq.setEnabled(true)
        let restored = Equalizer(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.gains, eq.gains)
        player.seek(to: 23.3)
        try await wait { !player.hasNext && player.audio.currentItem?.audioMix != nil }
        eq.flatten()
        XCTAssertEqual(eq.gains, Array(repeating: 0, count: 10))
    }

    func testEqualizerChangesRenderedFixtureAudio() async throws {
        let url = try playbackEntries()[0].url
        let item = AVPlayerItem(url: url)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let suite = "CueEQRender-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let eq = Equalizer(defaults: defaults)
        eq.setEnabled(true)
        eq.attach(to: item)
        try await wait { item.audioMix != nil }

        func level(_ mix: AVAudioMix?) throws -> Double {
            let reader = try AVAssetReader(asset: item.asset)
            reader.timeRange = CMTimeRange(start: CMTime(value: 1, timescale: 1),
                                           duration: CMTime(value: 1, timescale: 2))
            let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = mix
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var power = 0.0
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
                var values = Array(repeating: Float.zero, count: CMBlockBufferGetDataLength(block) / 4)
                let status = values.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, noErr)
                for value in values { power += Double(value) * Double(value) }
                count += values.count
            }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThan(count, 0)
            return 10 * log10(power / Double(count))
        }
        let dry = try level(nil)
        XCTAssertEqual(try level(item.audioMix), dry, accuracy: 0.01)
        // Measure the midrange of the fixture against its unfiltered render.
        eq.setGain(12, band: 4)
        let boosted = try level(item.audioMix)
        eq.setGain(-12, band: 4)
        let cut = try level(item.audioMix)
        XCTAssertGreaterThan(boosted, dry + 1)
        XCTAssertLessThan(cut, dry - 1)
        eq.setEnabled(false)
        XCTAssertEqual(try level(item.audioMix), dry, accuracy: 0.01)
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
        defer { store.player.reset(); controller.close() }
        let view = try XCTUnwrap(controller.window?.contentView)
        view.layoutSubtreeIfNeeded()
        // Exercise the footer with progress enabled regardless of desktop occlusion.
        store.player.setProgressVisible(true)
        let slider = try XCTUnwrap(view.descendants(of: NSSlider.self).first { $0.accessibilityLabel() == "Playback position" })
        // The asset supplies the duration when Plex metadata omits it.
        store.player.replace(try playbackEntries(duration: 0), startingAt: 0)
        try await wait("seek bar to show playback") { slider.doubleValue > 0.2 }
        let first = slider.doubleValue
        try await wait("seek bar to advance") { slider.doubleValue > first + 0.4 }
        XCTAssertTrue(slider.isEnabled)
        XCTAssertFalse(slider.isVertical)
        XCTAssertGreaterThan(slider.bounds.width, 80)
        XCTAssertEqual(slider.maxValue, 24, accuracy: 0.1)
        store.player.toggle()
        try await wait("player to pause") { !store.player.playing }
        slider.doubleValue = 12
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        try await wait("player to seek to 12 seconds") { abs(store.player.audio.currentTime().seconds - 12) < 0.15 }
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(slider.doubleValue, 12, accuracy: 0.15)
        store.player.toggle()
        try await wait("seek bar to advance after resuming") { slider.doubleValue > 12.4 }
    }

    func testSpaceAndNowPlayingWhileSearchKeepsSpaces() async throws {
        let store = LibraryStore()
        let player = store.player
        player.volume = 0
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { player.reset(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        let search = try XCTUnwrap(root.descendants(of: NSSearchField.self).first)
        func space(repeat held: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: " ",
                                                       charactersIgnoringModifiers: " ", isARepeat: held, keyCode: 49))
            window.sendEvent(event)
        }
        let info = MPNowPlayingInfoCenter.default()
        let remote = MPRemoteCommandCenter.shared()
        player.replace(try playbackEntries(), startingAt: 0)
        try await wait { info.playbackState == .playing }
        XCTAssertEqual(info.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track 1")
        XCTAssertTrue(remote.nextTrackCommand.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(table))
        try space()
        try await wait { !player.playing && info.playbackState == .paused }
        try space(repeat: true)
        XCTAssertEqual(player.audio.rate, 0)
        try space()
        try await wait { player.playing && info.playbackState == .playing }
        XCTAssertTrue(window.makeFirstResponder(search))
        try space()
        XCTAssertEqual(search.stringValue, " ")
        XCTAssertTrue(player.playing)
        player.next()
        XCTAssertEqual(info.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Track 2")
        XCTAssertTrue(remote.nextTrackCommand.isEnabled)
        let first = try XCTUnwrap(player.queue.first)
        XCTAssertEqual(first.track.title, "Track 1")
        player.removeQueuedEntries([first.id])
        XCTAssertFalse(remote.nextTrackCommand.isEnabled)
        player.reset()
        XCTAssertNil(info.nowPlayingInfo)
        XCTAssertFalse(remote.togglePlayPauseCommand.isEnabled)
    }

    func testQueueEditsPreservePlaybackAndAdvanceInNewOrder() async throws {
        let player = Player()
        player.volume = 0
        defer { player.reset() }
        // The same Plex track may occur more than once in the queue.
        let entries = try playbackEntries() + playbackEntries()
        player.replace(entries, startingAt: 0)
        try await wait { player.playing && player.elapsed > 0 }
        let item = player.audio.currentItem
        player.moveQueuedEntries([entries[3].id, entries[1].id], to: 0)
        XCTAssertEqual(player.queue, [entries[3], entries[1], entries[0], entries[2]])
        XCTAssertTrue(player.audio.currentItem === item)
        XCTAssertEqual(player.current?.id, entries[0].id)
        player.seek(to: 23.4)
        try await wait { player.current?.id == entries[3].id }
        XCTAssertEqual(player.queue, [entries[3], entries[1], entries[2]])
        player.pause()
        try await wait { !player.playing }
        player.removeQueuedEntries([entries[1].id, entries[2].id])
        XCTAssertEqual(player.queue, [entries[3]])
        XCTAssertEqual(player.current?.id, entries[3].id)
        XCTAssertEqual(player.audio.rate, 0)
        let pausedItem = player.audio.currentItem
        player.append([entries[1], entries[2]])
        XCTAssertEqual(player.queue, [entries[3], entries[1], entries[2]])
        XCTAssertTrue(player.audio.currentItem === pausedItem)
        XCTAssertEqual(player.audio.rate, 0)
        player.select(2)
        XCTAssertEqual(player.current?.id, entries[2].id)
        XCTAssertEqual(player.queue, [entries[3], entries[1], entries[2]])
        player.next()
        XCTAssertEqual(player.current?.id, entries[3].id)
        XCTAssertEqual(player.queue, [entries[3], entries[1], entries[2]])
    }

    func testQueueTableMovesSelectionAndHandlesBothDeleteKeys() async throws {
        let store = LibraryStore()
        let entries = try playbackEntries() + playbackEntries() + playbackEntries()
        store.player.volume = 0
        store.player.replace(entries, startingAt: 0)
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { store.player.reset(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let view = try XCTUnwrap(window.contentView)
        let table = try XCTUnwrap(view.descendants(of: NSTableView.self).first)
        let tabs = try XCTUnwrap(view.descendants(of: NSSegmentedControl.self).first)
        tabs.selectedSegment = 3
        _ = tabs.sendAction(tabs.action, to: tabs.target)
        try await wait { table.numberOfRows == 6 }
        XCTAssertEqual(tabs.toolTip(forSegment: 3), "6 tracks remaining")
        XCTAssertEqual(tabs.image(forSegment: 3)?.accessibilityDescription, "6 tracks remaining")
        XCTAssertTrue(table.allowsMultipleSelection)
        table.sortDescriptors = [NSSortDescriptor(key: "Track", ascending: false)]
        try await wait { table.numberOfRows == 6 }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let rect = table.rect(ofRow: 1)
        let point = table.convert(NSPoint(x: 20, y: rect.midY), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                    modifierFlags: .control, timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(click)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 1]))
        XCTAssertTrue(controller.moveQueueSelection([entries[1].id, entries[3].id], above: 0))
        try await wait { table.numberOfRows == 6 && table.selectedRowIndexes == IndexSet([1, 2]) }
        XCTAssertEqual(store.player.queue, [entries[0], entries[1], entries[3], entries[2], entries[4], entries[5]])
        func pressDelete(_ code: UInt16, _ character: String) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)))
        }
        try pressDelete(51, "\u{7f}")
        try await wait { table.numberOfRows == 4 }
        XCTAssertEqual(store.player.queue, [entries[0], entries[2], entries[4], entries[5]])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try pressDelete(117, "\u{f728}")
        try await wait { table.numberOfRows == 3 && tabs.toolTip(forSegment: 3) == "3 tracks remaining" }
        XCTAssertEqual(store.player.queue, [entries[0], entries[4], entries[5]])
        // Playback order remains zero-based in the table after consuming the queue head.
        store.player.seek(to: 23.4)
        try await wait { table.numberOfRows == 2 && store.player.current?.id == entries[4].id }
        let writer = controller.tableView(table, pasteboardWriterForRow: 1) as? NSPasteboardItem
        XCTAssertEqual(writer?.string(forType: .init("org.cueplayer.queue-entry")), entries[5].id.uuidString)
        store.selectQueuedTrack(entries[5].id)
        XCTAssertEqual(store.player.current?.id, entries[5].id)
        XCTAssertTrue(controller.moveQueueSelection([entries[5].id], above: 0))
        XCTAssertEqual(store.player.queue, [entries[5], entries[4]])
    }

    func testSortedQueueKeepsIdentityAndRemembersColumnChoices() async throws {
        let suite = "CueQueueColumns-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults)
        store.player.volume = 0
        let entries = try playbackEntries() + playbackEntries().prefix(1)
        store.player.replace(entries, startingAt: 0)
        store.player.moveQueuedEntries([entries[2].id], to: 0)
        let controller = LibraryWindow(store: store)
        controller.showWindow(nil)
        defer { store.player.reset(); controller.close() }
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let tabs = try XCTUnwrap(root.descendants(of: NSSegmentedControl.self).first)
        let table = try XCTUnwrap(root.descendants(of: NSTableView.self).first)
        func tab(_ index: Int) {
            tabs.selectedSegment = index
            _ = tabs.sendAction(tabs.action, to: tabs.target)
        }
        func rowIsBold(_ row: Int) -> Bool {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
            return cell?.textField?.font?.fontDescriptor.symbolicTraits.contains(.bold) == true
        }
        tab(3)
        try await wait { table.numberOfRows == 3 && rowIsBold(1) }
        XCTAssertFalse(rowIsBold(0))
        XCTAssertFalse(rowIsBold(2))
        XCTAssertEqual(table.tableColumns.map(\.title), ["Track", "Artist", "Album", "Time"])
        let menu = try XCTUnwrap(tabs.menu)
        XCTAssertTrue(menu === table.headerView?.menu)
        let choice = try XCTUnwrap(menu.item(withTitle: "Disc"))
        XCTAssertEqual(choice.state, .off)
        menu.performActionForItem(at: menu.index(of: choice))
        XCTAssertEqual(menu.item(withTitle: "Disc")?.state, .on)
        XCTAssertTrue(table.tableColumns.allSatisfy { $0.sortDescriptorPrototype != nil })
        table.sortDescriptors = [NSSortDescriptor(key: "Track", ascending: false)]
        try await wait {
            table.numberOfRows == 3 && (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "Track 2"
        }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        XCTAssertEqual(store.player.current?.id, entries[1].id)
        XCTAssertEqual(store.player.queue, [entries[2], entries[0], entries[1]])
        XCTAssertEqual(tabs.toolTip(forSegment: 3), "3 tracks remaining")
        try await wait { rowIsBold(0) && !rowIsBold(2) && store.player.playing }
        XCTAssertEqual(table.selectedRow, 0)
        store.player.seek(to: 23.4)
        try await wait { table.numberOfRows == 2 && tabs.toolTip(forSegment: 3) == "2 tracks remaining" }
        XCTAssertEqual(store.player.queue, [entries[2], entries[0]])
        XCTAssertEqual(store.player.current?.id, entries[2].id)
        XCTAssertTrue(rowIsBold(0))
        XCTAssertFalse(rowIsBold(1))
        tab(0)
        XCTAssertNil(menu.item(withTitle: "Disc"))
        tab(3)
        XCTAssertTrue(table.tableColumns.contains { $0.title == "Disc" })
        XCTAssertEqual(defaults.stringArray(forKey: "columns.Queue")?.last, "Disc")
    }

    func testColumnOrderPersistsForEachView() throws {
        let suite = "CueColumnOrder-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Album", "Time", "Track", "Artist"], forKey: "columns.Queue")
        let controller = LibraryWindow(store: LibraryStore(defaults: defaults))
        controller.showWindow(nil)
        defer { controller.close() }
        let view = try XCTUnwrap(controller.window?.contentView)
        let tabs = try XCTUnwrap(view.descendants(of: NSSegmentedControl.self).first)
        let table = try XCTUnwrap(view.descendants(of: NSTableView.self).first)
        func selectTab(_ index: Int, on control: NSSegmentedControl) {
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
        }

        selectTab(3, on: tabs)
        XCTAssertTrue(table.allowsColumnReordering)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Track", "Artist", "Album", "Time"])
        table.moveColumn(3, toColumn: 0)
        let queueOrder = ["Time", "Track", "Artist", "Album"]
        XCTAssertEqual(table.tableColumns.map(\.title), queueOrder)
        XCTAssertEqual(Array(defaults.stringArray(forKey: "columnOrder.Queue")?.prefix(4) ?? []), queueOrder)

        let menu = try XCTUnwrap(tabs.menu)
        func toggleArtistColumn() throws {
            let item = try XCTUnwrap(menu.item(withTitle: "Artist"))
            menu.performActionForItem(at: menu.index(of: item))
        }
        try toggleArtistColumn()
        XCTAssertEqual(table.tableColumns.map(\.title), ["Time", "Track", "Album"])
        table.moveColumn(2, toColumn: 0)
        try toggleArtistColumn()
        let restoredOrder = ["Album", "Time", "Artist", "Track"]
        XCTAssertEqual(table.tableColumns.map(\.title), restoredOrder)

        selectTab(0, on: tabs)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Album", "Artist", "Year"])
        table.moveColumn(2, toColumn: 0)
        XCTAssertEqual(table.sortDescriptors.first?.key, "Artist")
        selectTab(3, on: tabs)
        XCTAssertEqual(table.tableColumns.map(\.title), restoredOrder)

        let reopened = LibraryWindow(store: LibraryStore(defaults: defaults))
        reopened.showWindow(nil)
        defer { reopened.close() }
        let reopenedView = try XCTUnwrap(reopened.window?.contentView)
        let reopenedTabs = try XCTUnwrap(reopenedView.descendants(of: NSSegmentedControl.self).first)
        let reopenedTable = try XCTUnwrap(reopenedView.descendants(of: NSTableView.self).first)
        XCTAssertEqual(reopenedTable.tableColumns.map(\.title), ["Year", "Album", "Artist"])
        selectTab(3, on: reopenedTabs)
        XCTAssertEqual(reopenedTable.tableColumns.map(\.title), restoredOrder)
    }

    private func wait(_ condition: String = "playback to reach the expected state", until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !ready() {
            guard Date() < deadline else { throw MusicError("Timed out waiting for \(condition).") }
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
