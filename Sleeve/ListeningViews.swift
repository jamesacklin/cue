import AppKit
import AVKit
import Combine

private final class SeekSlider: NSSlider {
    private(set) var isScrubbing = false

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        defer { isScrubbing = false }
        super.mouseDown(with: event)
    }
}

@MainActor
final class Transport: NSStackView, @preconcurrency AVRoutePickerViewDelegate {
    let player: Player
    private let title = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let seek = SeekSlider()
    private let volume = NSSlider()
    private var playButton: NSButton!
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private let airPlay = AVRoutePickerView()
    private let playImage = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    private let pauseImage = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
    var canStartSelection = false {
        didSet { playButton.isEnabled = player.current != nil || canStartSelection }
    }
    private var subscriptions = Set<AnyCancellable>()

    init(player: Player, target: AnyObject, action: Selector) {
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
        func button(_ name: String, image: NSImage?, target: AnyObject, action: Selector) -> NSButton {
            let button = NSButton(title: "", target: target, action: action)
            button.image = image
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.toolTip = name
            button.setAccessibilityLabel(name)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            controls.addArrangedSubview(button)
            return button
        }
        previousButton = button("Previous track", image: NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: nil),
                                target: self, action: #selector(previous))
        playButton = button("Play", image: playImage, target: target, action: action)
        nextButton = button("Next track", image: NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil),
                            target: self, action: #selector(next))
        airPlay.delegate = self
        airPlay.isRoutePickerButtonBordered = false
        airPlay.toolTip = "AirPlay"
        airPlay.widthAnchor.constraint(equalToConstant: 28).isActive = true
        airPlay.heightAnchor.constraint(equalToConstant: 26).isActive = true
        controls.addArrangedSubview(airPlay)
        controls.setCustomSpacing(12, after: airPlay)
        player.routePlayer.sink { [weak airPlay] engine in airPlay?.player = engine }
            .store(in: &subscriptions)
        seek.isVertical = false
        seek.trackFillColor = .controlAccentColor
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
        let action = playing ? "Pause" : "Play"
        playButton.image = playing ? pauseImage : playImage
        playButton.toolTip = action
        playButton.setAccessibilityLabel(action)
        previousButton.isEnabled = current != nil
        playButton.isEnabled = current != nil || canStartSelection
        nextButton.isEnabled = hasNext
    }

    private func renderTime(_ elapsed: Double, _ length: Double) {
        let maximum = max(1, length)
        if seek.maxValue != maximum { seek.maxValue = maximum }
        seek.isEnabled = player.current != nil && length > 0
        if !seek.isScrubbing, seek.doubleValue != elapsed { seek.doubleValue = elapsed }
        let display = "\(timeLabel(elapsed)) / \(timeLabel(length.rounded()))"
        if time.stringValue != display { time.stringValue = display }
    }
    @objc private func previous() { player.previous() }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        routePickerView.player = player.audio
    }
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
