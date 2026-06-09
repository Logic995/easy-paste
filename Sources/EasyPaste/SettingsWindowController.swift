import AppKit
import EasyPasteCore
import ObjectiveC
import UniformTypeIdentifiers

private enum SettingsMetrics {
    static let trailingControlWidth: CGFloat = 300
    static let shortcutControlWidth: CGFloat = 150
    static let sliderValueWidth: CGFloat = 62
    static let sliderWidth: CGFloat = trailingControlWidth - sliderValueWidth - 10
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private enum Page: CaseIterable {
        case general
        case privacy
        case shortcuts

        var title: String {
            switch self {
            case .general: return L10n.t("settings.general")
            case .privacy: return L10n.t("settings.privacy")
            case .shortcuts: return L10n.t("settings.shortcuts")
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .privacy: return "hand.raised"
            case .shortcuts: return "keyboard"
            }
        }

    }

    private let store: ClipboardStore
    private let onChange: (Bool) -> Void
    private let onClearLocalData: () -> Void
    private var pendingPreferenceSaveTask: Task<Void, Never>?
    private var selectedPage: Page = .general
    private let rootView = NSView()
    private let sidebarView = NSView()
    private let sidebarStack = NSStackView()
    private let contentView = FlippedView()
    private let scrollView = NSScrollView()
    nonisolated(unsafe) private var hotKeyDiagnosticsObserver: NSObjectProtocol?
    nonisolated(unsafe) private var glassCapabilityObserver: NSObjectProtocol?

