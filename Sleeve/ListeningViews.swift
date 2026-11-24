import AppKit
import AVKit
import Combine

@MainActor
final class Transport: NSStackView {
    let player: Player
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let seek = NSSlider()
    private let volume = NSSlider()
    private var playButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var subscriptions = Set<AnyCancellable>()

    init(player: Player) {
        self.player = player
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        edgeInsets = .init(top: 9, left: 12, bottom: 10, right: 12)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(title)
        let controls = NSStackView()
        controls.spacing = 6
        func button(_ name: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: name, target: self, action: action)
            button.controlSize = .small
            controls.addArrangedSubview(button)
            return button
        }
        previousButton = button("Previous", #selector(previous))
        playButton = button("Play", #selector(toggle))
        playButton.widthAnchor.constraint(equalToConstant: 55).isActive = true
        nextButton = button("Next", #selector(next))
        seek.controlSize = .small
        seek.setAccessibilityLabel("Playback position")
        seek.isContinuous = false
        seek.target = self
        seek.action = #selector(scrub)
        seek.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.addArrangedSubview(seek)
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        controls.addArrangedSubview(time)
        controls.setCustomSpacing(16, after: time)
        let label = NSTextField(labelWithString: "Volume")
        label.font = .systemFont(ofSize: 11)
        controls.addArrangedSubview(label)
        volume.controlSize = .small
        volume.maxValue = 1
        volume.doubleValue = player.volume
        volume.target = self
        volume.action = #selector(setVolume)
        volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(equalToConstant: 70).isActive = true
        controls.addArrangedSubview(volume)
        addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
        title.widthAnchor.constraint(lessThanOrEqualTo: controls.widthAnchor).isActive = true
        // A clock tick only moves the scrubber and the time label.
        Publishers.CombineLatest(player.$elapsed, player.$length)
            .sink { [weak self] elapsed, length in self?.renderTime(elapsed, length) }
            .store(in: &subscriptions)
        Publishers.CombineLatest4(player.$queue, player.$index, player.$playing, player.$error)
            .sink { [weak self] queue, index, playing, error in
                let current = index.flatMap { queue.indices.contains($0) ? queue[$0] : nil }
                self?.render(current, playing: playing, error: error, hasNext: index.map { $0 + 1 < queue.count } ?? false)
            }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func render(_ current: QueueEntry?, playing: Bool, error: String?, hasNext: Bool) {
        title.stringValue = error ?? current.map { "\($0.track.artist) — \($0.track.title)" } ?? "Stopped"
        title.toolTip = title.stringValue
        playButton.title = playing ? "Pause" : "Play"
        previousButton.isEnabled = current != nil
        playButton.isEnabled = current != nil
        nextButton.isEnabled = hasNext
    }

    private func renderTime(_ elapsed: Double, _ length: Double) {
        let maximum = max(1, length)
        if seek.maxValue != maximum { seek.maxValue = maximum }
        seek.isEnabled = player.current != nil && length > 0
        if !seek.isHighlighted { seek.doubleValue = elapsed }
        time.stringValue = "\(timeLabel(elapsed)) / \(timeLabel(length.rounded()))"
    }
    @objc private func previous() { player.previous() }
    @objc private func toggle() { player.toggle() }
    @objc private func next() { player.next() }
    @objc private func scrub() { player.seek(to: seek.doubleValue) }
    @objc private func setVolume() { player.volume = volume.doubleValue }
}

@MainActor
func showOutputPicker(for player: Player, in window: NSWindow) {
    let alert = NSAlert()
    alert.messageText = "Audio Output"
    let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 38, height: 30))
    picker.player = player.audio
    alert.accessoryView = picker
    alert.addButton(withTitle: "Done")
    alert.beginSheetModal(for: window)
}
