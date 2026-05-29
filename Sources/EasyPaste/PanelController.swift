import AppKit
import Carbon
import EasyPasteCore

/// 面板尺寸/间距按屏幕比例缩放。同一台 13" Air 和 27" iMac 上看起来组件比例一致。
@MainActor
struct PanelMetrics {
    let scale: CGFloat
    var panelHeight: CGFloat { round(305 * scale) }
    var toolbarButtonSize: CGFloat { round(27 * scale) }
    var cardSpacing: CGFloat { round(17 * scale) }
    var hPad: CGFloat { round(19 * scale) }
    var vPad: CGFloat { round(13 * scale) }
    var panelHorizontalInsetRatio: CGFloat { 0.010 }
    var panelBottomInsetRatio: CGFloat { 0.006 }
    var panelCornerRadius: CGFloat { round(22 * scale) }
    var pillHeight: CGFloat { round(25 * scale) }
    var pillRadius: CGFloat { 13 * scale }
    var pillFontSize: CGFloat { 12 * scale }
    var pillIconSize: CGFloat { round(13 * scale) }
    var searchHeight: CGFloat { round(27 * scale) }
    var tabHeight: CGFloat { round(27 * scale) }
    var toolbarHeight: CGFloat { round(29 * scale) }
    var toolbarSymbolSize: CGFloat { round(14 * scale) }
    var toolbarButtonRadius: CGFloat { round(8 * scale) }
}

/// 当前面板度量（在 show 前由 PanelController 根据屏幕设置）。
@MainActor
enum PanelLayout {
    nonisolated(unsafe) static var current = PanelMetrics(scale: 1.0)
}

@MainActor
private enum PanelShortcutHintMode: Equatable {
    case none
    case commandNumbers
    case plainText
    case commandNumbersAndPlainText
}

@MainActor
private enum PanelReloadScrollBehavior {
    case selected
    case leading
}

@MainActor
private enum PanelReloadMode {
    case initialLightweight
    case fullReuse
}

private struct CardRenderSignature: Equatable {
    var selector: BoardSelector
    var query: String
    var itemKeys: [String]
}

/// 根据屏幕高度计算 scale；裁到 [0.85, 1.30]，保证 13" 不太挤、27" 不太空。
@MainActor
func computeUIScale(for screen: NSScreen?) -> CGFloat {
    let h = screen?.frame.height ?? 1080
    let s = h / 1080.0
    return max(0.85, min(1.30, s))
}

@MainActor
final class PanelController: NSObject {
    private let store: ClipboardStore
    private let clipboardController: ClipboardController
    private let onPreferencesChanged: () -> Void
    private let onClearLocalData: () -> Void
    private let window: QuickPanel
    private var targetApplication: NSRunningApplication?

    private var visibleItems: [ClipboardItem] = []
    private var selectedItemID: UUID?
    private var formatPicker: FormatPickerView?
    private var ignoreResignKeyUntil: Date?
    private var isPresentingPanelDialog = false
    private var acceptedKeySinceShow = false
    private var shortcutHintMode: PanelShortcutHintMode = .none
    private var localKeyMonitor: Any?
    private var localModifierMonitor: Any?
    private var globalModifierMonitor: Any?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var glassCapabilityObserver: NSObjectProtocol?
    private var modifierPollTimer: Timer?
    private var quickPasteHotKeyRefs: [EventHotKeyRef] = []
    private var quickPasteHotKeyHandler: EventHandlerRef?
    private var quickPasteInputCharacters: [Int: String] = [:]
    private var settingsWindowController: SettingsWindowController?
    private var lastRenderedCardSignature: CardRenderSignature?
    private var renderedCardCount = 0
    private let minimumInitialCardRenderLimit = 8
    private let maximumInitialCardRenderLimit = 14
    private let cardRenderBatchSize = 10

    private let rootView = NSView()
    private let panelEffectView = NSVisualEffectView()
    private let panelBackdropView = NSView()
    private let titlePill = NSView()
    private let titleLabel = NSTextField(labelWithString: "Clipboard")
    private let clipboardIcon = NSImageView()
    private let searchToggleButton = SymbolButton(symbol: "magnifyingglass", tooltip: "搜索 (⌘F)")
    private let addButton = SymbolButton(symbol: "plus", tooltip: "新建 Pinboard (⇧⌘N)")
    private let pauseButton = SymbolButton(symbol: "pause.fill", tooltip: "暂停/继续记录 (⌘T)")
    private let moreButton = SymbolButton(symbol: "ellipsis", tooltip: "更多")

    private let searchField = GlassSearchField()
    private let tabStrip = PinboardTabStrip()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let cardStack = NSStackView()
    private weak var emptyView: NSView?

