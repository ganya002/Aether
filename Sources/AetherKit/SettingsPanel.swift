import AppKit

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsController: NSWindowController {
    private let glassView = NSGlassEffectView()
    private let shade = NSSlider()
    private let radius = NSSlider()
    private let gap = NSSlider()
    private let font = NSSlider()
    private let shadeValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let gapValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let glass = NSSegmentedControl(labels: GlassStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let text = NSSegmentedControl(labels: TextTone.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let rest = NSSegmentedControl(labels: FocusRest.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let snap = NSButton(checkboxWithTitle: "Snap windows when you let go", target: nil, action: nil)
    private let notify = NSButton(checkboxWithTitle: "Notify when a command finishes in the background", target: nil, action: nil)
    private let dropdown = NSButton(checkboxWithTitle: "Dropdown terminal    ⌃⌘`", target: nil, action: nil)
    private let dock = NSButton(checkboxWithTitle: "Hide the Dock icon", target: nil, action: nil)
    private var applying = false

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Settings"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        super.init(window: panel)

        glassView.autoresizingMask = [.width, .height]
        glassView.frame = panel.contentView?.bounds ?? .zero
        glassView.style = .regular
        glassView.cornerRadius = 22
        if #available(macOS 27.0, *) {
            glassView.effectIsInteractive = true
        }
        let host = NSView(frame: glassView.bounds)
        host.autoresizingMask = [.width, .height]
        glassView.contentView = host
        panel.contentView = glassView

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        host.addSubview(scroll)

        let document = FlippedDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18),
        ])

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(section("Glass"))
        stack.addArrangedSubview(glass)
        stack.addArrangedSubview(section("Unfocused panes"))
        stack.addArrangedSubview(rest)
        let restNote = note("Dim keeps the type readable. Blur frosts them. As is leaves them alone. The focused pane gets a border either way.")
        stack.addArrangedSubview(restNote)
        stack.addArrangedSubview(section("Type"))
        stack.addArrangedSubview(labeled("Text", text))
        stack.addArrangedSubview(sliderRow("Shade", shade, shadeValue, min: 0, max: 0.82))
        stack.addArrangedSubview(sliderRow("Font", font, fontValue, min: 10, max: 24))
        stack.addArrangedSubview(section("Window"))
        stack.addArrangedSubview(sliderRow("Corners", radius, radiusValue, min: 8, max: 32))
        stack.addArrangedSubview(sliderRow("Gap", gap, gapValue, min: 4, max: 22))
        stack.addArrangedSubview(snap)
        stack.addArrangedSubview(section("Terminal"))
        stack.addArrangedSubview(notify)
        stack.addArrangedSubview(dropdown)
        stack.addArrangedSubview(dock)

        let reveal = NSButton(title: "Show Config in Finder", target: self, action: #selector(revealConfig))
        reveal.bezelStyle = .rounded
        reveal.font = .systemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(reveal)
        stack.addArrangedSubview(note("That file is the one you can copy to another Mac. Changes apply immediately."))

        for control in [glass, text, rest] {
            control.target = self
            control.action = #selector(changed)
            control.segmentDistribution = .fillEqually
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        for box in [snap, notify, dropdown, dock] {
            box.target = self
            box.action = #selector(changed)
            box.font = .systemFont(ofSize: 13)
        }
        for slider in [shade, radius, gap, font] {
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
        }
        for value in [shadeValue, radiusValue, gapValue, fontValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        load()
        window?.center()
        guard let window else { return }
        GlassMotion.present(window)
    }

    @objc private func changed() {
        guard !applying else { return }
        paintValues()
        AppModel.shared.updateSettings { settings in
            settings.shade = shade.doubleValue
            settings.cornerRadius = radius.doubleValue
            settings.gap = gap.doubleValue
            settings.fontSize = font.doubleValue
            settings.glass = GlassStyle.allCases[glass.selectedSegment]
            settings.text = TextTone.allCases[text.selectedSegment]
            settings.focusRest = FocusRest.allCases[rest.selectedSegment]
            settings.snapWindows = snap.state == .on
            settings.notifyOnFinish = notify.state == .on
            settings.dropdownEnabled = dropdown.state == .on
            settings.hideDockIcon = dock.state == .on
        }
        glassView.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
    }

    @objc private func revealConfig() {
        ConfigStore.save(AppModel.shared.settings)
        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL()])
    }

    private func load() {
        applying = true
        let settings = AppModel.shared.settings
        shade.doubleValue = settings.shade
        radius.doubleValue = settings.cornerRadius
        gap.doubleValue = settings.gap
        font.doubleValue = settings.fontSize
        glass.selectedSegment = GlassStyle.allCases.firstIndex(of: settings.glass) ?? 0
        text.selectedSegment = TextTone.allCases.firstIndex(of: settings.text) ?? 0
        rest.selectedSegment = FocusRest.allCases.firstIndex(of: settings.focusRest) ?? 0
        snap.state = settings.snapWindows ? .on : .off
        notify.state = settings.notifyOnFinish ? .on : .off
        dropdown.state = settings.dropdownEnabled ? .on : .off
        dock.state = settings.hideDockIcon ? .on : .off
        glassView.style = settings.glass == .clear ? .clear : .regular
        paintValues()
        applying = false
    }

    private func paintValues() {
        shadeValue.stringValue = String(format: "%.2f", shade.doubleValue)
        radiusValue.stringValue = String(Int(radius.doubleValue.rounded()))
        gapValue.stringValue = String(Int(gap.doubleValue.rounded()))
        fontValue.stringValue = String(Int(font.doubleValue.rounded()))
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.preferredMaxLayoutWidth = 400
        return label
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let line = NSStackView(views: [label, control])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 12
        return line
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField, min: Double, max: Double) -> NSView {
        slider.minValue = min
        slider.maxValue = max
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let line = NSStackView(views: [label, slider, value])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        return line
    }
}
