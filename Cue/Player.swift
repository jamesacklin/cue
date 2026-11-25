import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [QueueEntry] = []
    @Published private(set) var current: QueueEntry?
    @Published private(set) var playing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var length = 0.0
    @Published var error: String?
    @Published var volume: Double = 0.7 {
        didSet { engine?.volume = Float(volume) }
    }
    let routePlayer = CurrentValueSubject<AVPlayer?, Never>(nil)
    private var engine: AVPlayer? {
        didSet {
            airPlayDiagnostics.observePlayer(engine)
            routePlayer.send(engine)
        }
    }
    private var clock: Any?
    private var progressVisible = true
    private var end: AnyCancellable?
    private var failure: AnyCancellable?
    private var stall: AnyCancellable?
    private var itemStatus: NSKeyValueObservation?
    private var playStatus: NSKeyValueObservation?
    private var finished = false
    private var history: [QueueEntry] = []
    private var systemTransport: SystemTransport?
    private let log = Logger(subsystem: "org.cueplayer.Minimal", category: "Playback")

    let airPlayDiagnostics = AirPlayDiagnostics()

    let equalizer: Equalizer

    init(defaults: UserDefaults = .standard) {
        equalizer = Equalizer(defaults: defaults)
    }

    var hasNext: Bool { nextPosition != nil }

    private var nextPosition: Int? { queue.firstIndex { $0.id != current?.id } }

    var audio: AVPlayer {
        if let engine { return engine }
        let audio = AVPlayer()
        engine = audio
        audio.volume = Float(volume)
        updateClock()
        playStatus = audio.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.engine.map { $0.timeControlStatus != .paused } ?? false
                self.updateSystemTransport()
            }
        }
        return audio
    }

    func setProgressVisible(_ visible: Bool) {
        guard progressVisible != visible else { return }
        progressVisible = visible
        updateClock()
    }

    private func updateClock() {
        guard let audio = engine else { return }
        if !progressVisible {
            if let clock { audio.removeTimeObserver(clock) }
            clock = nil
            return
        }
        guard clock == nil else { return }
        syncProgress()
        clock = audio.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncProgress() }
        }
    }

    private func syncProgress() {
        guard progressVisible, let item = engine?.currentItem else { return }
        // Read the current item even if a callback was queued before a seek or track change.
        let seconds = item.currentTime().seconds
        if seconds.isFinite, seconds >= 0, seconds != elapsed { elapsed = seconds }
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            let measured = (duration * 1000).rounded() / 1000
            if measured != length { length = measured; updateSystemTransport() }
        }
    }

    func replace(_ entries: [QueueEntry], startingAt index: Int) {
        guard entries.indices.contains(index) else { return }
        history.removeAll()
        queue = Array(entries.dropFirst(index))
        start(entries[index])
    }

    func append(_ entries: [QueueEntry]) {
        guard let first = entries.first else { return }
        if current == nil || finished {
            if let current { history.append(current) }
            queue = entries
            start(first)
        } else {
            queue.append(contentsOf: entries)
            updateSystemTransport()
        }
    }

    func moveQueuedEntries(_ ids: [UUID], to boundary: Int) {
        guard (0...queue.count).contains(boundary), !ids.isEmpty else { return }
        let selected = Set(ids)
        let entries = Dictionary(uniqueKeysWithValues: queue.filter { selected.contains($0.id) }.map { ($0.id, $0) })
        guard entries.count == ids.count else { return }
        let insertion = queue.prefix(boundary).filter { !selected.contains($0.id) }.count
        var reordered = queue.filter { !selected.contains($0.id) }
        reordered.insert(contentsOf: ids.compactMap { entries[$0] }, at: insertion)
        guard reordered != queue else { return }
        queue = reordered
    }

    func removeQueuedEntries(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let remaining = queue.filter { !ids.contains($0.id) }
        guard remaining.count < queue.count else { return }
        queue = remaining
        updateSystemTransport()
    }

    func select(_ position: Int) {
        guard queue.indices.contains(position) else { return }
        let entry = queue[position]
        if let current, current.id != entry.id { history.append(current) }
        start(entry)
    }

    private func start(_ entry: QueueEntry) {
        current = entry
        elapsed = 0
        finished = false
        error = nil
        length = entry.track.duration
        let item = AVPlayerItem(url: entry.url)
        item.preferredForwardBufferDuration = 5
        airPlayDiagnostics.observeItem(item)
        end = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.engine?.currentItem === item else { return }
                self.removeQueuedEntries([entry.id])
                if self.hasNext { self.next() }
                else { self.finished = true; self.audio.pause() }
            }
        failure = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] notification in
                guard let self, let item, self.engine?.currentItem === item else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? item.error
                self.airPlayDiagnostics.recordFailure("Playback failed before the end of the item", error: error)
                self.playbackFailed()
            }
        stall = NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.engine?.currentItem === item else { return }
                self.log.notice("Playback stalled while waiting for media data")
                self.airPlayDiagnostics.record("Playback stalled (buffer empty=\(item.isPlaybackBufferEmpty)" +
                                               ", likely to keep up=\(item.isPlaybackLikelyToKeepUp))")
            }
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.engine?.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.airPlayDiagnostics.record("Playback item ready")
                } else if item.status == .failed {
                    self.airPlayDiagnostics.recordFailure("Playback item failed", error: item.error)
                    self.playbackFailed()
                }
            }
        }
        equalizer.attach(to: item)
        audio.replaceCurrentItem(with: item)
        if systemTransport == nil { systemTransport = SystemTransport(player: self) }
        audio.play()
        updateSystemTransport(position: 0)
    }

    private func updateSystemTransport(position: Double? = nil) {
        guard let engine, let systemTransport else { return }
        let time = position ?? engine.currentTime().seconds
        let rate = engine.timeControlStatus == .playing ? Double(engine.rate) : 0
        systemTransport.update(position: time.isFinite ? time : elapsed, rate: rate)
    }

    private func playbackFailed() {
        audio.pause()
        error = "Couldn’t play this track. Check the server connection and that macOS supports the audio format."
    }

    func toggle() {
        guard let engine else { return }
        if engine.timeControlStatus == .paused { resume() } else { pause() }
    }

    func pause() { engine?.pause() }

    func resume() {
        guard let current else { return }
        if finished {
            queue.insert(current, at: 0)
            start(current)
        } else if audio.currentItem?.status == .failed || error != nil { start(current) }
        else { audio.play() }
    }

    func previous() {
        guard let current else { return }
        let position = engine?.currentTime().seconds ?? elapsed
        if position > 3 || history.isEmpty {
            seek(to: 0)
        } else if let previous = history.popLast() {
            if !queue.contains(where: { $0.id == previous.id }) { queue.insert(previous, at: 0) }
            start(previous)
        }
    }

    func next() { if let nextPosition { select(nextPosition) } }

    func seek(to time: Double) {
        guard let current, time.isFinite else { return }
        if finished {
            queue.insert(current, at: 0)
            finished = false
        }
        elapsed = min(length, max(0, time))
        audio.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateSystemTransport(position: elapsed)
    }

    func reset() {
        equalizer.attach(to: nil)
        systemTransport = nil
        end = nil
        failure = nil
        stall = nil
        itemStatus = nil
        engine?.pause()
        engine?.replaceCurrentItem(with: nil)
        if let clock { engine?.removeTimeObserver(clock) }
        clock = nil
        playStatus = nil
        engine = nil
        current = nil
        queue = []
        history.removeAll()
        playing = false
        finished = false
        error = nil
        elapsed = 0
        length = 0
    }

    deinit {
        if let clock { engine?.removeTimeObserver(clock) }
    }
}
