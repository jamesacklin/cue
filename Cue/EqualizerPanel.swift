import AppKit
import Combine

@MainActor
final class EqualizerPanel: NSWindowController {
    private let equalizer: Equalizer
    private var sliders: [NSSlider] = []
    private var readings: [NSTextField] = []
    private var status: AnyCancellable?

    init(equalizer: Equalizer) {
        self.equalizer = equalizer
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Graphic Equalizer"
        let enable = NSButton(checkboxWithTitle: "Enable equalizer", target: self, action: #selector(toggle(_:)))
        enable.state = equalizer.enabled ? .on : .off
        let reset = NSButton(title: "Reset to Flat", target: self, action: #selector(flatten))
        let header = NSStackView(views: [enable, NSView(), reset])
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 7
        for i in Equalizer.frequencies.indices.reversed() {
            let hz = Equalizer.frequencies[i]
            let name = hz >= 1000 ? "\(hz / 1000) kHz" : "\(hz) Hz"
            let label = NSTextField(labelWithString: name)
            label.alignment = .right
            let slider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: self, action: #selector(adjust(_:)))
            slider.tag = i
            slider.setAccessibilityLabel(name)
            slider.numberOfTickMarks = 3
            slider.allowsTickMarkValuesOnly = false
            slider.isContinuous = true
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            value.alignment = .right
            let row = NSStackView(views: [label, slider, value])
            row.spacing = 10
            label.widthAnchor.constraint(equalToConstant: 50).isActive = true
            slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
            value.widthAnchor.constraint(equalToConstant: 62).isActive = true
            rows.addArrangedSubview(row)
            sliders.append(slider)
            readings.append(value)
        }
        let note = NSTextField(labelWithString: "")
        let stack = NSStackView(views: [header, rows, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        header.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        panel.contentView = stack
        status = equalizer.$message.sink { text in
            note.stringValue = text ?? ""
            note.isHidden = text == nil
            panel.setContentSize(stack.fittingSize)
        }
        refresh()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("Use init(equalizer:)") }

    @objc private func toggle(_ button: NSButton) { equalizer.setEnabled(button.state == .on) }

    @objc private func flatten() {
        equalizer.flatten()
        refresh()
    }

    @objc private func adjust(_ slider: NSSlider) {
        let x = slider.doubleValue
        let gain = abs(x) < 0.025 ? 0 : (x < 0 ? -1.0 : 1.0) * (4 * abs(x) + 8 * x * x)
        equalizer.setGain((gain * 10).rounded() / 10, band: slider.tag)
        refresh()
    }

    private func refresh() {
        for (slider, reading) in zip(sliders, readings) {
            let gain = equalizer.gains[slider.tag]
            slider.doubleValue = (gain < 0 ? -1 : 1) * (sqrt(16 + 32 * abs(gain)) - 4) / 16
            reading.stringValue = gain == 0 ? "0 dB" : String(format: "%+.1f dB", gain)
            slider.setAccessibilityValueDescription(reading.stringValue)
        }
    }
}
