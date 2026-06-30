import AppKit

/// 一个手工拼装的搜索输入框：
/// - 圆角玻璃感外观
/// - 左侧固定一颗放大镜 SF Symbol
/// - 内嵌 NSTextField，避免 NSSearchField + isBezeled=false 时文本与 cell 边距错位
/// - 失焦回调，用于"无内容时收起搜索栏"
@MainActor
final class GlassSearchField: NSView, NSTextFieldDelegate {
    /// 文本变化（每次 keystroke 都会回调）
    var onTextChange: ((String) -> Void)?
    /// Return 提交 或 失去焦点（任一都会触发，PanelController 用来在空文本时收起搜索栏）
    var onCommitOrCancel: (() -> Void)?
    /// 搜索框持有焦点时，普通左右方向键仍交给面板切换卡片。
    var onHorizontalNavigation: ((Int) -> Void)?
    var ignoresMouseEvents = false

    var stringValue: String {
        get { textField.stringValue }
        set {
            textField.stringValue = newValue
            updateClearButton()
        }
    }

    var placeholder: String = "" {
        didSet { applyPlaceholder() }
    }

    private let icon = NSImageView()
    private let textField = NSTextField()
    private let clearButton = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = EasyPasteThemeStore.effectiveTheme.searchBorder.cgColor
        layer?.backgroundColor = EasyPasteThemeStore.effectiveTheme.searchBackground.cgColor
        // 不裁剪 — 否则聚焦时的 outer halo（box-shadow 风格）会被裁掉。
        // 内部子视图都在圆角矩形里，不会溢出。
        layer?.masksToBounds = false

        // 放大镜 icon
        icon.image = EasyPasteIcon.symbol(
            named: "magnifyingglass",
            fallbacks: ["circle"],
            accessibilityDescription: "搜索",
            pointSize: 12,
            weight: .medium
        )
        icon.contentTintColor = EasyPasteThemeStore.effectiveTheme.secondaryText
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        // 文本框：去掉所有 bezel/背景，让它跟容器的圆角玻璃融为一体
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.textColor = EasyPasteThemeStore.effectiveTheme.searchText
        textField.font = .systemFont(ofSize: 12, weight: .regular)
        textField.delegate = self
        textField.cell?.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)

        // clear button（仅在有文本时显示）
        clearButton.isBordered = false
        clearButton.bezelStyle = .inline
        clearButton.title = ""
        clearButton.image = EasyPasteIcon.symbol(
            named: "xmark.circle.fill",
            fallbacks: ["xmark", "circle"],
            accessibilityDescription: "清除搜索",
            pointSize: 12,
            weight: .regular
        )
        clearButton.contentTintColor = EasyPasteThemeStore.effectiveTheme.secondaryText
        clearButton.target = self
        clearButton.action = #selector(handleClear)
        clearButton.isHidden = true
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16)
        ])

        applyPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 把 firstResponder 转给内嵌 NSTextField；外部 `window.makeFirstResponder(searchField)` 也能工作。
    override func becomeFirstResponder() -> Bool {
        focusTextInput()
    }

    /// 用户点击 view 任意位置都视为聚焦输入框
    override func mouseDown(with event: NSEvent) {
        focusTextInput()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        ignoresMouseEvents ? nil : super.hitTest(point)
    }

    /// 兼容外部读取 currentEditor（focusSearch 用到）
    func currentEditor() -> NSText? {
        textField.currentEditor()
    }

    @discardableResult
    func focusTextInput() -> Bool {
        guard let window else { return false }
        let focused = window.makeFirstResponder(textField)
        if focused {
            textField.currentEditor()?.selectedRange = NSRange(location: textField.stringValue.count, length: 0)
        }
        return focused
    }

    var isEditingText: Bool {
        window?.firstResponder === textField.currentEditor()
    }

    func applyTheme(_ theme: EasyPasteTheme = EasyPasteThemeStore.effectiveTheme) {
        layer?.borderColor = theme.searchBorder.cgColor
        layer?.backgroundColor = theme.searchBackground.cgColor
        icon.contentTintColor = theme.secondaryText
        textField.textColor = theme.searchText
        clearButton.contentTintColor = theme.secondaryText
        applyPlaceholder()
    }

    /// 输入框真正持有焦点时高亮 — 用 controlAccentColor 的微弱 halo，跟参考图一致。
    private func updateFocusRing(focused: Bool) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if focused {
            layer.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
            layer.borderWidth = 1.2
            layer.shadowColor = NSColor.controlAccentColor.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 5
            layer.shadowOffset = .zero
        } else {
            layer.borderColor = EasyPasteThemeStore.effectiveTheme.searchBorder.cgColor
            layer.borderWidth = 0.5
            layer.shadowOpacity = 0
        }
        CATransaction.commit()
    }

    private func applyPlaceholder() {
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: EasyPasteThemeStore.effectiveTheme.searchPlaceholder,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular)
            ]
        )
    }

    private func updateClearButton() {
        clearButton.isHidden = textField.stringValue.isEmpty
    }

    @objc private func handleClear() {
        textField.stringValue = ""
        updateClearButton()
        onTextChange?("")
        // 清空后也通知 commit，以便外层可以收起搜索栏
        onCommitOrCancel?()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateClearButton()
        onTextChange?(textField.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        updateFocusRing(focused: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        updateFocusRing(focused: false)
        // 失焦：通知外层处理（PanelController 在文本为空时收起搜索栏）
        onCommitOrCancel?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return / Esc 都让 panel 接管（panel 的 keyHandler 会处理 ⌘⇧Return / Esc / 普通 Return）
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommitOrCancel?()
            return false  // 让事件继续冒泡
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Esc：清空 + 收起
            textField.stringValue = ""
            onTextChange?("")
            onCommitOrCancel?()
            return true
        }
        if commandSelector == #selector(NSResponder.moveLeft(_:)) {
            onHorizontalNavigation?(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveRight(_:)) {
            onHorizontalNavigation?(1)
            return true
        }
        return false
    }
}