    init(
        store: ClipboardStore,
        clipboardController: ClipboardController,
        onPreferencesChanged: @escaping () -> Void = {},
        onClearLocalData: @escaping () -> Void = {}
    ) {
        self.store = store
        self.clipboardController = clipboardController
        self.onPreferencesChanged = onPreferencesChanged
        self.onClearLocalData = onClearLocalData

        // 选最大的屏幕作为 scale 基准，让 UI 在大屏上更舒展、小屏上更紧凑。
        let largestScreen = NSScreen.screens.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        let scale = computeUIScale(for: largestScreen ?? NSScreen.main)
        PanelLayout.current = PanelMetrics(scale: scale)
        CardLayout.current = CardMetrics(scale: scale)

        let initialWidth = largestScreen?.frame.width ?? NSScreen.main?.frame.width ?? 1280
        window = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: PanelLayout.current.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()
        buildWindow()
        updatePillTitle()
        updatePauseButton()
        themeObserver = NotificationCenter.default.addObserver(
            forName: EasyPasteThemeStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyTheme()
                self?.lastRenderedCardSignature = nil
                self?.reloadDataKeepingLeadingEdge()
            }
        }
        glassCapabilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyTheme()
            }
        }

        // 失去 key 状态时自动收起面板（用户点别处 / 完成粘贴）。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        if let glassCapabilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(glassCapabilityObserver)
        }
    }

    @objc private func handleBecomeKey(_ note: Notification) {
        acceptedKeySinceShow = true
    }

    @objc private func handleResignKey(_ note: Notification) {
        // 排除：弹出 alert（创建/重命名 board）会暂时夺走 key，但 alert 关闭会回来；
        // 我们只在用户真正切到别的应用 / 点击别处时收起。
        // 用一个延后判断：如果短时间内 panel 仍不是 key 也不在 modal 流程，再收起。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            guard let self else { return }
            if let ignoreUntil = self.ignoreResignKeyUntil, Date() < ignoreUntil { return }
            if self.isPresentingPanelDialog { return }
            guard self.acceptedKeySinceShow else { return }
            // 如果当前 key window 是我们这个 panel 或者其子 alert，不收起。
            let key = NSApp.keyWindow
            if key === self.window { return }
            if let key, key.sheetParent === self.window { return }
            if self.isSettingsWindowVisible { return }
            // alert 弹起时 NSApp.modalWindow 会非 nil，让出主导权
            if NSApp.modalWindow != nil { return }
            self.hideAnimated()
        }
    }

    func toggle(targetApplication: NSRunningApplication?) {
        if window.isVisible {
            hideAnimated()
        } else {
            show(targetApplication: targetApplication)
        }
    }

    func show(targetApplication: NSRunningApplication?) {
        let showStart = EasyPasteDiagnostics.now()
        if store.preferences.showDuringScreenSharing == false,
           Self.isAnyScreenCaptured() {
            EasyPasteDiagnostics.log("panel.show.skipped", ["reason": "screenSharing"])
            return
        }
        self.targetApplication = targetApplication
        selectedItemID = nil
        applyTheme()
        startPanelKeyMonitoring()
        startModifierMonitoring()
        startDismissMonitoring()
        positionWindow()        // 先确定 window 大小
        reloadData(scrollBehavior: .leading, mode: .initialLightweight)
        updateShortcutHints(for: NSEvent.modifierFlags)
        showAnimated()
        EasyPasteDiagnostics.log("panel.show.firstFrame", [
            "ms": EasyPasteDiagnostics.elapsedMS(since: showStart),
            "visible": "\(visibleItems.count)",
            "rendered": "\(renderedCardCount)"
        ])
        hydrateRenderedCards()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 35_000_000)
            guard let self, self.window.isVisible else { return }
            let syncStart = EasyPasteDiagnostics.now()
            let captured = self.clipboardController.syncNow()
            EasyPasteDiagnostics.log("panel.show.postSync", [
                "captured": "\(captured)",
                "ms": EasyPasteDiagnostics.elapsedMS(since: syncStart)
            ])
        }
    }

    /// 把面板从屏幕底向上滑入 + 淡入，避免突兀闪现。
    /// 关键点：不动 window frame（全宽 vibrancy 窗口每帧 setFrame 极卡），
    /// 改用 rootView.layer 的 affine transform + opacity 做内部动画，
    /// WindowServer 只合成一次玻璃背景。
    private func showAnimated() {
        ignoreResignKeyUntil = Date().addingTimeInterval(0.45)
        acceptedKeySinceShow = false
        // 1. window 立刻就位，但先让 rootView 透明 + 下沉，避免肉眼看到突兀的 frame jump
        rootView.wantsLayer = true
        if let layer = rootView.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.setAffineTransform(CGAffineTransform(translationX: 0, y: -18))
            CATransaction.commit()
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        positionWindow()
        acceptedKeySinceShow = false

        // 2. 在 contentView 里做 layer 动画 — 比 window.animator().setFrame 平滑得多
        if let layer = rootView.layer {
            let timing = CAMediaTimingFunction(controlPoints: 0.20, 0.90, 0.30, 1.00) // easeOutQuart 风格
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.22)
            CATransaction.setAnimationTimingFunction(timing)

            let translate = CABasicAnimation(keyPath: "transform")
            translate.fromValue = CATransform3DMakeTranslation(0, -18, 0)
            translate.toValue = CATransform3DIdentity
            layer.add(translate, forKey: "showSlide")
            layer.transform = CATransform3DIdentity

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            layer.add(fade, forKey: "showFade")
            layer.opacity = 1

            CATransaction.commit()
        }
    }

    /// 反向：rootView 下滑 + 淡出后再 orderOut。
    func hideAnimated() {
        guard window.isVisible else { return }
        guard let layer = rootView.layer else {
            resetSearchStateForNextShow()
            window.orderOut(nil)
            return
        }

        let timing = CAMediaTimingFunction(controlPoints: 0.50, 0.00, 0.75, 0.20) // easeInQuart
        stopPanelKeyMonitoring()
        stopDismissMonitoring()
        stopModifierMonitoring()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(timing)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.window.orderOut(nil)
                self.resetSearchStateForNextShow()
                self.updateShortcutHints(mode: .none)
                self.stopPanelKeyMonitoring()
                self.stopModifierMonitoring()
                self.stopDismissMonitoring()
                // 还原 layer 到初始态，给下次 show 用
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.rootView.layer?.opacity = 1
                self.rootView.layer?.setAffineTransform(.identity)
                CATransaction.commit()
                if self.store.preferences.runInBackground == false {
                    NSApp.terminate(nil)
                }
            }
        }

        let translate = CABasicAnimation(keyPath: "transform")
        translate.fromValue = CATransform3DIdentity
        translate.toValue = CATransform3DMakeTranslation(0, -14, 0)
        layer.add(translate, forKey: "hideSlide")
        layer.transform = CATransform3DMakeTranslation(0, -14, 0)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        layer.add(fade, forKey: "hideFade")
        layer.opacity = 0

        CATransaction.commit()
    }

    func reloadData() {
        reloadData(scrollBehavior: .selected)
    }

    func storeDidChange() {
        guard window.isVisible else {
            lastRenderedCardSignature = nil
            return
        }
        let previousFirstID = visibleItems.first?.id
        let nextVisibleItems = ClipboardSearch.filteredItems(
            store.items(in: store.activeBoardSelector),
            query: searchField.stringValue,
            selector: .all
        )
        let newLeadingItem = nextVisibleItems.first?.id != nil && nextVisibleItems.first?.id != previousFirstID
        reloadData(scrollBehavior: newLeadingItem ? .leading : .selected)
    }

    func openSettingsFromMenu() {
        openSettings()
    }

    func prepareForLocalDataCleanup() {
        dismissFormatPicker()
        settingsWindowController?.close()
        settingsWindowController = nil
        hideAnimated()
    }

    private func reloadDataKeepingLeadingEdge() {
        reloadData(scrollBehavior: .leading)
    }

    private func reloadData(
        scrollBehavior: PanelReloadScrollBehavior,
        mode: PanelReloadMode = .fullReuse
    ) {
        let reloadStart = EasyPasteDiagnostics.now()
        let baseItems = store.items(in: store.activeBoardSelector)
        visibleItems = ClipboardSearch.filteredItems(
            baseItems,
            query: searchField.stringValue,
            selector: .all
        )

        if visibleItems.isEmpty {
            selectedItemID = nil
        } else if !visibleItems.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = visibleItems[0].id
        }

        updatePillTitle()
        rebuildTabs()
        let initialRenderLimit = visibleInitialCardRenderLimit()
        if scrollBehavior == .leading || renderedCardCount == 0 {
            renderedCardCount = min(visibleItems.count, initialRenderLimit)
        } else {
            renderedCardCount = min(visibleItems.count, max(renderedCardCount, initialRenderLimit))
        }
        let signature = cardRenderSignature()
        let needsCards = visibleItems.isEmpty
            ? emptyView == nil
            : cardStack.arrangedSubviews.isEmpty
        if signature != lastRenderedCardSignature || needsCards {
            rebuildCards(mode: mode)
            lastRenderedCardSignature = signature
        } else {
            updateRenderedCardState()
        }
        switch scrollBehavior {
        case .selected:
            scrollSelectedCardIntoView()
        case .leading:
            scrollCardsToLeading()
        }
        dismissFormatPicker()
        updatePauseButton()
        if window.isVisible {
            hydrateRenderedCards()
        }
        EasyPasteDiagnostics.log("panel.reload", [
            "base": "\(baseItems.count)",
            "visible": "\(visibleItems.count)",
            "rendered": "\(renderedCardCount)",
            "cards": "\(cardStack.arrangedSubviews.count)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: reloadStart)
        ])
    }

    private func cardRenderSignature() -> CardRenderSignature {
        CardRenderSignature(
            selector: store.activeBoardSelector,
            query: searchField.stringValue,
            itemKeys: Array(visibleItems.prefix(renderedCardCount)).map { item in
                "\(item.id.uuidString):\(item.hash):\(item.updatedAt.timeIntervalSinceReferenceDate):\(item.pinned)"
            } + ["count:\(visibleItems.count)", "rendered:\(renderedCardCount)"]
        )
    }

    private func visibleInitialCardRenderLimit() -> Int {
        rootView.layoutSubtreeIfNeeded()
        let visibleWidth = max(scrollView.contentView.bounds.width, window.frame.width - PanelLayout.current.hPad * 2)
        let stride = max(CardLayout.cardWidth + PanelLayout.current.cardSpacing, 1)
        let visibleCards = Int(ceil(visibleWidth / stride))
        return min(maximumInitialCardRenderLimit, max(minimumInitialCardRenderLimit, visibleCards + 2))
    }

    private func updatePillTitle() {
        let boardName: String
        switch store.activeBoardSelector {
        case .all: boardName = "Clipboard"
        case .pinned: boardName = "Pinned"
        case .board(let id): boardName = store.name(for: .board(id))
        }
        titleLabel.stringValue = boardName
    }

    // MARK: - Build

    private func buildWindow() {
        window.isFloatingPanel = true
        // 顶到所有应用、Dock 和菜单栏上方；isFloatingPanel 会把 level 设回 floating，
        // 所以必须在它之后设置 screenSaver level。
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        // canJoinAllSpaces — 在所有 Space 都可见
        // fullScreenAuxiliary — 允许在全屏 App 上方浮起（关键）
        // stationary — 切换 Space 时不跟着动
        // ignoresCycle — 不参与 ⌘` 循环
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
            .transient
        ]
        window.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        window.modifierHandler = { [weak self] flags in
            self?.updateShortcutHints(for: flags)
        }

        // Paste 风格：有边距的深色玻璃浮层，而不是贴边全宽条。
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = PanelLayout.current.panelCornerRadius
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 0.8
        rootView.translatesAutoresizingMaskIntoConstraints = true
        let initialScreenFrame = (currentScreen() ?? NSScreen.main ?? NSScreen.screens.first)?.frame
            ?? NSRect(x: 0, y: 0, width: window.frame.width, height: window.frame.height)
        rootView.frame = rootFrame(
            windowFrame: NSRect(
                x: 0,
                y: 0,
                width: max(window.frame.width, initialScreenFrame.width),
                height: currentPanelHeight() + bottomPanelInset(for: initialScreenFrame)
            ),
            screenFrame: initialScreenFrame
        )

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(rootView)
        window.contentView = container

        let toolbar = makeToolbar()
        configureSearch()
        configureTabStrip()
        configureCardsArea()

        // 用纯约束做竖向布局，避免 NSStackView 在 vertical 时对孩子宽度不友好。
        panelEffectView.blendingMode = .behindWindow
        panelEffectView.state = .active
        panelEffectView.wantsLayer = true
        panelEffectView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(panelEffectView)

        panelBackdropView.wantsLayer = true
        panelBackdropView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(panelBackdropView)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(content)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(toolbar)
        content.addSubview(scrollView)

        let m = PanelLayout.current
        let hPad = m.hPad
        let vTop = m.vPad
        let vBottom = m.vPad

        // 顶层 content 占满 rootView
        NSLayoutConstraint.activate([
            panelEffectView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            panelEffectView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            panelEffectView.topAnchor.constraint(equalTo: rootView.topAnchor),
            panelEffectView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            panelBackdropView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            panelBackdropView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            panelBackdropView.topAnchor.constraint(equalTo: rootView.topAnchor),
            panelBackdropView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.topAnchor.constraint(equalTo: rootView.topAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            // toolbar 顶部
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: vTop),
            toolbar.heightAnchor.constraint(equalToConstant: m.toolbarHeight),

            // scrollView 占据剩余
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: hPad),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -hPad),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -vBottom)
        ])
        applyTheme()
    }

    private func applyTheme() {
        let theme = EasyPasteThemeStore.effectiveTheme
        window.appearance = EasyPasteThemeStore.appearance
        let glassOpacity = min(1.0, max(0.0, store.preferences.panelGlassOpacity))
        let glassAvailable = PanelGlassCapability.isAvailable
        panelEffectView.isHidden = !glassAvailable
        panelEffectView.material = theme.panelMaterial
        panelEffectView.alphaValue = glassAvailable ? 0.28 + 0.72 * glassOpacity : 0
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        panelBackdropView.layer?.backgroundColor = (glassAvailable
            ? theme.panelBackground(opacity: glassOpacity)
            : theme.panelSolidBackground
        ).cgColor
        rootView.layer?.borderColor = theme.panelBorder.cgColor

        titlePill.layer?.backgroundColor = theme.pillBackground.cgColor
        titlePill.layer?.borderColor = theme.pillBorder.cgColor
        titleLabel.textColor = theme.pillText
        clipboardIcon.contentTintColor = theme.pillText

        searchToggleButton.applyTheme(theme)
        addButton.applyTheme(theme)
        pauseButton.applyTheme(theme)
        moreButton.applyTheme(theme)
        searchField.applyTheme(theme)
        tabStrip.applyTheme(theme)
    }

    private func makeToolbar() -> NSView {
        // 中央 Clipboard pill
        titlePill.wantsLayer = true
        titlePill.layer?.cornerRadius = PanelLayout.current.pillRadius
        titlePill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        titlePill.layer?.borderWidth = 0.5
        titlePill.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        titlePill.translatesAutoresizingMaskIntoConstraints = false

        if let img = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 12 * PanelLayout.current.scale, weight: .medium)
            clipboardIcon.image = img.withSymbolConfiguration(config)
        }
        clipboardIcon.imageScaling = .scaleProportionallyDown
        clipboardIcon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: PanelLayout.current.pillFontSize, weight: .medium)
        titleLabel.backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        titlePill.addSubview(clipboardIcon)
        titlePill.addSubview(titleLabel)

        let m = PanelLayout.current
        NSLayoutConstraint.activate([
            titlePill.heightAnchor.constraint(equalToConstant: m.pillHeight),
            titlePill.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            clipboardIcon.leadingAnchor.constraint(equalTo: titlePill.leadingAnchor, constant: 12),
            clipboardIcon.centerYAnchor.constraint(equalTo: titlePill.centerYAnchor),
            clipboardIcon.widthAnchor.constraint(equalToConstant: m.pillIconSize),
            clipboardIcon.heightAnchor.constraint(equalToConstant: m.pillIconSize),
            titleLabel.leadingAnchor.constraint(equalTo: clipboardIcon.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: titlePill.trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: titlePill.centerYAnchor)
        ])

        searchToggleButton.onClick = { [weak self] in self?.toggleSearch() }
        addButton.onClick = { [weak self] in self?.promptCreatePinboard() }
        pauseButton.onClick = { [weak self] in self?.togglePause() }
        moreButton.onClick = { [weak self] in self?.showMoreMenu() }

        // Paste 的工具区集中在中间：搜索、Clipboard/Pinboard 切换、添加。
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.heightAnchor.constraint(equalToConstant: m.toolbarHeight).isActive = true

        let leftGroup = NSStackView(views: [])
        leftGroup.orientation = .horizontal
        leftGroup.spacing = 8
        leftGroup.translatesAutoresizingMaskIntoConstraints = false

        tabStrip.isHidden = true
        let centerGroup = NSStackView(views: [searchToggleButton, titlePill, tabStrip, addButton])
        centerGroup.orientation = .horizontal
        centerGroup.alignment = .centerY
        centerGroup.spacing = 10
        centerGroup.translatesAutoresizingMaskIntoConstraints = false

        let rightGroup = NSStackView(views: [pauseButton, moreButton])
        rightGroup.orientation = .horizontal
        rightGroup.spacing = 8
        rightGroup.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(leftGroup)
        toolbar.addSubview(centerGroup)
        toolbar.addSubview(rightGroup)

        // 搜索框居中、固定为 toolbar 宽度的 ~60%（带上下限），保持合适比例不撑满。
        // 1) 中心对齐 toolbar 中线  2) 等比宽度 60%  3) 不允许超过左/右两侧按钮组
        searchField.placeholder = L10n.t("panel.searchPlaceholder")
        searchField.onTextChange = { [weak self] text in
            guard let self else { return }
            self.reloadData()
            if text.isEmpty {
                self.collapseEmptySearch()
            }
        }
        searchField.onCommitOrCancel = { [weak self] in self?.handleSearchCommitOrCancel() }
        searchField.onHorizontalNavigation = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.isHidden = true
        searchField.alphaValue = 0
        searchField.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(searchField)

        let widthMul = searchField.widthAnchor.constraint(equalTo: toolbar.widthAnchor, multiplier: 0.60)
        widthMul.priority = .defaultHigh
        let widthMin = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        let widthMax = searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 520)

        NSLayoutConstraint.activate([
            leftGroup.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            leftGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            centerGroup.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            centerGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            rightGroup.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            rightGroup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            tabStrip.heightAnchor.constraint(equalToConstant: m.toolbarHeight),
            tabStrip.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            tabStrip.widthAnchor.constraint(lessThanOrEqualTo: toolbar.widthAnchor, multiplier: 0.58),

            // 搜索框水平居中、垂直居中、高度按 metrics
            searchField.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            searchField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: PanelLayout.current.searchHeight),
            // 不能越界到左/右边缘和右侧按钮组
            searchField.leadingAnchor.constraint(greaterThanOrEqualTo: toolbar.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(lessThanOrEqualTo: rightGroup.leadingAnchor, constant: -8),
            widthMul, widthMin, widthMax
        ])

        // 引用一下，方便切换显隐
        self.toolbarLeftGroup = leftGroup
        self.toolbarCenterGroup = centerGroup

        return toolbar
    }

    private weak var toolbarLeftGroup: NSStackView?
    private weak var toolbarCenterGroup: NSStackView?

    private func toggleSearch() {
        if searchField.isHidden {
            focusSearch()
        } else {
            setSearchInline(false)
            window.makeFirstResponder(nil)
            searchToggleButton.isActive = false
        }
    }

    private func configureSearch() {
        // 现在 searchField 已经在 makeToolbar 里被加到 toolbar 上，不再需要独立容器。
        // 这里只做基础属性配置（delegate / placeholder 已在 toolbar 阶段处理）。
    }

    /// 失焦或回车：如果搜索框为空，自动收起回初始按钮态。
    private func handleSearchCommitOrCancel() {
        if searchField.stringValue.isEmpty {
            collapseEmptySearch()
        }
    }

    private func collapseEmptySearch() {
        guard !searchField.isHidden else { return }
        setSearchInline(false)
    }

    private func resetSearchStateForNextShow() {
        searchField.layer?.removeAllAnimations()
        toolbarLeftGroup?.layer?.removeAllAnimations()
        toolbarCenterGroup?.layer?.removeAllAnimations()
        searchField.stringValue = ""
        searchField.isHidden = true
        searchField.alphaValue = 0
        searchField.layer?.setAffineTransform(.identity)
        toolbarLeftGroup?.isHidden = false
        toolbarCenterGroup?.isHidden = false
        toolbarLeftGroup?.alphaValue = 1
        toolbarCenterGroup?.alphaValue = 1
        searchToggleButton.isActive = false
        window.makeFirstResponder(nil)
    }

    /// 内联展开/收起搜索框：动画过渡 — 三组按钮淡出 + 搜索框淡入并轻微放大。
    /// 整个 toolbar 行高度不变，因此卡片不会被往下推。
    private func setSearchInline(_ visible: Bool) {
        // 取消可能正在进行的动画，避免叠加
        searchField.layer?.removeAllAnimations()
        toolbarLeftGroup?.layer?.removeAllAnimations()
        toolbarCenterGroup?.layer?.removeAllAnimations()

        // 确保 layer-backed，便于 alphaValue/transform 动画走 GPU
        searchField.wantsLayer = true
        toolbarLeftGroup?.wantsLayer = true
        toolbarCenterGroup?.wantsLayer = true

        searchToggleButton.isActive = visible

        if visible {
            // 1) 让 searchField 立刻可参与布局，但视觉透明 + 轻微缩小（98%）
            searchField.isHidden = false
            searchField.alphaValue = 0
            if let layer = searchField.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                // 以中心为锚点做缩放，避免左上角跳
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.position = CGPoint(x: searchField.frame.midX, y: searchField.frame.midY)
                layer.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
                CATransaction.commit()
            }

            // 2) 三组按钮和搜索框同时跑动画，左+中淡出，搜索框淡入 + 回到 1.0 缩放
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.90, 0.30, 1.00)
                ctx.allowsImplicitAnimation = true
                toolbarLeftGroup?.animator().alphaValue = 0
                toolbarCenterGroup?.animator().alphaValue = 0
                searchField.animator().alphaValue = 1
                searchField.layer?.setAffineTransform(.identity)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.toolbarLeftGroup?.isHidden = true
                    self?.toolbarCenterGroup?.isHidden = true
                }
            }
        } else {
            // 收起：先把左中两组 unhide 但仍透明，再一起做反向 fade
            toolbarLeftGroup?.isHidden = false
            toolbarCenterGroup?.isHidden = false
            toolbarLeftGroup?.alphaValue = 0
            toolbarCenterGroup?.alphaValue = 0

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.90, 0.30, 1.00)
                ctx.allowsImplicitAnimation = true
                searchField.animator().alphaValue = 0
                toolbarLeftGroup?.animator().alphaValue = 1
                toolbarCenterGroup?.animator().alphaValue = 1
                searchField.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.98, y: 0.98))
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.searchField.isHidden = true
                    // 还原变换
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.searchField.layer?.setAffineTransform(.identity)
                    CATransaction.commit()
                }
            }

            searchField.stringValue = ""
            window.makeFirstResponder(nil)
        }
    }

    private func configureTabStrip() {
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStrip.onSelect = { [weak self] selector in
            self?.selectBoard(selector)
        }
        tabStrip.onCreate = { [weak self] in
            self?.promptCreatePinboard()
        }
        tabStrip.onContextMenu = { [weak self] selector, event in
            self?.showBoardContextMenu(selector, at: event)
        }
        tabStrip.isHidden = true // 仅当用户创建了至少一个 pinboard 才显示
    }

    private func setTabsVisible(_ visible: Bool) {
        tabStrip.isHidden = !visible
        titlePill.isHidden = visible
        addButton.isHidden = visible
    }

    private func configureCardsArea() {
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 用低优先级约束给一个理想高度，让 window 高度真正主导。
        let prefHeight = scrollView.heightAnchor.constraint(equalToConstant: CardLayout.cardHeight + 12)
        prefHeight.priority = .defaultLow
        prefHeight.isActive = true

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        cardStack.orientation = .horizontal
        cardStack.alignment = .top
        cardStack.spacing = PanelLayout.current.cardSpacing
        cardStack.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(cardStack)

        NSLayoutConstraint.activate([
            // 横向列表贴近滚动区底部，视觉上更接近 Paste，底部留白不会显得太厚。
            documentView.topAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.heightAnchor.constraint(equalToConstant: CardLayout.cardHeight + 8),

            cardStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            cardStack.heightAnchor.constraint(equalToConstant: CardLayout.cardHeight + 8)
        ])
    }

    // MARK: - Render

    private func rebuildTabs() {
        let visible = store.visibleBoards
        var names: [BoardSelector: String] = [:]
        for selector in visible {
            names[selector] = store.name(for: selector)
        }
        tabStrip.update(boards: visible, names: names, active: store.activeBoardSelector)
        // 仅当用户已经创建了至少一个 pinboard 才在 toolbar 第一行显示 tab 条。
        let shouldShow = !store.pinboards.isEmpty
        setTabsVisible(shouldShow)
    }

    private func rebuildCards(mode: PanelReloadMode = .fullReuse) {
        let renderStart = EasyPasteDiagnostics.now()
        cardStack.arrangedSubviews.forEach { view in
            cardStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        // 清掉上一次的空态视图
        emptyView?.removeFromSuperview()
        emptyView = nil

        if visibleItems.isEmpty {
            let message: String
            if !searchField.stringValue.isEmpty {
                message = L10n.t("panel.emptySearch")
            } else if store.activeBoardSelector != .all {
                message = L10n.t("panel.emptyBoard")
            } else {
                message = L10n.t("panel.emptyAll")
            }
            // 空态：直接挂在 scrollView 上面，撑满可见区域 + 居中显示，
            // 不放进 cardStack（cardStack 是横向滚动布局，宽度由内容决定，无法整体居中）。
            let view = EmptyClipView(message: message)
            view.translatesAutoresizingMaskIntoConstraints = false
            scrollView.superview?.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
                view.topAnchor.constraint(equalTo: scrollView.topAnchor),
                view.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
            ])
            scrollView.isHidden = true
            emptyView = view
            return
        }

        scrollView.isHidden = false

        appendCards(upTo: renderedCardCount, mode: mode)
        EasyPasteDiagnostics.log("panel.cards.rebuild", [
            "visible": "\(visibleItems.count)",
            "rendered": "\(cardStack.arrangedSubviews.count)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: renderStart)
        ])
    }

    private func appendCards(upTo targetCount: Int, mode: PanelReloadMode = .fullReuse) {
        guard targetCount > cardStack.arrangedSubviews.count else { return }
        let appendStart = EasyPasteDiagnostics.now()
        let previousCount = cardStack.arrangedSubviews.count
        let cappedCount = min(targetCount, visibleItems.count)
        for index in cardStack.arrangedSubviews.count..<cappedCount {
            let item = visibleItems[index]
            let card = ClipCardView(item: item, renderMode: .lightweight)
            card.isSelected = item.id == selectedItemID
            card.shortcutHint = shortcutHint(forCardAt: index)
            card.onSelect = { [weak self] id, shouldPaste, flags in
                guard let self else { return }
                let wasSelected = self.selectedItemID == id
                self.selectItem(id)
                guard shouldPaste else { return }
                guard let item = self.visibleItems.first(where: { $0.id == id }) else { return }
                if flags.contains(.shift), item.kind != .image {
                    self.pasteSelected(transform: .plain)
                } else if wasSelected {
                    self.pasteSelected(transform: .original)
                }
            }
            card.onContextMenu = { [weak self] id, event in
                self?.showItemContextMenu(itemID: id, at: event)
            }
            cardStack.addArrangedSubview(card)
        }
        EasyPasteDiagnostics.log("panel.cards.append", [
            "from": "\(previousCount)",
            "to": "\(cardStack.arrangedSubviews.count)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: appendStart)
        ])
        if window.isVisible || mode == .initialLightweight {
            hydrateRenderedCards()
        }
    }

    private func hydrateRenderedCards() {
        for (index, view) in cardStack.arrangedSubviews.enumerated() {
            guard let card = view as? ClipCardView else { continue }
            card.hydrateAsync(priorityIndex: index)
        }
    }

    private func updateRenderedCardState() {
        emptyView?.isHidden = !visibleItems.isEmpty
        scrollView.isHidden = visibleItems.isEmpty
        for (index, view) in cardStack.arrangedSubviews.enumerated() {
            guard let card = view as? ClipCardView else { continue }
            card.isSelected = card.itemID == selectedItemID
            card.shortcutHint = shortcutHint(forCardAt: index)
        }
    }

    @objc private func scrollViewBoundsDidChange(_ note: Notification) {
        extendRenderedCardsIfNeeded()
    }

    private func extendRenderedCardsIfNeeded() {
        guard renderedCardCount < visibleItems.count,
              !cardStack.arrangedSubviews.isEmpty else { return }
        documentView.layoutSubtreeIfNeeded()
        let remainingWidth = cardStack.frame.maxX - scrollView.contentView.bounds.maxX
        guard remainingWidth < CardLayout.cardWidth * 4 else { return }
        renderedCardCount = min(visibleItems.count, renderedCardCount + cardRenderBatchSize)
        appendCards(upTo: renderedCardCount)
        lastRenderedCardSignature = cardRenderSignature()
        updateRenderedCardState()
        hydrateRenderedCards()
    }

    private func updatePauseButton() {
        pauseButton.setSymbol(clipboardController.isPaused ? "play.fill" : "pause.fill")
    }

    private func startPanelKeyMonitoring() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.window === self.window, self.window.isVisible else { return event }

            if self.handlePanelShortcut(event) {
                return nil
            }

            return event
        }
    }

    private func stopPanelKeyMonitoring() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func startModifierMonitoring() {
        guard localModifierMonitor == nil, globalModifierMonitor == nil, modifierPollTimer == nil else { return }

        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                self?.updateShortcutHints(for: flags)
            }
            return event
        }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor in
                self?.updateShortcutHints(for: flags)
            }
        }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateShortcutHints(for: NSEvent.modifierFlags)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierPollTimer = timer
    }

    private func stopModifierMonitoring() {
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }
    }

    private func startQuickPasteHotKeys() {
        guard quickPasteHotKeyRefs.isEmpty, quickPasteHotKeyHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                let pointer = UInt(bitPattern: userData)
                let shortcutID = Int(hotKeyID.id)
                Task { @MainActor in
                    guard let rawPointer = UnsafeRawPointer(bitPattern: pointer) else { return }
                    let controller = Unmanaged<PanelController>.fromOpaque(rawPointer).takeUnretainedValue()
                    controller.handleQuickPasteHotKey(shortcutID)
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &quickPasteHotKeyHandler
        )

        let signature = fourCharCode("EPQP")
        let digitKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9)
        ]

        for (index, keyCode) in digitKeyCodes.enumerated() {
            registerQuickPasteHotKey(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey),
                hotKeyID: EventHotKeyID(signature: signature, id: UInt32(100 + index))
            )
            registerQuickPasteHotKey(
                keyCode: keyCode,
                modifiers: UInt32(cmdKey) | UInt32(shiftKey),
                hotKeyID: EventHotKeyID(signature: signature, id: UInt32(200 + index))
            )
        }

        let modifierVariants: [(UInt32, Bool)] = [
            (0, false),
            (UInt32(shiftKey), true),
            (UInt32(cmdKey), false),
            (UInt32(cmdKey) | UInt32(shiftKey), true)
        ]
        for (variantIndex, variant) in modifierVariants.enumerated() {
            let baseID = UInt32(300 + variantIndex * 10)
            registerQuickPasteHotKey(
                keyCode: UInt32(kVK_LeftArrow),
                modifiers: variant.0,
                hotKeyID: EventHotKeyID(signature: signature, id: baseID)
            )
            registerQuickPasteHotKey(
                keyCode: UInt32(kVK_RightArrow),
                modifiers: variant.0,
                hotKeyID: EventHotKeyID(signature: signature, id: baseID + 1)
            )
            registerQuickPasteHotKey(
                keyCode: UInt32(kVK_Return),
                modifiers: variant.0,
                hotKeyID: EventHotKeyID(signature: signature, id: baseID + (variant.1 ? 4 : 2))
            )
            registerQuickPasteHotKey(
                keyCode: UInt32(kVK_ANSI_KeypadEnter),
                modifiers: variant.0,
                hotKeyID: EventHotKeyID(signature: signature, id: baseID + (variant.1 ? 5 : 3))
            )
        }

        registerQuickPasteHotKey(
            keyCode: UInt32(kVK_Escape),
            modifiers: 0,
            hotKeyID: EventHotKeyID(signature: signature, id: 500)
        )
        registerQuickPasteHotKey(
            keyCode: UInt32(kVK_Tab),
            modifiers: 0,
            hotKeyID: EventHotKeyID(signature: signature, id: 501)
        )
        registerQuickPasteHotKey(
            keyCode: UInt32(kVK_Delete),
            modifiers: 0,
            hotKeyID: EventHotKeyID(signature: signature, id: 502)
        )
        registerSearchCharacterHotKeys(signature: signature)
    }

    private func registerSearchCharacterHotKeys(signature: OSType) {
        quickPasteInputCharacters.removeAll()
        let characters: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_A), "a"), (UInt32(kVK_ANSI_B), "b"), (UInt32(kVK_ANSI_C), "c"),
            (UInt32(kVK_ANSI_D), "d"), (UInt32(kVK_ANSI_E), "e"), (UInt32(kVK_ANSI_F), "f"),
            (UInt32(kVK_ANSI_G), "g"), (UInt32(kVK_ANSI_H), "h"), (UInt32(kVK_ANSI_I), "i"),
            (UInt32(kVK_ANSI_J), "j"), (UInt32(kVK_ANSI_K), "k"), (UInt32(kVK_ANSI_L), "l"),
            (UInt32(kVK_ANSI_M), "m"), (UInt32(kVK_ANSI_N), "n"), (UInt32(kVK_ANSI_O), "o"),
            (UInt32(kVK_ANSI_P), "p"), (UInt32(kVK_ANSI_Q), "q"), (UInt32(kVK_ANSI_R), "r"),
            (UInt32(kVK_ANSI_S), "s"), (UInt32(kVK_ANSI_T), "t"), (UInt32(kVK_ANSI_U), "u"),
            (UInt32(kVK_ANSI_V), "v"), (UInt32(kVK_ANSI_W), "w"), (UInt32(kVK_ANSI_X), "x"),
            (UInt32(kVK_ANSI_Y), "y"), (UInt32(kVK_ANSI_Z), "z"),
            (UInt32(kVK_ANSI_0), "0"), (UInt32(kVK_ANSI_1), "1"), (UInt32(kVK_ANSI_2), "2"),
            (UInt32(kVK_ANSI_3), "3"), (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"),
            (UInt32(kVK_ANSI_6), "6"), (UInt32(kVK_ANSI_7), "7"), (UInt32(kVK_ANSI_8), "8"),
            (UInt32(kVK_ANSI_9), "9"),
            (UInt32(kVK_Space), " "), (UInt32(kVK_ANSI_Minus), "-"), (UInt32(kVK_ANSI_Period), "."),
            (UInt32(kVK_ANSI_Comma), ","), (UInt32(kVK_ANSI_Slash), "/")
        ]
        for (offset, entry) in characters.enumerated() {
            let id = 600 + offset
            quickPasteInputCharacters[id] = entry.1
            registerQuickPasteHotKey(
                keyCode: entry.0,
                modifiers: 0,
                hotKeyID: EventHotKeyID(signature: signature, id: UInt32(id))
            )
        }

        let shiftedCharacters: [(UInt32, String)] = [
            (UInt32(kVK_ANSI_Semicolon), ":"),
            (UInt32(kVK_ANSI_Quote), "\""),
            (UInt32(kVK_ANSI_Minus), "_")
        ]
        for (offset, entry) in shiftedCharacters.enumerated() {
            let id = 700 + offset
            quickPasteInputCharacters[id] = entry.1
            registerQuickPasteHotKey(
                keyCode: entry.0,
                modifiers: UInt32(shiftKey),
                hotKeyID: EventHotKeyID(signature: signature, id: UInt32(id))
            )
        }
    }

    private func registerQuickPasteHotKey(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            quickPasteHotKeyRefs.append(ref)
        } else {
            NSLog("EasyPaste failed to register quick paste hotkey id=\(hotKeyID.id) status=\(status)")
        }
    }

    private func stopQuickPasteHotKeys() {
        quickPasteHotKeyRefs.forEach { UnregisterEventHotKey($0) }
        quickPasteHotKeyRefs.removeAll()
        quickPasteInputCharacters.removeAll()
        if let quickPasteHotKeyHandler {
            RemoveEventHandler(quickPasteHotKeyHandler)
            self.quickPasteHotKeyHandler = nil
        }
    }

    private func handleQuickPasteHotKey(_ shortcutID: Int) {
        guard window.isVisible else { return }
        if (100..<109).contains(shortcutID) {
            quickPaste(index: shortcutID - 100, transform: .original)
        } else if (200..<209).contains(shortcutID) {
            quickPastePlainText(index: shortcutID - 200)
        } else if shortcutID >= 300 && shortcutID < 340 && shortcutID % 10 == 0 {
            moveSelection(by: -1)
        } else if shortcutID >= 300 && shortcutID < 340 && shortcutID % 10 == 1 {
            moveSelection(by: 1)
        } else if shortcutID >= 300 && shortcutID < 340 && (shortcutID % 10 == 2 || shortcutID % 10 == 3) {
            pasteSelected(transform: .original)
        } else if shortcutID >= 300 && shortcutID < 340 && (shortcutID % 10 == 4 || shortcutID % 10 == 5) {
            pasteSelected(transform: .plain)
        } else if shortcutID == 500 {
            hideAnimated()
        } else if shortcutID == 501 {
            completeSearchToken()
        } else if shortcutID == 502 {
            deleteSearchCharacter()
        } else if let character = quickPasteInputCharacters[shortcutID] {
            appendSearchCharacter(character)
        }
    }

    private func fourCharCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { result, byte in
            (result << 8) + OSType(byte)
        }
    }

    private func startDismissMonitoring() {
        guard localDismissMonitor == nil, globalDismissMonitor == nil, appActivationObserver == nil else { return }

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) { [weak self] event in
            guard let self else { return event }
            if self.shouldDismiss(forLocalMouseEvent: event) {
                self.hideAnimated()
            }
            return event
        }

        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window.isVisible else { return }
                if self.isSettingsWindowVisible { return }
                if self.isPresentingPanelDialog { return }
                if let ignoreUntil = self.ignoreResignKeyUntil, Date() < ignoreUntil { return }
                self.hideAnimated()
            }
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let activatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, self.window.isVisible else { return }
                if activatedPID == ProcessInfo.processInfo.processIdentifier {
                    return
                }
                if self.isSettingsWindowVisible { return }
                if self.isPresentingPanelDialog { return }
                if let ignoreUntil = self.ignoreResignKeyUntil, Date() < ignoreUntil { return }
                self.hideAnimated()
            }
        }
    }

    private func stopDismissMonitoring() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func shouldDismiss(forLocalMouseEvent event: NSEvent) -> Bool {
        guard window.isVisible else { return false }
        if isSettingsWindowVisible { return false }
        if isPresentingPanelDialog { return false }
        if let ignoreUntil = ignoreResignKeyUntil, Date() < ignoreUntil { return false }
        if event.window === window { return false }
        if let eventWindow = event.window, eventWindow.sheetParent === window { return false }
        return true
    }

    private var isSettingsWindowVisible: Bool {
        settingsWindowController?.window?.isVisible == true
    }

    private func updateShortcutHints(for flags: NSEvent.ModifierFlags) {
        let relevant = flags.intersection([.command, .shift])
        if relevant.contains(.command) && relevant.contains(.shift) {
            updateShortcutHints(mode: .commandNumbersAndPlainText)
        } else if relevant.contains(.command) {
            updateShortcutHints(mode: .commandNumbers)
        } else if relevant.contains(.shift) {
            updateShortcutHints(mode: .plainText)
        } else {
            updateShortcutHints(mode: .none)
        }
    }

    private func updateShortcutHints(mode: PanelShortcutHintMode) {
        guard shortcutHintMode != mode else { return }
        shortcutHintMode = mode
        for (index, view) in cardStack.arrangedSubviews.enumerated() {
            (view as? ClipCardView)?.shortcutHint = shortcutHint(forCardAt: index)
        }
    }

    private func shortcutHint(forCardAt index: Int) -> CardShortcutHint {
        switch shortcutHintMode {
        case .none:
            return .none
        case .commandNumbers:
            return CardShortcutHint(commandNumber: index < 9 ? index + 1 : nil, showsPlainText: false)
        case .plainText:
            return CardShortcutHint(commandNumber: nil, showsPlainText: true)
        case .commandNumbersAndPlainText:
            return CardShortcutHint(commandNumber: index < 9 ? index + 1 : nil, showsPlainText: true)
        }
    }

    // MARK: - Window position

    /// 取鼠标当前所在的屏幕（更符合用户预期），找不到才退化到主屏。
    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return s
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func positionWindow() {
        guard let screen = currentScreen() else {
            window.center()
            return
        }

        // 接近 Paste 的贴底浮层：跟随鼠标所在屏幕，但左右和底部都留一点呼吸感。
        let full = screen.frame
        let visible = screen.visibleFrame
        let bottomInset = bottomPanelInset(for: full)
        applyRootInsets(windowFrame: NSRect(x: 0, y: 0, width: full.width, height: currentPanelHeight() + bottomInset), screenFrame: full)

        let panelHeight = currentPanelHeight()
        let windowHeight = panelHeight + bottomInset
        let target = NSRect(
            x: full.minX,
            y: visible.minY,
            width: full.width,
            height: windowHeight
        )
        window.minSize = NSSize(width: 100, height: 100)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.setFrame(target, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        applyRootInsets(windowFrame: window.frame, screenFrame: full)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func currentPanelHeight() -> CGFloat {
        PanelLayout.current.panelHeight
    }

    private func bottomPanelInset(for screenFrame: NSRect) -> CGFloat {
        round(screenFrame.height * PanelLayout.current.panelBottomInsetRatio)
    }

    private func applyRootInsets(windowFrame: NSRect, screenFrame: NSRect) {
        let frame = rootFrame(windowFrame: windowFrame, screenFrame: screenFrame)
        rootView.frame = frame
        rootView.needsLayout = true
    }

    private func rootFrame(windowFrame: NSRect, screenFrame: NSRect) -> NSRect {
        let effectiveWidth = windowFrame.width > 0 ? windowFrame.width : screenFrame.width
        let effectiveHeight = windowFrame.height > 0 ? windowFrame.height : currentPanelHeight()
        let insetX = round(effectiveWidth * PanelLayout.current.panelHorizontalInsetRatio)
        let bottomInset = round(screenFrame.height * PanelLayout.current.panelBottomInsetRatio)
        return NSRect(
            x: insetX,
            y: bottomInset,
            width: max(0, effectiveWidth - insetX * 2),
            height: max(0, effectiveHeight - bottomInset)
        )
    }

    /// 当 pinboard 列表变化（新增/删除）时调用，让 panel 高度跟着变。
    private func adjustPanelHeightAnimated() {
        guard window.isVisible, let screen = currentScreen() else { return }
        let full = screen.frame
        let visible = screen.visibleFrame
        let bottomInset = bottomPanelInset(for: full)
        applyRootInsets(windowFrame: window.frame, screenFrame: full)

        let windowHeight = currentPanelHeight() + bottomInset
        let target = NSRect(
            x: full.minX,
            y: visible.minY,
            width: full.width,
            height: windowHeight
        )
        if target == window.frame { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.90, 0.30, 1.00)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(target, display: true)
            rootView.animator().frame = rootFrame(windowFrame: target, screenFrame: full)
        }
    }

    // MARK: - Key handling

    private func handleKey(_ event: NSEvent) -> Bool {
        if handlePanelShortcut(event) {
            return true
        }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isEditingSearch = window.firstResponder === searchField.currentEditor()
        let noMods = mods.isEmpty

        if noMods,
           let characters = event.characters,
           characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           !CharacterSet.controlCharacters.contains(scalar) {
            if isEditingSearch {
                return false
            }
            appendSearchCharacter(characters.lowercased())
            return true
        }

        return false
    }

    private func handlePanelShortcut(_ event: NSEvent) -> Bool {
        if let picker = formatPicker {
            if picker.handleKey(event) {
                return true
            }
            return false
        }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        updateShortcutHints(for: event.modifierFlags)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let isEditingSearch = window.firstResponder === searchField.currentEditor()

        if event.keyCode == 53 {
            hideAnimated()
            return true
        }

        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let cmdOnly = mods == .command
        let shiftOnly = mods == .shift
        let cmdShift = mods == [.command, .shift]
        let noMods = mods.isEmpty

        if isReturn {
            if shiftOnly || cmdShift {
                pasteSelected(transform: .plain)
                return true
            }
            pasteSelected(transform: .original)
            return true
        }

        if event.keyCode == 48 && noMods {
            completeSearchToken()
            return true
        }

        if cmdOnly && key == "c" {
            copySelected(transform: .original)
            return true
        }

        if cmdOnly && key == "f" {
            focusSearch()
            return true
        }

        if cmdOnly && key == "," {
            openSettings()
            return true
        }

        if cmdOnly && key == "t" {
            togglePause()
            return true
        }

        if cmdOnly && event.keyCode == 123 {
            cycleBoard(by: -1)
            return true
        }
        if cmdOnly && event.keyCode == 124 {
            cycleBoard(by: 1)
            return true
        }

        if cmdOnly && key == "[" {
            cycleBoard(by: -1)
            return true
        }
        if cmdOnly && key == "]" {
            cycleBoard(by: 1)
            return true
        }

        if cmdShift && key == "n" {
            promptCreatePinboard()
            return true
        }

        if (cmdOnly || cmdShift), let digit = Int(key), digit >= 1, digit <= 9 {
            quickPaste(index: digit - 1, transform: cmdShift ? .plain : .original)
            return true
        }

        if event.keyCode == 123 || (!isEditingSearch && noMods && key == "h") {
            moveSelection(by: -1)
            return true
        }
        if event.keyCode == 124 || (!isEditingSearch && noMods && key == "l") {
            moveSelection(by: 1)
            return true
        }

        if !isEditingSearch && (event.keyCode == 51 || event.keyCode == 117) {
            deleteSelected()
            return true
        }

        if !isEditingSearch && noMods && key == "/" {
            focusSearch()
            return true
        }

        if !isEditingSearch && noMods && key == " " {
            togglePinned()
            return true
        }

        return false
    }

    // MARK: - Selection

    private func moveSelection(by delta: Int) {
        guard !visibleItems.isEmpty else { return }
        let currentIndex = visibleItems.firstIndex { $0.id == selectedItemID } ?? 0
        let nextIndex = max(0, min(visibleItems.count - 1, currentIndex + delta))
        selectItem(visibleItems[nextIndex].id)
    }

    private func selectItem(_ id: UUID) {
        if let index = visibleItems.firstIndex(where: { $0.id == id }),
           index >= renderedCardCount {
            renderedCardCount = min(visibleItems.count, index + 1)
            appendCards(upTo: renderedCardCount)
            lastRenderedCardSignature = cardRenderSignature()
        }
        selectedItemID = id
        for case let card as ClipCardView in cardStack.arrangedSubviews {
            card.isSelected = card.itemID == id
        }
        scrollSelectedCardIntoView()
    }

    private func scrollSelectedCardIntoView() {
        guard let selectedItemID,
              let card = cardStack.arrangedSubviews.first(where: { ($0 as? ClipCardView)?.itemID == selectedItemID }) else {
            return
        }
        documentView.layoutSubtreeIfNeeded()
        scrollView.contentView.scrollToVisible(card.frame.insetBy(dx: -22, dy: 0))
    }

    private func scrollCardsToLeading() {
        documentView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private var selectedItem: ClipboardItem? {
        guard let selectedItemID else { return nil }
        return visibleItems.first { $0.id == selectedItemID }
    }

    private func focusSearch() {
        focusSearch(withPrefix: nil)
    }

    private func focusSearch(withPrefix prefix: String?) {
        setSearchInline(true)
        window.makeFirstResponder(searchField)
        if let prefix {
            searchField.stringValue = prefix
            reloadData()
        }
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
    }

    private func appendSearchCharacter(_ character: String) {
        guard character.isEmpty == false else { return }
        setSearchInline(true)
        window.makeFirstResponder(searchField)
        searchField.stringValue += character
        reloadData()
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
    }

    private func deleteSearchCharacter() {
        guard !searchField.stringValue.isEmpty else { return }
        setSearchInline(true)
        window.makeFirstResponder(searchField)
        searchField.stringValue.removeLast()
        reloadData()
        if searchField.stringValue.isEmpty {
            collapseEmptySearch()
        } else {
            searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
        }
    }

    private func completeSearchToken() {
        setSearchInline(true)
        window.makeFirstResponder(searchField)

        let value = searchField.stringValue
        let prefixEnd = value.endIndex
        let tokenStart = value[..<prefixEnd].lastIndex(where: { $0.isWhitespace }).map { value.index(after: $0) } ?? value.startIndex
        let currentToken = String(value[tokenStart..<prefixEnd])
        let lowerToken = currentToken.lowercased()

        let commandCandidates = [
            "pinned", "today",
            "type:text", "type:url", "type:json", "type:xml", "type:yaml",
            "type:sql", "type:markdown", "type:code", "type:image"
        ]
        let appCandidates = Set(store.items.map(\.sourceApp).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { appName -> String in
                appName.contains(" ") ? "app:\"\(appName)\"" : "app:\(appName)"
            }
        let candidates = commandCandidates + appCandidates
        guard let completion = candidates.first(where: { candidate in
            candidate.lowercased().hasPrefix(lowerToken)
        }) else {
            return
        }

        let needsTrailingSpace = !completion.hasSuffix(":")
        searchField.stringValue = String(value[..<tokenStart]) + completion + (needsTrailingSpace ? " " : "")
        reloadData()
        searchField.currentEditor()?.selectedRange = NSRange(location: searchField.stringValue.count, length: 0)
    }

    // MARK: - Actions

    private func copySelected(transform: ClipboardTransform) {
        guard let item = selectedItem else { return }
        do {
            try clipboardController.copy(item, transform: effectiveTransform(transform, for: item))
            clipboardController.playSoundEffectIfNeeded()
        } catch {
            NSLog("EasyPaste copy failed: \(error.localizedDescription)")
        }
    }

    private func pasteSelected(transform: ClipboardTransform) {
        guard let item = selectedItem else { return }
        do {
            stopDismissMonitoring()
            stopModifierMonitoring()
            updateShortcutHints(mode: .none)
            let finalTransform = effectiveTransform(transform, for: item)
            resetSearchStateForNextShow()
            window.orderOut(nil)
            NSApp.deactivate()
            if store.preferences.pasteDestination == .clipboard {
                try clipboardController.copy(item, transform: finalTransform)
            } else {
                try clipboardController.paste(item, transform: finalTransform, targetApplication: pasteTargetApplication())
            }
            clipboardController.playSoundEffectIfNeeded()
            try store.markUsed(id: item.id)
        } catch {
            NSLog("EasyPaste paste failed: \(error.localizedDescription)")
        }
    }

    private func effectiveTransform(_ requested: ClipboardTransform, for item: ClipboardItem) -> ClipboardTransform {
        guard item.kind != .image else { return .original }
        if store.preferences.alwaysPastePlainText || requested == .plain {
            return .plain
        }
        return requested
    }

    private func pasteTargetApplication() -> NSRunningApplication? {
        if let targetApplication, targetApplication.isTerminated == false {
            return targetApplication
        }
        return NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
        }
    }

    private func quickPaste(index: Int, transform: ClipboardTransform) {
        guard visibleItems.indices.contains(index) else { return }
        let item = visibleItems[index]
        selectItem(item.id)
        pasteSelected(transform: transform)
    }

    private func quickPastePlainText(index: Int) {
        guard visibleItems.indices.contains(index) else { return }
        let item = visibleItems[index]
        selectItem(item.id)
        guard item.kind != .image else { return }
        pasteSelected(transform: .plain)
    }

    @objc private func togglePinned() {
        guard let item = selectedItem else { return }
        do {
            try store.togglePinned(id: item.id)
            reloadData()
        } catch {
            NSLog("EasyPaste togglePinned failed: \(error.localizedDescription)")
        }
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem else { return }
        do {
            try store.delete(id: item.id)
            reloadData()
        } catch {
            NSLog("EasyPaste delete failed: \(error.localizedDescription)")
        }
    }

    @objc private func togglePause() {
        clipboardController.isPaused.toggle()
        updatePauseButton()
    }

    @objc private func clearUnpinned() {
        do {
            try store.clearUnpinned()
            reloadData()
        } catch {
            NSLog("EasyPaste clearUnpinned failed: \(error.localizedDescription)")
        }
    }

    @objc private func showMoreMenu() {
        let menu = NSMenu()

        let createItem = NSMenuItem(title: L10n.t("menu.newPinboard"), action: #selector(promptCreatePinboardAction), keyEquivalent: "n")
        createItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(createItem)
        menu.addItem(NSMenuItem.separator())

        let formatItem = NSMenuItem(title: L10n.t("menu.formatPaste"), action: #selector(presentFormatPickerAction), keyEquivalent: "\r")
        formatItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(formatItem)
        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: L10n.t("menu.clearUnpinned"), action: #selector(clearUnpinned), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("menu.clearLocalDataAndQuit"), action: #selector(clearLocalDataAndQuitAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }

        let location = NSPoint(x: moreButton.bounds.minX, y: moreButton.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: location, in: moreButton)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func clearLocalDataAndQuitAction() {
        onClearLocalData()
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    private func openSettings() {
        ignoreResignKeyUntil = Date().addingTimeInterval(1.0)
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                onChange: { [weak self] needsReload in
                    guard let self else { return }
                    self.applyTheme()
                    if needsReload {
                        self.reloadDataKeepingLeadingEdge()
                        self.onPreferencesChanged()
                    }
                },
                onClearLocalData: { [weak self] in
                    self?.onClearLocalData()
                }
            )
        }
        settingsWindowController?.show(relativeTo: window)
    }

    private static func isAnyScreenCaptured() -> Bool {
        let likelySharingBundleIDs: Set<String> = [
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.cisco.webexmeetingsapp",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.apple.ScreenSharing",
            "com.apple.QuickTimePlayerX",
            "com.obsproject.obs-studio"
        ]
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return likelySharingBundleIDs.contains(bundleID)
        }
    }

    // MARK: - Pinboards

    private func selectBoard(_ selector: BoardSelector) {
        do {
            try store.setActiveBoard(selector)
            reloadData()
        } catch {
            NSLog("EasyPaste setActiveBoard failed: \(error.localizedDescription)")
        }
    }

    private func cycleBoard(by delta: Int) {
        let boards = store.visibleBoards
        guard !boards.isEmpty else { return }
        let currentIndex = boards.firstIndex(of: store.activeBoardSelector) ?? 0
        let nextIndex = (currentIndex + delta + boards.count) % boards.count
        selectBoard(boards[nextIndex])
    }

    @objc private func promptCreatePinboardAction() {
        promptCreatePinboard()
    }

    private func promptCreatePinboard() {
        let alert = NSAlert()
        alert.messageText = L10n.t("pinboard.createTitle")
        alert.informativeText = L10n.t("pinboard.createHint")
        alert.addButton(withTitle: L10n.t("pinboard.create"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = L10n.t("pinboard.namePlaceholder")
        alert.accessoryView = input

        isPresentingPanelDialog = true
        defer {
            isPresentingPanelDialog = false
            ignoreResignKeyUntil = Date().addingTimeInterval(0.25)
        }

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                let board = try store.createBoard(name: input.stringValue)
                try store.setActiveBoard(.board(board.id))
                reloadData()
            } catch {
                NSLog("EasyPaste createBoard failed: \(error.localizedDescription)")
            }
        }
    }

    private func showBoardContextMenu(_ selector: BoardSelector, at event: NSEvent) {
        guard case .board(let id) = selector else { return }

        let menu = NSMenu()
        let renameItem = NSMenuItem(title: L10n.t("pinboard.rename"), action: #selector(renameCurrentBoardAction), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = id
        let deleteItem = NSMenuItem(title: L10n.t("pinboard.delete"), action: #selector(deleteCurrentBoardAction), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = id
        menu.addItem(renameItem)
        menu.addItem(deleteItem)
        guard let view = event.window?.contentView else { return }
        let location = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    @objc private func renameCurrentBoardAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("pinboard.renameTitle")
        alert.addButton(withTitle: L10n.t("pinboard.save"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = store.name(for: .board(id))
        alert.accessoryView = input

        isPresentingPanelDialog = true
        defer {
            isPresentingPanelDialog = false
            ignoreResignKeyUntil = Date().addingTimeInterval(0.25)
        }

        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try store.renameBoard(id: id, to: input.stringValue)
                reloadData()
            } catch {
                NSLog("EasyPaste renameBoard failed: \(error.localizedDescription)")
            }
        }
    }

    @objc private func deleteCurrentBoardAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        do {
            try store.deleteBoard(id: id)
            reloadData()
        } catch {
            NSLog("EasyPaste deleteBoard failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Item context menu

    private func showItemContextMenu(itemID: UUID, at event: NSEvent) {
        guard let item = store.items.first(where: { $0.id == itemID }) else { return }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: item.pinned ? L10n.t("menu.unpin") : L10n.t("menu.pin"), action: #selector(togglePinned), keyEquivalent: " "))
        menu.addItem(NSMenuItem(title: L10n.t("menu.copy"), action: #selector(copyOriginalAction), keyEquivalent: "c"))
        let copyPlain = NSMenuItem(title: L10n.t("menu.copyPlain"), action: #selector(copyPlainAction), keyEquivalent: "c")
        copyPlain.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyPlain)
        menu.addItem(NSMenuItem(title: L10n.t("menu.formatPaste"), action: #selector(presentFormatPickerAction), keyEquivalent: ""))
        let deleteItem = NSMenuItem(title: L10n.t("menu.delete"), action: #selector(deleteSelected), keyEquivalent: "\u{8}")
        deleteItem.keyEquivalentModifierMask = []
        menu.addItem(deleteItem)
        menu.addItem(NSMenuItem.separator())

        if !store.pinboards.isEmpty {
            let boardsMenu = NSMenu()
            for board in store.pinboards.sorted(by: { $0.sortIndex < $1.sortIndex }) {
                let mItem = NSMenuItem(title: board.name, action: #selector(toggleBoardForSelected(_:)), keyEquivalent: "")
                mItem.state = item.boardIDs.contains(board.id) ? .on : .off
                mItem.representedObject = board.id
                mItem.target = self
                boardsMenu.addItem(mItem)
            }
            let parent = NSMenuItem(title: L10n.t("menu.pinboards"), action: nil, keyEquivalent: "")
            parent.submenu = boardsMenu
            menu.addItem(parent)
        }

        menu.items.forEach { if $0.target == nil { $0.target = self } }
        guard let view = event.window?.contentView else { return }
        let location = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    @objc private func copyOriginalAction() {
        copySelected(transform: .original)
    }

    @objc private func copyPlainAction() {
        copySelected(transform: .plain)
    }

    @objc private func toggleBoardForSelected(_ sender: NSMenuItem) {
        guard let item = selectedItem,
              let boardID = sender.representedObject as? UUID else {
            return
        }
        do {
            try store.toggleBoard(itemID: item.id, boardID: boardID)
            reloadData()
        } catch {
            NSLog("EasyPaste toggleBoard failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Format picker

    @objc private func presentFormatPickerAction() {
        presentFormatPicker()
    }

    private func presentFormatPicker() {
        guard let item = selectedItem else { return }
        let candidates = FormatPickerView.candidateTransforms(for: item)
        guard !candidates.isEmpty else { return }

        dismissFormatPicker()

        let picker = FormatPickerView(transforms: candidates)
        picker.onCancel = { [weak self] in
            self?.dismissFormatPicker()
        }
        picker.onPick = { [weak self] transform in
            self?.dismissFormatPicker()
            self?.pasteSelected(transform: transform)
        }
        rootView.addSubview(picker)

        if let card = cardStack.arrangedSubviews.first(where: { ($0 as? ClipCardView)?.itemID == selectedItemID }) {
            let cardFrame = card.convert(card.bounds, to: rootView)
            let pickerHeight: CGFloat = 36 + CGFloat(candidates.count) * 28
            let originX = max(12, min(cardFrame.midX - 120, rootView.bounds.width - 252))
            let originY = max(12, min(cardFrame.maxY + 8, rootView.bounds.height - pickerHeight - 12))
            picker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picker.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: originX),
                picker.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -(rootView.bounds.height - originY - pickerHeight))
            ])
        } else {
            NSLayoutConstraint.activate([
                picker.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
                picker.centerYAnchor.constraint(equalTo: rootView.centerYAnchor)
            ])
        }

        formatPicker = picker

        // 弹出动画：alpha 0 + 轻微上滑 → 1 + 原位
        picker.wantsLayer = true
        picker.alphaValue = 0
        picker.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 6))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            picker.animator().alphaValue = 1
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        picker.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    private func dismissFormatPicker() {
        guard let picker = formatPicker else { return }
        formatPicker = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            picker.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                picker.removeFromSuperview()
            }
        })
    }
}

extension PanelController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class QuickPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    var modifierHandler: ((NSEvent.ModifierFlags) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        modifierHandler?(event.modifierFlags)
        super.flagsChanged(with: event)
    }
}

// MARK: - Toolbar symbol button

@MainActor
final class SymbolButton: NSView {
    var onClick: (() -> Void)?

    /// 表示按钮处于「激活」态（如搜索按钮当前正在展开搜索框）。
    var isActive = false {
        didSet { applyStyle() }
    }

    private let imageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { applyStyle() }
    }
    private var isPressed = false {
        didSet { applyStyle() }
    }

    init(symbol: String, tooltip: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = PanelLayout.current.toolbarButtonRadius
        toolTip = tooltip

        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = EasyPasteThemeStore.effectiveTheme.toolbarIcon
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        setSymbol(symbol)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PanelLayout.current.toolbarButtonSize),
            heightAnchor.constraint(equalToConstant: PanelLayout.current.toolbarButtonSize),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14)
        ])
        applyStyle()
    }

    func applyTheme(_ theme: EasyPasteTheme = EasyPasteThemeStore.effectiveTheme) {
        imageView.contentTintColor = theme.toolbarIcon
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSymbol(_ name: String) {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13 * PanelLayout.current.scale, weight: .semibold)
            imageView.image = image.withSymbolConfiguration(config)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressed = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    private func applyStyle() {
        let alpha: CGFloat
        if isPressed {
            alpha = 0.18
        } else if isActive {
            alpha = 0.16
        } else if isHovering {
            alpha = 0.10
        } else {
            alpha = 0.0
        }
        // 平滑过渡颜色，避免按钮颜色突变。
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let base = EasyPasteThemeStore.effectiveTheme.toolbarButtonBackgroundBase
        layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
        CATransaction.commit()
    }
}
