import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class Player: ObservableObject {
    private(set) var queueRevision = 0
    @Published private(set) var queue: ArraySlice<QueueEntry> = [] {
        didSet { queueRevision &+= 1 }
    }
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
    private var itemDuration: NSKeyValueObservation?
    private var itemStatus: NSKeyValueObservation?
    private var playStatus: NSKeyValueObservation?
    var mediaURL: ((QueueEntry) -> URL)?
    var diagnoseMedia: ((URL) async -> PlexFailure?)?
    var requestSignIn: (() -> Void)?
    private var diagnosis: Task<Void, Never>?
    private var stallTimeout: Task<Void, Never>?
    private var retryPosition: Double?
    private var wantsPlayback = false
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

    private var nextPosition: Int? { queue.firstIndex { $0.id != current?.id }.map { $0 - queue.startIndex } }

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
        guard progressVisible, retryPosition == nil, let item = engine?.currentItem else { return }
        // Read the current item even if a callback was queued before a seek or track change.
        let seconds = item.currentTime().seconds
        if seconds.isFinite, seconds >= 0, seconds != elapsed { elapsed = seconds }
    }

    func replace(_ entries: [QueueEntry], startingAt index: Int) {
        guard entries.indices.contains(index) else { return }
        history.removeAll()
        queue = index == 0 ? entries[...] : Array(entries[index...])[...]
        start(entries[index])
    }

    func append(_ entries: [QueueEntry]) {
        guard let first = entries.first else { return }
        if current == nil || finished {
            if let current { history.append(current) }
            queue = entries[...]
            start(first)
        } else {
            queue.append(contentsOf: entries)
            updateSystemTransport()
        }
    }

    func moveQueuedEntries(_ ids: [UUID], to boundary: Int) {
        guard (0...queue.count).contains(boundary), !ids.isEmpty else { return }
        let selected = Set(ids)
        guard selected.count == ids.count else { return }
        var moved: [UUID: QueueEntry] = [:]
        var insertion = boundary
        var reordered: [QueueEntry] = []
        reordered.reserveCapacity(queue.count)
        for (position, entry) in queue.enumerated() {
            if selected.contains(entry.id) {
                moved[entry.id] = entry
                if position < boundary { insertion -= 1 }
            } else {
                reordered.append(entry)
            }
        }
        guard moved.count == ids.count else { return }
        reordered.insert(contentsOf: ids.compactMap { moved[$0] }, at: insertion)
        guard !reordered.elementsEqual(queue, by: { $0.id == $1.id }) else { return }
        queue = reordered[...]
    }

    func removeQueuedEntries(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let remaining = queue.filter { !ids.contains($0.id) }
        guard remaining.count < queue.count else { return }
        queue = remaining[...]
        updateSystemTransport()
    }

    private func finishQueuedEntry(_ id: UUID) {
        guard queue.first?.id == id else {
            if let index = queue.firstIndex(where: { $0.id == id }) { queue.remove(at: index) }
            return
        }
        let tail = queue.dropFirst()
        // Advance in constant time. Occasionally release a mostly consumed backing array.
        if tail.isEmpty { queue = [] }
        else if tail.startIndex >= 256 && tail.startIndex >= tail.count { queue = Array(tail)[...] }
        else { queue = tail }
    }

    func select(_ position: Int) {
        guard (0..<queue.count).contains(position) else { return }
        let entry = queue[position: position]
        if let current, current.id != entry.id { history.append(current) }
        start(entry)
    }

    private func start(_ entry: QueueEntry, at position: Double = 0, play: Bool = true) {
        diagnosis?.cancel()
        stallTimeout?.cancel()
        retryPosition = nil
        wantsPlayback = play
        current = entry
        elapsed = position
        finished = false
        error = nil
        length = entry.track.duration
        let url = mediaURL?(entry) ?? entry.url
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 5
        airPlayDiagnostics.observeItem(item)
        end = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.engine?.currentItem === item else { return }
                guard self.retryPosition == nil else { return }
                self.finishQueuedEntry(entry.id)
                if self.hasNext { self.next() }
                else { self.finished = true; self.audio.pause() }
            }
        failure = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] notification in
                guard let self, let item, self.engine?.currentItem === item else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error ?? item.error
                self.airPlayDiagnostics.recordFailure("Playback failed before the end of the item", error: error)
                self.playbackFailed(item, url: url, cause: error)
            }
        stall = NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.engine?.currentItem === item else { return }
                self.log.notice("Playback stalled while waiting for media data")
                self.airPlayDiagnostics.record("Playback stalled (buffer empty=\(item.isPlaybackBufferEmpty)" +
                                               ", likely to keep up=\(item.isPlaybackLikelyToKeepUp))")
                self.monitorStall(item, url: url)
            }
        itemDuration = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.engine?.currentItem === item else { return }
                let duration = item.duration.seconds
                guard duration.isFinite, duration > 0 else { return }
                let catalog = entry.track.duration
                // Some files load with a doubled duration. Allow for rounding in
                // either source, with a tighter tolerance for short tracks.
                let doubled = catalog > 0 && abs(duration / 2 - catalog) <= min(1, catalog * 0.01)
                let length = doubled ? catalog : (duration * 1000).rounded() / 1000
                let endTime = doubled ? CMTime(seconds: catalog, preferredTimescale: 1000) : .invalid
                // Changing the end time can trigger another duration observation.
                if item.forwardPlaybackEndTime != endTime { item.forwardPlaybackEndTime = endTime }
                if length != self.length { self.length = length; self.updateSystemTransport() }
            }
        }
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.engine?.currentItem === item else { return }
                if item.status == .readyToPlay {
                    self.airPlayDiagnostics.record("Playback item ready")
                } else if item.status == .failed {
                    self.airPlayDiagnostics.recordFailure("Playback item failed", error: item.error)
                    self.playbackFailed(item, url: url, cause: item.error)
                }
            }
        }
        equalizer.attach(to: item)
        audio.replaceCurrentItem(with: item)
        if systemTransport == nil { systemTransport = SystemTransport(player: self) }
        if position > 0 {
            audio.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if play { audio.play() } else { audio.pause() }
        updateSystemTransport(position: position)
    }

    private func updateSystemTransport(position: Double? = nil) {
        guard let engine, let systemTransport else { return }
        let time = position ?? engine.currentTime().seconds
        let rate = engine.timeControlStatus == .playing ? Double(engine.rate) : 0
        systemTransport.update(position: time.isFinite ? time : elapsed, rate: rate)
    }

    private func monitorStall(_ item: AVPlayerItem, url: URL) {
        guard wantsPlayback, retryPosition == nil else { return }
        stallTimeout?.cancel()
        let position = item.currentTime()
        stallTimeout = Task { [weak self, weak item] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let item, engine?.currentItem === item,
                  wantsPlayback, !finished, item.currentTime() == position,
                  engine?.timeControlStatus != .playing else { return }
            playbackFailed(item, url: url, cause: URLError(.timedOut))
        }
    }

    private func playbackFailed(_ item: AVPlayerItem, url: URL, cause: Error?) {
        guard retryPosition == nil, !finished, let entry = current else { return }
        let time = item.currentTime().seconds
        let position = time.isFinite && time > 0 ? time : elapsed
        retryPosition = position
        elapsed = position
        audio.pause()
        if PlexFailure.isConnectionLoss(cause as NSError?) {
            error = "Connection lost. Press Play to retry from here."
            return
        }

        error = "Playback interrupted. Press Play to retry."
        diagnosis = Task { [weak self, weak item, diagnoseMedia] in
            let failure = await diagnoseMedia?(url)
            guard !Task.isCancelled, let self, let item, engine?.currentItem === item,
                  (mediaURL?(entry) ?? entry.url) == url else { return }
            switch failure {
            case .missing:
                finishQueuedEntry(entry.id)
                if let next = queue.first { start(next, play: wantsPlayback) }
                else {
                    reset()
                    error = "“\(entry.track.title)” is no longer available on Plex."
                }
            case .unauthorized:
                error = "Press Play to resume after signing in to Plex."
                requestSignIn?()
            case .forbidden, .unavailable: error = failure?.localizedDescription
            case .disconnected: error = "Connection lost. Press Play to retry from here."
            case nil: error = "Couldn’t play this track. Check its file or press Play to retry."
            }
        }
    }

    func toggle() {
        guard let engine else { return }
        if engine.timeControlStatus == .paused { resume() } else { pause() }
    }

    func pause() {
        wantsPlayback = false
        stallTimeout?.cancel()
        engine?.pause()
    }

    func resume() {
        guard let current else { return }
        if finished {
            queue.insert(current, at: queue.startIndex)
            start(current)
        } else if let retryPosition {
            start(current, at: retryPosition)
        } else if audio.currentItem?.status == .failed {
            start(current, at: elapsed)
        } else {
            wantsPlayback = true
            audio.play()
        }
    }

    func previous() {
        guard current != nil else { return }
        let position = retryPosition ?? engine?.currentTime().seconds ?? elapsed
        if position > 3 || history.isEmpty {
            seek(to: 0)
        } else if let previous = history.popLast() {
            if !queue.contains(where: { $0.id == previous.id }) { queue.insert(previous, at: queue.startIndex) }
            start(previous)
        }
    }

    func next() { if let nextPosition { select(nextPosition) } }

    func seek(to time: Double) {
        guard let current, time.isFinite else { return }
        if finished {
            queue.insert(current, at: queue.startIndex)
            finished = false
        }
        elapsed = min(length, max(0, time))
        if retryPosition != nil { retryPosition = elapsed }
        else { audio.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        updateSystemTransport(position: elapsed)
    }

    func reset() {
        diagnosis?.cancel()
        diagnosis = nil
        stallTimeout?.cancel()
        stallTimeout = nil
        retryPosition = nil
        wantsPlayback = false
        equalizer.attach(to: nil)
        systemTransport = nil
        end = nil
        failure = nil
        stall = nil
        itemStatus = nil
        itemDuration = nil
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
