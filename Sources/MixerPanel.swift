import AppKit
import ServiceManagement

// plain AppKit, keeps memory down
@MainActor
final class MixerPanel: NSViewController {
    private static let width: CGFloat = 340
    private static let rowHeight: CGFloat = 54
    private static let maxRowsHeight: CGFloat = 440

    private let model: MixerModel
    private var rowViews: [String: RowView] = [:]
    private var rowOrder: [String] = []

    private let outputLabel = NSTextField(labelWithString: "")
    private let bannerStack = NSStackView()
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let emptyLabel = NSTextField(labelWithString: "Nothing is playing right now.")
    private let showAllBox = NSButton(checkboxWithTitle: "Show all audio apps", target: nil, action: nil)
    private let loginBox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let resetAllButton = NSButton(title: "Reset All", target: nil, action: nil)

    init(model: MixerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        let parts: [NSView] = [makeHeader(), separator(), bannerStack, makeRowsArea(), emptyLabel, separator(), makeFooter()]
        for part in parts {
            stack.addArrangedSubview(part)
            part.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        view = root

        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: - Building

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: "Levels")
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let speaker = NSImageView(image: NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil) ?? NSImage())
        speaker.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        speaker.contentTintColor = .secondaryLabelColor

        outputLabel.font = .systemFont(ofSize: 11)
        outputLabel.textColor = .secondaryLabelColor
        outputLabel.lineBreakMode = .byTruncatingMiddle
        outputLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [title, NSView(), speaker, outputLabel])
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return row
    }

    private func makeRowsArea() -> NSView {
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = document

        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollHeight,
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.heightAnchor.constraint(equalToConstant: 72).isActive = true

        bannerStack.orientation = .vertical
        bannerStack.spacing = 0
        return scrollView
    }

    private func makeFooter() -> NSView {
        for control in [showAllBox, loginBox, resetAllButton] {
            control.font = .systemFont(ofSize: 11)
            control.target = self
        }
        showAllBox.action = #selector(toggleShowAll)
        loginBox.action = #selector(toggleLogin)
        resetAllButton.action = #selector(resetAll)
        resetAllButton.controlSize = .small
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let quit = NSButton(title: "Quit Levels", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.font = .systemFont(ofSize: 11)
        quit.controlSize = .small

        let toggles = NSStackView(views: [showAllBox, NSView(), loginBox])
        let buttons = NSStackView(views: [resetAllButton, NSView(), quit])
        let footer = NSStackView(views: [toggles, buttons])
        footer.orientation = .vertical
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        for row in [toggles, buttons] {
            row.widthAnchor.constraint(equalTo: footer.widthAnchor, constant: -28).isActive = true
        }
        return footer
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Updating

    private func refresh() {
        outputLabel.stringValue = model.outputName
        showAllBox.state = model.showAllApps ? .on : .off
        resetAllButton.isEnabled = model.hasAdjustments
        updateBanners()

        let rows = model.rows()
        let ids = rows.map(\.id)
        if ids != rowOrder {
            let wanted = Set(ids)
            for (id, view) in rowViews where !wanted.contains(id) {
                view.removeFromSuperview()
                rowViews[id] = nil
            }
            for id in ids where rowViews[id] == nil {
                rowViews[id] = RowView(key: id, model: model)
            }
            for view in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(view) }
            for id in ids {
                let row = rowViews[id]!
                rowsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            }
            rowOrder = ids
        }
        for row in rows { rowViews[row.id]?.configure(row) }

        scrollView.isHidden = rows.isEmpty
        emptyLabel.isHidden = !rows.isEmpty
        scrollHeight.constant = min(CGFloat(rows.count) * Self.rowHeight + 8, Self.maxRowsHeight)
    }

    private func updateBanners() {
        for view in bannerStack.arrangedSubviews { view.removeFromSuperview() }
        if model.permission == .denied {
            let text = "Levels needs “System Audio Recording” access to change app volumes. Turn on Levels under Privacy & Security → Screen & System Audio Recording."
            let button = NSButton(title: "Open Privacy Settings…", target: self, action: #selector(openPrivacySettings))
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            addBanner(text, tint: .systemOrange, extra: button)
        }
        if let message = model.errorMessage {
            addBanner(message, tint: .systemRed, extra: nil)
        }
        bannerStack.isHidden = bannerStack.arrangedSubviews.isEmpty
    }

    private func addBanner(_ text: String, tint: NSColor, extra: NSView?) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.preferredMaxLayoutWidth = Self.width - 24
        var views: [NSView] = [label]
        if let extra { views.append(extra) }
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.wantsLayer = true
        content.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        bannerStack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: bannerStack.widthAnchor).isActive = true
    }

    // MARK: - Actions

    @objc private func toggleShowAll() { model.showAllApps = showAllBox.state == .on }
    @objc private func resetAll() { model.resetAll() }

    @objc private func toggleLogin() {
        do {
            if loginBox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class RowView: NSView {
    private let key: String
    private let model: MixerModel

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let playingIcon = NSImageView()
    private let notRunningLabel = NSTextField(labelWithString: "not running")
    private let levelLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let muteButton = NSButton()

    init(key: String, model: MixerModel) {
        self.key = key
        self.model = model
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 54).isActive = true

        icon.image = model.icon(for: key)
        icon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        playingIcon.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Playing")
        playingIcon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        playingIcon.contentTintColor = .systemGreen

        notRunningLabel.font = .systemFont(ofSize: 10)
        notRunningLabel.textColor = .tertiaryLabelColor

        levelLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        levelLabel.alignment = .right
        levelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)

        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        muteButton.target = self
        muteButton.action = #selector(toggleMute)

        let name = NSStackView(views: [nameLabel, playingIcon, notRunningLabel])
        name.spacing = 5

        for view in [icon, name, levelLabel, slider, muteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            name.trailingAnchor.constraint(lessThanOrEqualTo: levelLabel.leadingAnchor, constant: -6),

            levelLabel.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            levelLabel.centerYAnchor.constraint(equalTo: name.centerYAnchor),

            slider.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            slider.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            slider.trailingAnchor.constraint(equalTo: muteButton.leadingAnchor, constant: -10),

            muteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            muteButton.widthAnchor.constraint(equalToConstant: 20),
        ])

        let menu = NSMenu()
        menu.addItem(withTitle: "Reset to 100%", action: #selector(resetRow), keyEquivalent: "").target = self
        self.menu = menu
    }

    func configure(_ row: AppRow) {
        nameLabel.stringValue = row.name
        playingIcon.isHidden = !row.isPlaying
        notRunningLabel.isHidden = row.isRunning || row.isPlaying
        icon.alphaValue = row.isRunning ? 1 : 0.5
        showSetting(updateSlider: true)
    }

    private func showSetting(updateSlider: Bool) {
        let setting = model.setting(for: key)
        if updateSlider { slider.doubleValue = setting.level }
        slider.alphaValue = setting.muted ? 0.4 : 1
        levelLabel.stringValue = setting.muted ? "Muted" : "\(Int((setting.level * 100).rounded()))%"
        levelLabel.textColor = .secondaryLabelColor
        muteButton.image = NSImage(systemSymbolName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   accessibilityDescription: setting.muted ? "Unmute" : "Mute")
        muteButton.contentTintColor = setting.muted ? .systemRed : .secondaryLabelColor
        muteButton.toolTip = setting.muted ? "Unmute" : "Mute"
    }

    @objc private func sliderMoved() {
        model.setLevel(slider.doubleValue, for: key)
        showSetting(updateSlider: false)
    }

    @objc private func toggleMute() { model.toggleMute(key) }
    @objc private func resetRow() { model.reset(key) }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
