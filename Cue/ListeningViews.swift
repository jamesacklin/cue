import AppKit
import AVKit
import Combine

@MainActor
func drawWindowGradient(in view: NSView, reversed: Bool = false) {
    if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        return
    }
    let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let light = NSColor(srgbRed: dark ? 0.24 : 0.93, green: dark ? 0.24 : 0.93, blue: dark ? 0.25 : 0.94, alpha: 1)
    let deep = NSColor(srgbRed: dark ? 0.15 : 0.80, green: dark ? 0.15 : 0.80, blue: dark ? 0.16 : 0.81, alpha: 1)
    let bounds = view.bounds
    let top = NSPoint(x: bounds.midX, y: view.isFlipped ? bounds.minY : bounds.maxY)
    let bottom = NSPoint(x: bounds.midX, y: view.isFlipped ? bounds.maxY : bounds.minY)
    NSGradient(starting: light, ending: deep)?.draw(
        from: reversed ? bottom : top,
        to: reversed ? top : bottom,
        options: []
    )
}

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
        didSet { if oldValue != canStartSelection { playButton.isEnabled = player.current != nil || canStartSelection } }
    }
    private var displayedSeconds: (elapsed: Int, length: Int)?
    private var subscriptions = Set<AnyCancellable>()

    init(player: Player, target: AnyObject, action: Selector) {
        self.player = player
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
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
        time.textColor = .secondaryLabelColor
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        controls.addArrangedSubview(time)
        controls.setCustomSpacing(16, after: time)
        if let speaker = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil) {
            let label = NSImageView(image: speaker)
            label.contentTintColor = .secondaryLabelColor
            label.setAccessibilityElement(false)
            controls.addArrangedSubview(label)
        }
        volume.controlSize = .small
        volume.maxValue = 1
        volume.doubleValue = player.volume
        volume.target = self
        volume.action = #selector(setVolume)
        volume.setAccessibilityLabel("Volume")
        volume.setAccessibilityValueDescription(player.volume.formatted(.percent))
        volume.widthAnchor.constraint(equalToConstant: 70).isActive = true
        controls.addArrangedSubview(volume)
        addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: widthAnchor, constant: -24).isActive = true
        title.widthAnchor.constraint(lessThanOrEqualTo: controls.widthAnchor).isActive = true
        // A clock tick only moves the scrubber and the time label.
        Publishers.CombineLatest(player.$elapsed, player.$length)
            .sink { [weak self] elapsed, length in self?.renderTime(elapsed, length) }
            .store(in: &subscriptions)
        Publishers.CombineLatest3(player.$current, player.$playing.removeDuplicates(), player.$error.removeDuplicates())
            .sink { [weak self] current, playing, error in
                self?.render(current, playing: playing, error: error)
            }.store(in: &subscriptions)
        let queueSummary = player.$queue.map { queue in
            (count: queue.count, firstID: queue.first?.id)
        }
        let currentID = player.$current.map { $0?.id }
        queueSummary.combineLatest(currentID)
            .map { summary, id -> Bool in
                summary.count > 1 || (summary.count == 1 && summary.firstID != id)
            }
            .removeDuplicates()
            .sink { [weak self] enabled in self?.nextButton.isEnabled = enabled }
            .store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawWindowGradient(in: self, reversed: true)
        super.draw(dirtyRect)
    }

    private func render(_ current: QueueEntry?, playing: Bool, error: String?) {
        title.stringValue = error ?? current.map { "\($0.track.artist) — \($0.track.title)" } ?? "Stopped"
        title.toolTip = title.stringValue
        let action = playing ? "Pause" : "Play"
        playButton.image = playing ? pauseImage : playImage
        playButton.toolTip = action
        playButton.setAccessibilityLabel(action)
        previousButton.isEnabled = current != nil
        playButton.isEnabled = current != nil || canStartSelection
    }

    private func renderTime(_ elapsed: Double, _ length: Double) {
        let maximum = max(1, length)
        if seek.maxValue != maximum { seek.maxValue = maximum }
        seek.isEnabled = player.current != nil && length > 0
        if !seek.isScrubbing, seek.doubleValue != elapsed { seek.doubleValue = elapsed }
        let seconds = (Int(elapsed), Int(length.rounded()))
        if let displayedSeconds, displayedSeconds == seconds { return }
        displayedSeconds = seconds
        time.stringValue = "\(timeLabel(elapsed)) / \(timeLabel(length.rounded()))"
        seek.setAccessibilityValueDescription("\(timeLabel(elapsed)) of \(timeLabel(length.rounded()))")
    }
    @objc private func previous() { player.previous() }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        routePickerView.player = player.audio
        player.airPlayDiagnostics.pickerOpened(routePickerView === airPlay ? "transport" : "Audio Output sheet")
    }

    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        player.airPlayDiagnostics.pickerClosed(routePickerView === airPlay ? "transport" : "Audio Output sheet")
    }

    @objc private func next() { player.next() }
    @objc private func scrub() { player.seek(to: seek.doubleValue) }
    @objc private func setVolume() {
        player.volume = volume.doubleValue
        volume.setAccessibilityValueDescription(player.volume.formatted(.percent))
    }

    func showOutputPicker(in window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Audio Output"
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 38, height: 30))
        picker.delegate = self
        picker.player = player.audio
        alert.accessoryView = picker
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window)
    }
}
