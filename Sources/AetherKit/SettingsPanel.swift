import AppKit

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate {
    private let glassView = NSGlassEffectView()
    private let shade = NSSlider()
    private let radius = NSSlider()
    private let gap = NSSlider()
    private let font = NSSlider()
    private let blur = NSSlider()
    private let shadeValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    private let gapValue = NSTextField(labelWithString: "")
    private let fontValue = NSTextField(labelWithString: "")
    private let blurValue = NSTextField(labelWithString: "")
    private let glass = NSSegmentedControl(labels: GlassStyle.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let text = NSSegmentedControl(labels: TextTone.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let rest = NSSegmentedControl(labels: FocusRest.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let snap = NSButton(checkboxWithTitle: "Snap windows when you let go", target: nil, action: nil)
    private let notify = NSButton(checkboxWithTitle: "Notify when a command finishes in the background", target: nil, action: nil)
    private let dropdown = NSButton(checkboxWithTitle: "Dropdown terminal    ⌃⌘`", target: nil, action: nil)
    private let dock = NSButton(checkboxWithTitle: "Hide the Dock icon", target: nil, action: nil)
    private let updates = NSButton(checkboxWithTitle: "Look for updates in the background", target: nil, action: nil)
    private let tabs = NSSegmentedControl(labels: ["Look", "Window", "Terminal", "Cloud", "Updates"], trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSStackView] = []
    private let updateStatus = NSTextField(labelWithString: "")
    private let keybinds = KeybindBoard()
    private let sessionWhere = NSSegmentedControl(labels: ["Local", "Cloud"], trackingMode: .selectOne, target: nil, action: nil)
    private let cloudStatus = NSTextField(wrappingLabelWithString: "")
    private var cloudChosen = false
    private let pairButton = NSButton(title: "Code for another device", target: nil, action: nil)
    private let signOutButton = NSButton(title: "Sign Out of Cloud…", target: nil, action: nil)
    private var prompting = false
    private var applying = false
    private var escMonitor: Any?
    private var vaporToken = 0

    init() {
        let panel = VaporPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
            styleMask: [.borderless, .fullSizeContentView],
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
        panel.delegate = self

        glassView.autoresizingMask = [.width, .height]
        glassView.frame = panel.contentView?.bounds ?? .zero
        glassView.style = .regular
        glassView.cornerRadius = 22
        glassView.enableInteractiveGlass()
        let host = NSView(frame: glassView.bounds)
        host.autoresizingMask = [.width, .height]
        glassView.contentView = host
        GlassPanel.mount(glassView, on: panel, radius: 22)

        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)

        let look = page()
        add(labeled("Glass", glass), to: look)
        add(labeled("Text", text), to: look)
        add(sliderRow("Shade", shade, shadeValue, min: 0, max: 0.82), to: look)
        add(sliderRow("Font", font, fontValue, min: 10, max: 24), to: look)
        add(labeled("Unfocused", rest), to: look)
        add(note("Dim softens them. Blur frosts them by the amount below. As is leaves them alone."), to: look)
        add(sliderRow("Blur", blur, blurValue, min: 0, max: 1), to: look)

        let windowPage = page()
        add(sliderRow("Corners", radius, radiusValue, min: 8, max: 32), to: windowPage)
        add(sliderRow("Gap", gap, gapValue, min: 4, max: 22), to: windowPage)
        add(snap, to: windowPage)
        add(dropdown, to: windowPage)
        add(dock, to: windowPage)

        let terminalPage = page()
        add(notify, to: terminalPage)
        add(note("A finished command in a pane you are not looking at can post a notification."), to: terminalPage)

        let cloudPage = page()
        add(sessionWhere, to: cloudPage)
        cloudStatus.font = .systemFont(ofSize: 12)
        cloudStatus.textColor = .secondaryLabelColor
        cloudStatus.preferredMaxLayoutWidth = 560
        add(cloudStatus, to: cloudPage)
        pairButton.target = self
        pairButton.action = #selector(pairDevice)
        pairButton.bezelStyle = .rounded
        pairButton.font = .systemFont(ofSize: 12, weight: .medium)
        add(pairButton, to: cloudPage)
        add(note("Cloud gives you a terminal of your own. The shell stays up after you quit. The code opens it on a phone or another computer. Local keeps your Cloud account for later."), to: cloudPage)
        signOutButton.target = self
        signOutButton.action = #selector(signOut)
        signOutButton.bezelStyle = .rounded
        signOutButton.font = .systemFont(ofSize: 12, weight: .medium)
        add(signOutButton, to: cloudPage)
        let reveal = NSButton(title: "Show Config in Finder", target: self, action: #selector(revealConfig))
        reveal.bezelStyle = .rounded
        reveal.font = .systemFont(ofSize: 12, weight: .medium)
        add(reveal, to: cloudPage)

        let updatePage = page()
        add(updates, to: updatePage)
        add(note("Off, Aether does not look unless you ask. A download still waits for Install now."), to: updatePage)
        let check = NSButton(title: "Check for updates", target: self, action: #selector(checkForUpdates))
        check.bezelStyle = .rounded
        check.font = .systemFont(ofSize: 12, weight: .medium)
        add(check, to: updatePage)
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .tertiaryLabelColor
        updateStatus.stringValue = ""
        add(updateStatus, to: updatePage)

        pages = [look, windowPage, terminalPage, cloudPage, updatePage]
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.segmentDistribution = .fillEqually

        let keysLabel = NSTextField(labelWithString: "Keys")
        keysLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        keysLabel.textColor = .labelColor
        let keyScroll = NSScrollView()
        keyScroll.translatesAutoresizingMaskIntoConstraints = false
        keyScroll.drawsBackground = false
        keyScroll.borderType = .noBorder
        keyScroll.hasVerticalScroller = true
        keyScroll.autohidesScrollers = true
        keybinds.translatesAutoresizingMaskIntoConstraints = false
        keyScroll.documentView = keybinds

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(tabs)
        for page in pages {
            stack.addArrangedSubview(page)
        }
        stack.addArrangedSubview(keysLabel)
        stack.addArrangedSubview(note("Click a shortcut, then press the new keys. Esc cancels. Reset puts that one shortcut back."))
        stack.addArrangedSubview(keyScroll)
        showPage(0)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            keybinds.leadingAnchor.constraint(equalTo: keyScroll.contentView.leadingAnchor),
            keybinds.trailingAnchor.constraint(equalTo: keyScroll.contentView.trailingAnchor),
            keybinds.topAnchor.constraint(equalTo: keyScroll.contentView.topAnchor),
        ])
        for page in pages {
            page.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        keyScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        keyScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        for control in [glass, text, rest, sessionWhere] {
            control.target = self
            control.action = #selector(changed)
            control.segmentDistribution = .fillEqually
        }
        for box in [snap, notify, dropdown, dock, updates] {
            box.target = self
            box.action = #selector(changed)
            box.font = .systemFont(ofSize: 13)
        }
        for slider in [shade, radius, gap, font, blur] {
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
        }
        for value in [shadeValue, radiusValue, gapValue, fontValue, blurValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
    }

    @objc private func selectTab() {
        showPage(tabs.selectedSegment)
    }

    private func showPage(_ index: Int) {
        let animate = window?.isVisible == true
        for (item, page) in pages.enumerated() {
            let show = item == index
            guard show != !page.isHidden else { continue }
            if show {
                page.alphaValue = animate ? 0 : 1
                page.isHidden = false
                if animate {
                    Motion.group(Motion.close) { page.animator().alphaValue = 1 }
                }
            } else {
                page.isHidden = true
                page.alphaValue = 1
            }
        }
    }

    private func page() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func add(_ row: NSView, to page: NSStackView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        page.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        vaporToken += 1
        load()
        UpdateCenter.shared.onStatus = { [weak self] message in
            self?.updateStatus.stringValue = message
        }
        SessionHub.shared.onLink = { [weak self] link in
            self?.cloudStatus.stringValue = link.title
            self?.cloudStatus.textColor = {
                switch link {
                case .failed, .unavailable: return .systemRed
                case .connected: return .secondaryLabelColor
                default: return .secondaryLabelColor
                }
            }()
        }
        cloudStatus.stringValue = SessionHub.shared.link.title
        if cloudChosen {
            switch SessionHub.shared.link {
            case .idle, .unavailable:
                Task { await self.connectCloud() }
            default:
                break
            }
        }
        window?.center()
        guard let window else { return }
        GlassMotion.present(window)
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, event.keyCode == 53 else { return event }
                self.vaporize()
                return nil
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !prompting else { return }
        vaporize()
    }

    func vaporize() {
        keybinds.stopRecording()
        guard let window, window.isVisible, window.alphaValue > 0.2 else { return }
        vaporToken += 1
        let token = vaporToken
        GlassMotion.vaporize(window) { [weak self] in self?.vaporToken == token }
    }

    @objc private func changed() {
        guard !applying else { return }
        paintValues()
        let wantsCloud = sessionWhere.selectedSegment == 1
        let switched = wantsCloud != cloudChosen
        AppModel.shared.updateSettings { settings in
            settings.shade = shade.doubleValue
            settings.cornerRadius = radius.doubleValue
            settings.gap = gap.doubleValue
            settings.fontSize = font.doubleValue
            settings.glass = GlassStyle.allCases[glass.selectedSegment]
            settings.text = TextTone.allCases[text.selectedSegment]
            settings.focusRest = FocusRest.allCases[rest.selectedSegment]
            settings.blurAmount = blur.doubleValue
            settings.snapWindows = snap.state == .on
            settings.notifyOnFinish = notify.state == .on
            settings.checkForUpdates = updates.state == .on
            settings.dropdownEnabled = dropdown.state == .on
            settings.hideDockIcon = dock.state == .on
            if switched && !wantsCloud {
                // Local stops using the account. It does not forget it.
                settings.cloudEnabled = false
            }
        }
        glassView.style = AppModel.shared.settings.glass == .clear ? .clear : .regular
        guard switched else { return }
        if wantsCloud {
            Task { await self.chooseCloud() }
        } else {
            cloudChosen = false
            SessionHub.shared.setLink(.idle)
            refreshCloudControls()
        }
    }

    private func chooseCloud() async {
        if !AppModel.shared.settings.hasCloudAccount {
            let alert = NSAlert()
            alert.messageText = "Start a Cloud account?"
            alert.informativeText = "Aether will make a Cloud account for this Mac. New terminals will run on the Cloud server instead of this Mac."
            alert.addButton(withTitle: "Start Cloud")
            alert.addButton(withTitle: "Cancel")
            guard await confirm(alert) == .alertFirstButtonReturn else {
                showLocal()
                return
            }
            SessionHub.shared.setLink(.connecting)
            do {
                try await SessionHub.shared.enroll()
            } catch {
                SessionHub.shared.setLink(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                showLocal()
                return
            }
        }
        cloudChosen = true
        AppModel.shared.updateSettings { $0.cloudEnabled = true }
        refreshCloudControls()
        await connectCloud()
    }

    private func showLocal() {
        applying = true
        sessionWhere.selectedSegment = 0
        applying = false
        cloudChosen = false
        refreshCloudControls()
    }

    private func connectCloud() async {
        guard AppModel.shared.settings.usesCloud else { return }
        SessionHub.shared.setLink(.connecting)
        do {
            try await SessionHub.shared.open()
        } catch SessionError.unauthorized {
            // SessionHub asks the person what to do.
        } catch {
            SessionHub.shared.setLink(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func confirm(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        prompting = true
        defer { prompting = false }
        guard let window, window.isVisible else { return alert.runModal() }
        return await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
        }
    }

    private func refreshCloudControls() {
        let settings = AppModel.shared.settings
        pairButton.isEnabled = settings.usesCloud
        signOutButton.isEnabled = settings.hasCloudAccount
    }

    @objc private func signOut() {
        Task {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Sign out of Cloud?"
            alert.informativeText = "This Mac forgets its Cloud account and goes back to Local. Terminals running in Cloud can't be reached from here again. The sign-in is kept in your keychain as a backup."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Sign Out")
            guard await confirm(alert) == .alertSecondButtonReturn else { return }
            SessionHub.shared.signOut()
            load()
        }
    }

    @objc private func pairDevice() {
        let settings = AppModel.shared.settings
        guard settings.usesCloud else { return }
        cloudStatus.stringValue = "Making a code…"
        Task {
            do {
                let result = try await CloudCatalog.pair(token: settings.sessionToken, ws: settings.sessionWS)
                if !result.url.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.url, forType: .string)
                    cloudStatus.stringValue = "Code \(result.code). The link is on the clipboard."
                } else {
                    cloudStatus.stringValue = "Code \(result.code)"
                }
            } catch {
                cloudStatus.stringValue = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    @objc private func checkForUpdates() {
        updateStatus.stringValue = "Checking…"
        Task {
            let message = await UpdateCenter.shared.checkNow()
            self.updateStatus.stringValue = message
        }
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
        blur.doubleValue = settings.blurAmount
        snap.state = settings.snapWindows ? .on : .off
        updates.state = settings.checkForUpdates ? .on : .off
        notify.state = settings.notifyOnFinish ? .on : .off
        dropdown.state = settings.dropdownEnabled ? .on : .off
        dock.state = settings.hideDockIcon ? .on : .off
        dropdown.title = "Dropdown terminal    \(settings.keys.symbol(.dropdown))"
        sessionWhere.selectedSegment = settings.usesCloud ? 1 : 0
        cloudChosen = sessionWhere.selectedSegment == 1
        refreshCloudControls()
        keybinds.reload()
        glassView.style = settings.glass == .clear ? .clear : .regular
        paintValues()
        applying = false
    }

    private func paintValues() {
        shadeValue.stringValue = String(format: "%.2f", shade.doubleValue)
        blurValue.stringValue = String(format: "%.2f", blur.doubleValue)
        radiusValue.stringValue = String(Int(radius.doubleValue.rounded()))
        gapValue.stringValue = String(Int(gap.doubleValue.rounded()))
        fontValue.stringValue = String(Int(font.doubleValue.rounded()))
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 560
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .left
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.translatesAutoresizingMaskIntoConstraints = false
        let line = NSStackView(views: [label, control])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 16
        line.distribution = .fill
        return line
    }

    private func sliderRow(_ title: String, _ slider: NSSlider, _ value: NSTextField, min: Double, max: Double) -> NSView {
        slider.cell = GlassSliderCell()
        slider.minValue = min
        slider.maxValue = max
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let line = NSStackView(views: [label, slider, value])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 16
        line.distribution = .fill
        return line
    }
}

private final class GlassSliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let ink = NSColor.labelColor
        ink.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let span = max(maxValue - minValue, 0.0001)
        let t = CGFloat((doubleValue - minValue) / span)
        let fill = NSRect(x: rect.minX, y: track.minY, width: max(4, rect.width * t), height: 4)
        ink.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let knob = NSRect(x: knobRect.midX - 7, y: knobRect.midY - 7, width: 14, height: 14)
        NSColor.labelColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
    }
}