    init(
        store: ClipboardStore,
        onChange: @escaping (Bool) -> Void,
        onClearLocalData: @escaping () -> Void = {}
    ) {
        self.store = store
        self.onChange = onChange
        self.onClearLocalData = onClearLocalData
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.t("settings.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        hotKeyDiagnosticsObserver = NotificationCenter.default.addObserver(
            forName: HotKeyController.diagnosticsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selectedPage == .shortcuts else { return }
                self.renderContent()
            }
        }
        glassCapabilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.selectedPage == .general else { return }
                self.renderContent()
                self.onChange(false)
            }
        }
        build()
        render()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let hotKeyDiagnosticsObserver {
            NotificationCenter.default.removeObserver(hotKeyDiagnosticsObserver)
        }
        if let glassCapabilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(glassCapabilityObserver)
        }
    }

    func show(relativeTo parent: NSWindow?) {
        render()
        applyTheme()
        if let window {
            centerWindowOnScreen(window, preferredScreen: parent?.screen)
        }
        showWindow(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func centerWindowOnScreen(_ window: NSWindow, preferredScreen: NSScreen?) {
        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            window.center()
            return
        }

        let frame = window.frame
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }

    private func build() {
        guard let window else { return }
        window.appearance = EasyPasteThemeStore.appearance

        rootView.wantsLayer = true
        rootView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = rootView

        sidebarView.wantsLayer = true
        sidebarView.layer?.cornerRadius = 12
        sidebarView.layer?.borderWidth = 0.5
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(sidebarView)

        sidebarStack.orientation = .horizontal
        sidebarStack.alignment = .centerY
        sidebarStack.distribution = .fillEqually
        sidebarStack.spacing = 6
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.addSubview(sidebarStack)

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(main)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            sidebarView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            sidebarView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 42),
            sidebarView.widthAnchor.constraint(equalToConstant: 356),
            sidebarView.heightAnchor.constraint(equalToConstant: 40),

            sidebarStack.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 5),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -5),
            sidebarStack.topAnchor.constraint(equalTo: sidebarView.topAnchor, constant: 5),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: -5),

            main.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            main.widthAnchor.constraint(equalToConstant: 620),
            main.topAnchor.constraint(equalTo: sidebarView.bottomAnchor, constant: 16),
            main.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),

            scrollView.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: main.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: main.bottomAnchor),

            contentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        sidebarView.identifier = NSUserInterfaceItemIdentifier("SettingsSidebar")
    }

    private func render() {
        renderSidebar()
        renderContent()
    }

    private func renderSidebar() {
        sidebarStack.arrangedSubviews.forEach {
            sidebarStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for page in Page.allCases {
            let item = SettingsSidebarItem(title: page.title, symbol: page.symbol, selected: page == selectedPage)
            item.onClick = { [weak self] in
                self?.selectedPage = page
                self?.render()
            }
            sidebarStack.addArrangedSubview(item)
        }
    }

    private func renderContent() {
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        switch selectedPage {
        case .general:
            buildGeneral(in: stack)
        case .privacy:
            buildPrivacy(in: stack)
        case .shortcuts:
            buildShortcuts(in: stack)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16)
        ])
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        applyTheme()
    }

    private func buildGeneral(in stack: NSStackView) {
        let p = store.preferences
        let glassUnavailableReason = PanelGlassCapability.unavailableReason
        addSection(to: stack, rows: [
            .switchRow(title: L10n.t("settings.openAtLogin"), isOn: p.openAtLogin) { [weak self] isOn in
                self?.updatePrefs { $0.openAtLogin = isOn }
                LoginItemManager.setEnabled(isOn)
            },
            .switchRow(title: L10n.t("settings.runInBackground"), isOn: p.runInBackground) { [weak self] isOn in
                self?.updatePrefs { $0.runInBackground = isOn }
            },
            .switchRow(title: L10n.t("settings.soundEffects"), isOn: p.soundEffects) { [weak self] isOn in
                self?.updatePrefs { $0.soundEffects = isOn }
            },
            .segmentedRow(title: L10n.t("settings.theme"), labels: [
                L10n.t("settings.theme.system"),
                L10n.t("settings.theme.light"),
                L10n.t("settings.theme.dark")
            ], selected: EasyPasteThemeMode.allCases.firstIndex(of: EasyPasteThemeStore.mode) ?? 0) { [weak self] index in
                guard EasyPasteThemeMode.allCases.indices.contains(index) else { return }
                EasyPasteThemeStore.mode = EasyPasteThemeMode.allCases[index]
                self?.render()
                self?.onChange(false)
            },
            .segmentedRow(title: L10n.t("settings.quickPanelStyle"), labels: [
                L10n.t("settings.quickPanelStyle.classic"),
                L10n.t("settings.quickPanelStyle.cardHandExperimental")
            ], selected: QuickPanelStyle.allCases.firstIndex(of: p.quickPanelStyle) ?? 0) { [weak self] index in
                guard QuickPanelStyle.allCases.indices.contains(index) else { return }
                self?.updatePrefs {
                    $0.quickPanelStyle = QuickPanelStyle.allCases[index]
                }
            },
            .sliderRow(
                title: L10n.t("settings.panelGlassOpacity"),
                subtitle: L10n.t("settings.panelGlassOpacityHint"),
                value: p.panelGlassOpacity,
                min: 0,
                max: 1,
                isEnabled: glassUnavailableReason == nil,
                disabledReason: glassUnavailableReason,
                formatter: { String(format: "%3d%%", Int(round($0 * 100))) }
            ) { [weak self] value in
                self?.updatePrefs(persist: false, reloadPanel: false) {
                    $0.panelGlassOpacity = min(1.0, max(0.0, value))
                }
                self?.schedulePreferenceSave()
            }
        ])

        addSection(to: stack, title: L10n.t("settings.pasteItems"), customView: pasteItemsView())

        addSection(to: stack, title: L10n.t("settings.keepHistory"), customView: historyView())
    }

    private func pasteItemsView() -> NSView {
        let active = RadioOptionView(
            selected: store.preferences.pasteDestination == .activeApp,
            title: L10n.t("settings.toActiveApp"),
            subtitle: L10n.t("settings.toActiveAppHint")
        )
        active.onClick = { [weak self] in
            self?.updatePrefs { $0.pasteDestination = .activeApp }
            self?.renderContent()
        }
        let clipboard = RadioOptionView(
            selected: store.preferences.pasteDestination == .clipboard,
            title: L10n.t("settings.toClipboard"),
            subtitle: L10n.t("settings.toClipboardHint")
        )
        clipboard.onClick = { [weak self] in
            self?.updatePrefs { $0.pasteDestination = .clipboard }
            self?.renderContent()
        }
        let plain = CheckboxRow(
            title: L10n.t("settings.alwaysPlain"),
            isOn: store.preferences.alwaysPastePlainText
        ) { [weak self] isOn in
            self?.updatePrefs { $0.alwaysPastePlainText = isOn }
        }

        return pinnedVerticalView([
            active,
            clipboard,
            separator(inset: 22),
            plain
        ])
    }

    private func historyView() -> NSView {
        let labels = [
            L10n.t("settings.day"),
            L10n.t("settings.week"),
            L10n.t("settings.month"),
            L10n.t("settings.year"),
            L10n.t("settings.forever")
        ]
        let selected = HistoryRetention.allCases.firstIndex(of: store.preferences.historyRetention) ?? 4
        let segmented = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: #selector(historyChanged(_:)))
        segmented.selectedSegment = selected
        segmented.segmentStyle = .rounded
        segmented.controlSize = .small
        let segmentWidth = SettingsMetrics.trailingControlWidth / CGFloat(labels.count)
        for index in labels.indices {
            segmented.setWidth(segmentWidth, forSegment: index)
        }
        segmented.translatesAutoresizingMaskIntoConstraints = false
        let segmentedRow = NSView()
        segmentedRow.translatesAutoresizingMaskIntoConstraints = false
        segmentedRow.addSubview(segmented)
        NSLayoutConstraint.activate([
            segmentedRow.heightAnchor.constraint(equalToConstant: 30),
            segmented.leadingAnchor.constraint(equalTo: segmentedRow.leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: segmentedRow.trailingAnchor),
            segmented.centerYAnchor.constraint(equalTo: segmentedRow.centerYAnchor)
        ])

        let button = NSButton(title: L10n.t("settings.eraseHistory"), target: self, action: #selector(eraseHistory))
        button.bezelStyle = .rounded
        button.controlSize = .small
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(button)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 30),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 126)
        ])
        return pinnedVerticalView([segmentedRow, row], spacing: 8)
    }

    private func buildPrivacy(in stack: NSStackView) {
        let p = store.preferences
        addSection(to: stack, rows: [
            .switchRow(title: L10n.t("settings.showDuringSharing"), subtitle: L10n.t("settings.showDuringSharingHint"), isOn: p.showDuringScreenSharing) { [weak self] isOn in
                self?.updatePrefs { $0.showDuringScreenSharing = isOn }
            },
            .switchRow(title: L10n.t("settings.generateLinkPreviews"), subtitle: L10n.t("settings.generateLinkPreviewsHint"), isOn: p.generateLinkPreviews) { [weak self] isOn in
                self?.updatePrefs { $0.generateLinkPreviews = isOn }
            },
            .switchRow(title: L10n.t("settings.debugPerformance"), subtitle: L10n.t("settings.debugPerformanceHint"), isOn: p.debugPerformance) { [weak self] isOn in
                self?.updatePrefs { $0.debugPerformance = isOn }
                EasyPasteDiagnostics.isEnabled = isOn
            }
        ])

        addSection(
            to: stack,
            title: L10n.t("settings.ignoreApplications"),
            subtitle: L10n.t("settings.ignoreApplicationsHint"),
            customView: ignoredAppsView()
        )

        addSection(
            to: stack,
            title: L10n.t("settings.localData"),
            subtitle: L10n.t("settings.localDataHint"),
            customView: localDataView()
        )
    }

    private func localDataView() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: L10n.t("settings.clearLocalDataHint"))
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.84)
        label.maximumNumberOfLines = 2

        let button = NSButton(title: L10n.t("settings.clearLocalData"), target: self, action: #selector(clearLocalData))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.contentTintColor = .systemRed

        [label, button].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview($0)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: SettingsMetrics.trailingControlWidth)
        ])
        return row
    }

    private func ignoredAppsView() -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .width
        outer.spacing = 0
        outer.translatesAutoresizingMaskIntoConstraints = false

        if store.preferences.ignoredApplications.isEmpty {
            let label = NSTextField(labelWithString: L10n.t("settings.noIgnoredApps"))
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText
            label.translatesAutoresizingMaskIntoConstraints = false
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: 38),
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: holder.centerYAnchor)
            ])
            outer.addArrangedSubview(holder)
        } else {
            for app in store.preferences.ignoredApplications {
                outer.addArrangedSubview(IgnoredAppRow(application: app) { [weak self] in
                    try? self?.store.removeIgnoredApplication(bundleIdentifier: app.bundleIdentifier)
                    self?.renderContent()
                    self?.onChange(true)
                })
            }
        }

        let controls = NSView()
        controls.wantsLayer = true
        controls.translatesAutoresizingMaskIntoConstraints = false
        let add = NSButton(title: "+", target: self, action: #selector(addIgnoredApplication))
        [add].forEach {
            $0.isBordered = false
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview($0)
        }
        NSLayoutConstraint.activate([
            controls.heightAnchor.constraint(equalToConstant: 30),
            add.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            add.centerYAnchor.constraint(equalTo: controls.centerYAnchor)
        ])
        outer.addArrangedSubview(controls)
        return outer
    }

    private func buildShortcuts(in stack: NSStackView) {
        addSection(to: stack, customView: activationShortcutView())
        addSection(to: stack, rows: [
            .shortcutRow(title: L10n.t("settings.nextPinboard"), keys: "⌘→"),
            .shortcutRow(title: L10n.t("settings.previousPinboard"), keys: "⌘←")
        ])
        addSection(to: stack, rows: [
            .shortcutRow(title: L10n.t("settings.quickPaste"), keys: "⌘ + 1…9"),
            .shortcutRow(title: L10n.t("settings.plainTextMode"), keys: "⇧ Shift")
        ])

        let reset = NSButton(title: L10n.t("settings.resetShortcuts"), target: self, action: #selector(resetShortcuts))
        reset.isEnabled = true
        reset.bezelStyle = .rounded
        reset.controlSize = .regular
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        reset.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(reset)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 42),
            reset.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            reset.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            reset.widthAnchor.constraint(equalToConstant: SettingsMetrics.trailingControlWidth)
        ])
        stack.addArrangedSubview(row)
    }

    private func addSection(to stack: NSStackView, title: String? = nil, subtitle: String? = nil, rows: [SettingsRow]) {
        addSection(to: stack, title: title, subtitle: subtitle, body: SettingsSection(rows: rows))
    }

    private func addSection(to stack: NSStackView, title: String? = nil, subtitle: String? = nil, customView: NSView) {
        addSection(to: stack, title: title, subtitle: subtitle, body: SettingsSection(customView: customView))
    }

    private func addSection(to stack: NSStackView, title: String? = nil, subtitle: String? = nil, body: NSView) {
        if let title {
            let header = sectionTitle(title, subtitle: subtitle)
            stack.addArrangedSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
            stack.setCustomSpacing(6, after: header)
        }
        stack.addArrangedSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        stack.setCustomSpacing(13, after: body)
    }

    private func pinnedVerticalView(_ views: [NSView], spacing: CGFloat = 0) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false

        var previous: NSView?
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: holder.trailingAnchor)
            ])
            if let previous {
                view.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: spacing).isActive = true
            } else {
                view.topAnchor.constraint(equalTo: holder.topAnchor).isActive = true
            }
            previous = view
        }

        if let previous {
            previous.bottomAnchor.constraint(equalTo: holder.bottomAnchor).isActive = true
        }
        return holder
    }

    private func activationShortcutView() -> NSView {
        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .width
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false

        let row = ShortcutCaptureRow(
            title: L10n.t("settings.activatePaste"),
            subtitle: L10n.t("settings.activatePasteHint"),
            shortcut: store.preferences.activationShortcut
        ) { [weak self] shortcut in
            self?.updatePrefs { $0.activationShortcut = shortcut }
            self?.renderContent()
        }
        outer.addArrangedSubview(row)

        let warning = shortcutWarningText()
        if !warning.isEmpty {
            outer.addArrangedSubview(SettingsWarningView(text: warning))
        }
        return outer
    }

    private func shortcutWarningText() -> String {
        let report = HotKeyController.latestReport
        var warnings: [String] = []
        if report.hasPasteConflict {
            warnings.append(L10n.t("settings.shortcutPasteConflict"))
        }
        if report.hasCarbonFailure {
            warnings.append(L10n.t("settings.shortcutRegisterFailed"))
        }
        if !report.accessibilityTrusted {
            warnings.append(L10n.t("settings.shortcutAccessibilityNeeded"))
        } else if report.hasEventTapFailure {
            warnings.append(L10n.t("settings.shortcutEventTapFailed"))
        }
        return warnings.joined(separator: "\n")
    }

    private func sectionTitle(_ title: String, subtitle: String? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText.withAlphaComponent(0.92)
        stack.addArrangedSubview(titleLabel)
        if let subtitle {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.82)
            stack.addArrangedSubview(subtitleLabel)
        }
        return stack
    }

    private func separator(inset: CGFloat = 0) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = EasyPasteThemeStore.effectiveTheme.panelBorder.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            view.topAnchor.constraint(equalTo: holder.topAnchor),
            view.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        return holder
    }

    private func updatePrefs(
        persist: Bool = true,
        reloadPanel: Bool = true,
        _ mutate: @escaping (inout EasyPastePreferences) -> Void
    ) {
        do {
            try store.updatePreferences(mutate, persist: persist)
            onChange(reloadPanel)
        } catch {
            NSLog("EasyPaste preferences save failed: \(error.localizedDescription)")
        }
    }

    private func schedulePreferenceSave() {
        pendingPreferenceSaveTask?.cancel()
        pendingPreferenceSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            do {
                try self.store.save()
            } catch {
                NSLog("EasyPaste debounced preferences save failed: \(error.localizedDescription)")
            }
            self.pendingPreferenceSaveTask = nil
        }
    }

    private func applyTheme() {
        let theme = EasyPasteThemeStore.effectiveTheme
        window?.appearance = EasyPasteThemeStore.appearance
        let background = settingsBackgroundColor(theme)
        window?.backgroundColor = background
        rootView.layer?.backgroundColor = background.cgColor
        sidebarView.layer?.backgroundColor = settingsSidebarColor(theme).cgColor
        sidebarView.layer?.borderColor = settingsStrokeColor(theme).cgColor
    }

    private func settingsBackgroundColor(_ theme: EasyPasteTheme) -> NSColor {
        theme.isDark
            ? NSColor(calibratedRed: 0.088, green: 0.095, blue: 0.108, alpha: 1)
            : NSColor(calibratedRed: 0.958, green: 0.964, blue: 0.974, alpha: 1)
    }

    private func settingsSidebarColor(_ theme: EasyPasteTheme) -> NSColor {
        theme.isDark
            ? NSColor(calibratedRed: 0.070, green: 0.078, blue: 0.092, alpha: 0.95)
            : NSColor(calibratedRed: 0.988, green: 0.991, blue: 0.996, alpha: 0.96)
    }

    private func settingsStrokeColor(_ theme: EasyPasteTheme) -> NSColor {
        theme.isDark
            ? NSColor.white.withAlphaComponent(0.065)
            : NSColor.black.withAlphaComponent(0.070)
    }

    @objc private func historyChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard HistoryRetention.allCases.indices.contains(index) else { return }
        updatePrefs { $0.historyRetention = HistoryRetention.allCases[index] }
    }

    @objc private func resetShortcuts() {
        updatePrefs { $0.activationShortcut = .defaultActivation }
        renderContent()
    }

    @objc private func eraseHistory() {
        let alert = NSAlert()
        alert.messageText = L10n.t("settings.eraseConfirmTitle")
        alert.informativeText = L10n.t("settings.eraseConfirmText")
        alert.addButton(withTitle: L10n.t("settings.erase"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            try? store.clearHistory()
            renderContent()
            onChange(true)
        }
    }

    @objc private func clearLocalData() {
        onClearLocalData()
    }

    @objc private func addIgnoredApplication() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("settings.addApp")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            return
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        try? store.addIgnoredApplication(IgnoredApplication(name: name, bundleIdentifier: bundleID, path: url.path))
        renderContent()
        onChange(true)
    }
}

