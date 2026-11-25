import AVFoundation
import Combine

@MainActor
final class Equalizer {
    static let frequencies = (0..<Int(CueEQBandCount)).map { Int(CueEQFrequency(UInt32($0))) }
    private let defaults: UserDefaults
    private(set) var gains: [Double]
    private(set) var enabled: Bool
    @Published private(set) var message: String?
    private weak var item: AVPlayerItem?
    private var installation: Task<Void, Never>?
    private var tap: MTAudioProcessingTap?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.array(forKey: "equalizer.gains") as? [Double]
        gains = Self.frequencies.indices.map { i in
            guard let saved, saved.indices.contains(i), saved[i].isFinite else { return 0 }
            return min(12, max(-12, saved[i]))
        }
        enabled = defaults.bool(forKey: "equalizer.enabled")
    }

    func attach(to item: AVPlayerItem?) {
        installation?.cancel()
        installation = nil
        tap = nil
        message = nil
        self.item = item
        installIfNeeded()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "equalizer.enabled")
        applyGains()
        if value { installIfNeeded() }
        else { message = nil }
    }

    func setGain(_ value: Double, band: Int) {
        guard gains.indices.contains(band), value.isFinite else { return }
        let gain = min(12, max(-12, value))
        guard gains[band] != gain else { return }
        gains[band] = gain
        defaults.set(gains, forKey: "equalizer.gains")
        if let tap, enabled { CueEQSetGain(tap, UInt32(band), Float(gains[band])) }
    }

    func flatten() {
        gains = Array(repeating: 0, count: gains.count)
        defaults.set(gains, forKey: "equalizer.gains")
        applyGains()
    }

    private func applyGains() {
        guard let tap else { return }
        for i in gains.indices { CueEQSetGain(tap, UInt32(i), enabled ? Float(gains[i]) : 0) }
    }

    private func installIfNeeded() {
        guard enabled, tap == nil, installation == nil, let item else { return }
        installation = Task { [weak self, weak item] in
            guard let item else { return }
            let track = try? await item.asset.loadTracks(withMediaType: .audio).first
            guard !Task.isCancelled, let self, self.item === item else { return }
            installation = nil
            guard enabled else { return }
            guard let track, let processor = CueEQCreateTap() else {
                message = "Equalizer unavailable for this track."
                return
            }
            tap = processor
            applyGains()
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = processor
            let mix = AVMutableAudioMix()
            mix.inputParameters = [input]
            item.audioMix = mix
            message = nil
        }
    }
}
