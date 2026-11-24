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
    private var observation: AnyCancellable?

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
        render()
        observation = player.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in self?.render() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        let current = player.current
        title.stringValue = player.error ?? current.map { "\($0.track.artist) — \($0.track.title)" } ?? "Stopped"
        title.toolTip = title.stringValue
        playButton.title = player.playing ? "Pause" : "Play"
        previousButton.isEnabled = current != nil
        playButton.isEnabled = current != nil
        nextButton.isEnabled = player.hasNext
        seek.isEnabled = current != nil && player.length > 0
        seek.maxValue = max(1, player.length)
        if !seek.isHighlighted { seek.doubleValue = player.elapsed }
        time.stringValue = "\(timeLabel(player.elapsed)) / \(timeLabel(player.length.rounded()))"
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
