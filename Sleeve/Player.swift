import AVFoundation
import Combine
import Foundation

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [QueueEntry] = []
    @Published private(set) var index: Int?
    @Published private(set) var playing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var length = 0.0
    @Published var error: String?
    @Published var volume: Double = 0.7 {
        didSet { audio.volume = Float(volume) }
    }
    private let audio = AVPlayer()
    private var clock: Any?
    private var end: AnyCancellable?
    private var failure: AnyCancellable?
    private var itemStatus: NSKeyValueObservation?
    private var playStatus: NSKeyValueObservation?
    private var finished = false

    var current: QueueEntry? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    var hasNext: Bool { index.map { $0 + 1 < queue.count } ?? false }

    init() {
        audio.volume = Float(volume)
        clock = audio.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.4, preferredTimescale: 600),
                                              queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let item = self.audio.currentItem else { return }
                let seconds = item.currentTime().seconds
                if seconds.isFinite { self.elapsed = max(0, seconds) }
                let duration = item.duration.seconds
                if duration.isFinite, duration > 0 {
                    self.length = (duration * 1000).rounded() / 1000
                }
            }
        }
        playStatus = audio.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = self.audio.timeControlStatus != .paused
            }
        }
    }

    func replace(_ entries: [QueueEntry], startingAt index: Int) {
        guard entries.indices.contains(index) else { return }
        queue = entries
        select(index)
    }

    func select(_ position: Int) {
        guard queue.indices.contains(position) else { return }
        let entry = queue[position]
        index = position
        elapsed = 0
        finished = false
        error = nil
        length = entry.track.duration
        let item = AVPlayerItem(url: entry.url)
        end = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.audio.currentItem === item else { return }
                if self.hasNext { self.select(position + 1) }
                else { self.finished = true; self.audio.pause() }
            }
        failure = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.audio.currentItem === item else { return }
                self.playbackFailed()
            }
        itemStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.audio.currentItem === item, item.status == .failed else { return }
                self.playbackFailed()
            }
        }
        audio.replaceCurrentItem(with: item)
        audio.play()
    }

    private func playbackFailed() {
        audio.pause()
        error = "Couldn’t play this track. Check the server connection and that macOS supports the audio format."
    }

    func toggle() {
        guard let index else { return }
        if playing { audio.pause() }
        else if finished || audio.currentItem?.status == .failed || error != nil { select(index) }
        else { audio.play() }
    }

    func previous() {
        guard let index else { return }
        if elapsed > 3 || index == 0 { seek(to: 0) }
        else { select(index - 1) }
    }

    func next() { if let index, hasNext { select(index + 1) } }

    func seek(to time: Double) {
        guard current != nil, time.isFinite else { return }
        finished = false
        elapsed = min(length, max(0, time))
        audio.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func reset() {
        end = nil
        failure = nil
        itemStatus = nil
        audio.pause()
        audio.replaceCurrentItem(with: nil)
        index = nil
        queue = []
        playing = false
        finished = false
        error = nil
        elapsed = 0
        length = 0
    }

    deinit {
        if let clock { audio.removeTimeObserver(clock) }
    }
}
