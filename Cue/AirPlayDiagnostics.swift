import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog

@MainActor
final class AirPlayDiagnostics {
    private let log = Logger(subsystem: "org.cueplayer.Minimal", category: "AirPlay")
    private var entries: [String] = []
    private weak var player: AVPlayer?
    private var playerObservations: [NSKeyValueObservation] = []
    private var itemErrors: AnyCancellable?
    private var lastPlaybackState: String?
    private var outputListener: AudioObjectPropertyListenerBlock?

    func record(_ event: String) {
        if entries.count == 100 { entries.removeFirst() }
        entries.append("\(Date().formatted(.iso8601))  \(event)")
        log.notice("\(event, privacy: .public)")
    }

    func observePlayer(_ player: AVPlayer?) {
        self.player = player
        playerObservations.removeAll()
        lastPlaybackState = nil
        guard let player else {
            itemErrors = nil
            record("Audio player released")
            return
        }
        watchDefaultOutput()
        record("Audio player created; \(Self.defaultOutput)")
        func observe<Value>(_ keyPath: KeyPath<AVPlayer, Value>) -> NSKeyValueObservation {
            player.observe(keyPath, options: [.new]) { [weak self] observed, _ in
                Task { @MainActor in
                    guard let self, self.player === observed else { return }
                    let state = self.playbackState
                    guard state != self.lastPlaybackState else { return }
                    self.lastPlaybackState = state
                    self.record("Playback state: \(state)")
                }
            }
        }
        playerObservations = [
            observe(\.timeControlStatus),
            observe(\.reasonForWaitingToPlay),
            observe(\.isExternalPlaybackActive),
            observe(\.audioOutputDeviceUniqueID)
        ]
    }

    func observeItem(_ item: AVPlayerItem) {
        record("Playback item loaded")
        itemErrors = NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: item)
            .receive(on: RunLoop.main).sink { [weak self, weak item] _ in
                guard let self, let item, self.player?.currentItem === item,
                      let event = item.errorLog()?.events.last else { return }
                self.recordError("Media error log", domain: event.errorDomain, code: event.errorStatusCode)
            }
    }

    func recordFailure(_ event: String, error: Error?) {
        guard let error = error as NSError? else {
            record(event)
            return
        }
        recordError(event, domain: error.domain, code: error.code)
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            recordError("Underlying error", domain: underlying.domain, code: underlying.code)
        }
    }

    private func recordError(_ event: String, domain: String, code: Int) {
        let knownDomains = [AVFoundationErrorDomain, NSURLErrorDomain, NSOSStatusErrorDomain,
                            NSCocoaErrorDomain, NSPOSIXErrorDomain, "CoreMediaErrorDomain"]
        let safeDomain = knownDomains.contains(domain) ? domain : "other domain"
        record("\(event): \(safeDomain) (\(code))")
    }

    func pickerOpened(_ location: String) {
        record("Route picker opened (\(location)): \(playbackState); \(Self.defaultOutput)")
    }

    func pickerClosed(_ location: String) {
        record("Route picker closed (\(location)): \(playbackState); \(Self.defaultOutput)")
    }

    var report: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let header = [
            "Cue \(version) AirPlay diagnostics",
            ProcessInfo.processInfo.operatingSystemVersionString,
            "At copy time: \(playbackState); \(Self.defaultOutput)",
            ""
        ]
        return (header + entries).joined(separator: "\n")
    }

    private var playbackState: String {
        guard let player else { return "no audio player" }
        let state: String
        switch player.timeControlStatus {
        case .paused: state = "paused"
        case .playing: state = "playing"
        case .waitingToPlayAtSpecifiedRate:
            state = "waiting (\(player.reasonForWaitingToPlay?.rawValue ?? "reason unavailable"))"
        @unknown default: state = "unknown"
        }
        let volume = Int((player.volume * 100).rounded())
        return "\(state), item loaded=\(player.currentItem != nil), volume=\(volume)%, muted=\(player.isMuted)" +
            ", explicit audio output=\(player.audioOutputDeviceUniqueID != nil), external video playback=\(player.isExternalPlaybackActive)"
    }

    private nonisolated static var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func watchDefaultOutput() {
        guard outputListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.record("Default output changed: \(Self.defaultOutput)") }
        }
        var address = Self.outputAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if status == noErr { outputListener = listener }
        else { record("Default output observation unavailable (OSStatus \(status))") }
    }

    private static var defaultOutput: String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var address = outputAddress
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let deviceStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard deviceStatus == noErr else { return "macOS default output unavailable (OSStatus \(deviceStatus))" }
        guard device != kAudioObjectUnknown else { return "no macOS default output" }
        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        guard transportStatus == noErr else { return "macOS default output type unavailable (OSStatus \(transportStatus))" }
        let type: String
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: type = "AirPlay"
        case kAudioDeviceTransportTypeBuiltIn: type = "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: type = "Bluetooth"
        case kAudioDeviceTransportTypeUSB: type = "USB"
        case kAudioDeviceTransportTypeHDMI: type = "HDMI"
        default: type = "0x" + String(transport, radix: 16)
        }
        return "macOS default output: \(type)"
    }

    deinit {
        if let outputListener {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
        }
    }
}