@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsSidebarItem: NSView {
    var onClick: (() -> Void)?
    private let selected: Bool
    private let titleLabel = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(title: String, symbol: String, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        let theme = EasyPasteThemeStore.effectiveTheme
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(theme.isDark ? 0.18 : 0.12).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 0.5 : 0
        layer?.borderColor = selected
            ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
            : NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = selected ? NSColor.controlAccentColor : theme.secondaryText.withAlphaComponent(0.72)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: selected ? .semibold : .medium)
        titleLabel.textColor = selected ? theme.primaryText : theme.secondaryText.withAlphaComponent(0.92)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
private enum SettingsRow {
    case switchRow(title: String, subtitle: String? = nil, isOn: Bool, onChange: (Bool) -> Void)
    case segmentedRow(title: String, labels: [String], selected: Int, onChange: (Int) -> Void)
    case sliderRow(title: String, subtitle: String? = nil, value: Double, min: Double, max: Double, isEnabled: Bool, disabledReason: String?, formatter: (Double) -> String, onChange: (Double) -> Void)
    case shortcutRow(title: String, keys: String)
}

@MainActor
private final class SettingsSection: NSView {
    init(rows: [SettingsRow]) {
        super.init(frame: .zero)
        build(rows.map { rowView($0) })
    }

    init(customView: NSView) {
        super.init(frame: .zero)
        build([customView])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build(_ views: [NSView]) {
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        let theme = EasyPasteThemeStore.effectiveTheme
        layer?.borderColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.black.withAlphaComponent(0.060)
        ).cgColor
        layer?.backgroundColor = (theme.isDark
            ? NSColor(calibratedRed: 0.104, green: 0.113, blue: 0.128, alpha: 0.98)
            : NSColor(calibratedWhite: 1.0, alpha: 0.86)
        ).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for (index, view) in views.enumerated() {
            stack.addArrangedSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
            if index < views.count - 1 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = (theme.isDark
                    ? NSColor.white.withAlphaComponent(0.045)
                    : NSColor.black.withAlphaComponent(0.050)
                ).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
                stack.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
            }
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }

    private func rowView(_ row: SettingsRow) -> NSView {
        switch row {
        case .switchRow(let title, let subtitle, let isOn, let onChange):
            return SwitchRow(title: title, subtitle: subtitle, isOn: isOn, onChange: onChange)
        case .segmentedRow(let title, let labels, let selected, let onChange):
            return SegmentedRow(title: title, labels: labels, selected: selected, onChange: onChange)
        case .sliderRow(let title, let subtitle, let value, let min, let max, let isEnabled, let disabledReason, let formatter, let onChange):
            return SliderRow(title: title, subtitle: subtitle, value: value, min: min, max: max, isEnabled: isEnabled, disabledReason: disabledReason, formatter: formatter, onChange: onChange)
        case .shortcutRow(let title, let keys):
            return ShortcutRow(title: title, keys: keys)
        }
    }
}

@MainActor
private final class SwitchRow: NSView {
    init(title: String, subtitle: String?, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText
        let subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.84)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.isHidden = subtitle == nil
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.onAction { onChange(toggle.state == .on) }
        [titleLabel, subtitleLabel, toggle].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: subtitle == nil ? 36 : 50),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: subtitle == nil ? 9 : 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class SegmentedRow: NSView {
    init(title: String, labels: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = selected
        control.segmentStyle = .rounded
        control.controlSize = .small
        let segmentWidth = SettingsMetrics.trailingControlWidth / CGFloat(max(labels.count, 1))
        for index in labels.indices {
            control.setWidth(segmentWidth, forSegment: index)
        }
        control.onAction { onChange(control.selectedSegment) }
        [titleLabel, control].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: SettingsMetrics.trailingControlWidth)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class SliderRow: NSView {
    init(
        title: String,
        subtitle: String?,
        value: Double,
        min: Double,
        max: Double,
        isEnabled: Bool,
        disabledReason: String?,
        formatter: @escaping (Double) -> String,
        onChange: @escaping (Double) -> Void
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText

        let effectiveSubtitle = disabledReason ?? subtitle
        let subtitleLabel = NSTextField(labelWithString: effectiveSubtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.84)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.isHidden = effectiveSubtitle == nil

        let valueLabel = NSTextField(labelWithString: isEnabled ? formatter(value) : L10n.t("settings.panelGlassUnavailable"))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        valueLabel.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.90)
        valueLabel.alignment = .right
        valueLabel.cell?.usesSingleLineMode = true

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.isEnabled = isEnabled
        slider.onAction {
            guard slider.isEnabled else { return }
            valueLabel.stringValue = formatter(slider.doubleValue)
            onChange(slider.doubleValue)
        }
        if !isEnabled {
            [titleLabel, subtitleLabel, valueLabel, slider].forEach { $0.alphaValue = 0.52 }
        }

        [titleLabel, subtitleLabel, valueLabel, slider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: effectiveSubtitle == nil ? 44 : 58),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: effectiveSubtitle == nil ? 12 : 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -16),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: slider.leadingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderValueWidth),

            slider.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.widthAnchor.constraint(equalToConstant: SettingsMetrics.sliderWidth)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class RadioOptionView: NSView {
        var onClick: (() -> Void)?
    init(selected: Bool, title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let ring = NSView()
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 7
        ring.layer?.borderWidth = 1
        ring.layer?.borderColor = (selected
            ? NSColor.controlAccentColor
            : EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.28)
        ).cgColor
        ring.layer?.backgroundColor = NSColor.clear.cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        ring.addSubview(dot)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText.withAlphaComponent(selected ? 0.96 : 0.82)
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = .systemFont(ofSize: 11, weight: .regular)
        sub.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.82)
        sub.maximumNumberOfLines = 2
        [ring, titleLabel, sub].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            ring.widthAnchor.constraint(equalToConstant: 14),
            ring.heightAnchor.constraint(equalToConstant: 14),
            dot.centerXAnchor.constraint(equalTo: ring.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            sub.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

@MainActor
private final class CheckboxRow: NSView {
    init(title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        checkbox.state = isOn ? .on : .off
        checkbox.controlSize = .small
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        checkbox.onAction { onChange(checkbox.state == .on) }
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ShortcutCaptureRow: NSView {
    init(title: String, subtitle: String, shortcut: KeyboardShortcut, onChange: @escaping (KeyboardShortcut) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = EasyPasteThemeStore.effectiveTheme.primaryText

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = EasyPasteThemeStore.effectiveTheme.secondaryText.withAlphaComponent(0.84)
        subtitleLabel.maximumNumberOfLines = 2

        let recorder = ShortcutRecorderField(shortcut: shortcut, onChange: onChange)

        [titleLabel, subtitleLabel, recorder].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -14),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: recorder.leadingAnchor, constant: -14),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            recorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            recorder.centerYAnchor.constraint(equalTo: centerYAnchor),
            recorder.widthAnchor.constraint(equalToConstant: SettingsMetrics.shortcutControlWidth),
            recorder.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ShortcutRecorderField: NSView {
    private var shortcut: KeyboardShortcut
    private let onChange: (KeyboardShortcut) -> Void
    private let label = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet { applyStyle() }
    }

    init(shortcut: KeyboardShortcut, onChange: @escaping (KeyboardShortcut) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false

        label.alignment = .center
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            return
        }
        guard let newShortcut = ShortcutFormatter.shortcut(from: event) else {
            NSSound.beep()
            isRecording = true
            return
        }
        shortcut = newShortcut
        isRecording = false
        onChange(newShortcut)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    private func applyStyle() {
        let theme = EasyPasteThemeStore.effectiveTheme
        label.stringValue = isRecording
            ? L10n.t("settings.shortcutRecording")
            : ShortcutFormatter.displayString(for: shortcut)
        label.textColor = isRecording ? .white : theme.primaryText
        layer?.backgroundColor = isRecording
            ? NSColor.controlAccentColor.cgColor
            : (theme.isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.white.withAlphaComponent(0.74)
            ).cgColor
        layer?.borderColor = isRecording
            ? NSColor.controlAccentColor.cgColor
            : theme.panelBorder.cgColor
    }
}

@MainActor
private final class SettingsWarningView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(EasyPasteThemeStore.effectiveTheme.isDark ? 0.18 : 0.12).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemOrange
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = EasyPasteThemeStore.effectiveTheme.primaryText
        label.maximumNumberOfLines = 4
        [icon, label].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ShortcutRow: NSView {
    init(title: String, keys: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = EasyPasteThemeStore.effectiveTheme.primaryText
        let key = KeycapView(text: keys)
        [label, key].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.trailingAnchor.constraint(equalTo: trailingAnchor),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.widthAnchor.constraint(equalToConstant: SettingsMetrics.shortcutControlWidth),
            key.heightAnchor.constraint(equalToConstant: 27)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class KeycapView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.alignment = .center
        label.cell?.usesSingleLineMode = true
        label.cell?.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyTheme() {
        let theme = EasyPasteThemeStore.effectiveTheme
        layer?.backgroundColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.105)
            : NSColor.black.withAlphaComponent(0.060)
        ).cgColor
        layer?.borderColor = (theme.isDark
            ? NSColor.white.withAlphaComponent(0.070)
            : NSColor.black.withAlphaComponent(0.060)
        ).cgColor
        label.textColor = theme.primaryText.withAlphaComponent(0.94)
    }
}

@MainActor
private final class IgnoredAppRow: NSView {
    init(application: IgnoredApplication, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        if let path = application.path {
            icon.image = NSWorkspace.shared.icon(forFile: path)
        } else {
            icon.image = NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: application.name)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = EasyPasteThemeStore.effectiveTheme.primaryText
        let remove = NSButton(title: "×", target: nil, action: nil)
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 15, weight: .bold)
        remove.onAction(onRemove)
        [icon, label, remove].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ClosureSleeve: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }
    @objc func invoke() {
        closure()
    }
}

@MainActor
private var closureSleeveKey: UInt8 = 0

@MainActor
private extension NSControl {
    func onAction(_ closure: @escaping () -> Void) {
        let sleeve = ClosureSleeve(closure)
        objc_setAssociatedObject(self, &closureSleeveKey, sleeve, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        target = sleeve
        action = #selector(ClosureSleeve.invoke)
    }
}
