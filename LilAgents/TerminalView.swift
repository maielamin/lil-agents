import AppKit

// MARK: - Command Palette (B1)

fileprivate struct CommandPaletteItem: Equatable {
    let label: String
    let command: String
    let hint: String
}

// Character-specific commands
private let bruceCommands: [CommandPaletteItem] = [
    CommandPaletteItem(label: "wake", command: "/wake", hint: "Resume agent after sleep"),
    CommandPaletteItem(label: "debug", command: "/debug", hint: "Analyze and troubleshoot code"),
    CommandPaletteItem(label: "refactor", command: "/refactor", hint: "Improve code structure"),
    CommandPaletteItem(label: "clear", command: "/clear", hint: "Start a new chat"),
    CommandPaletteItem(label: "export", command: "/export", hint: "Export conversation to Markdown"),
]

private let jazzCommands: [CommandPaletteItem] = [
    CommandPaletteItem(label: "wake", command: "/wake", hint: "Resume agent after sleep"),
    CommandPaletteItem(label: "explore", command: "/explore", hint: "Explore ideas and possibilities"),
    CommandPaletteItem(label: "reflect", command: "/reflect", hint: "Think deeper about the topic"),
    CommandPaletteItem(label: "brainstorm", command: "/brainstorm", hint: "Generate creative ideas"),
    CommandPaletteItem(label: "clear", command: "/clear", hint: "Start a new chat"),
    CommandPaletteItem(label: "export", command: "/export", hint: "Export conversation to Markdown"),
]

// Select commands based on current character
private func getCommandPaletteCommands() -> [CommandPaletteItem] {
    let characterName = AgentProvider.current.displayName.lowercased()
    if characterName.contains("bruce") {
        return bruceCommands
    } else {
        return jazzCommands
    }
}


class CommandPaletteView: NSView {
    var onSelectCommand: ((String) -> Void)?
    private let commands: [CommandPaletteItem]
    private var rows: [NSButton] = []
    private var trackingAreasByIndex: [Int: NSTrackingArea] = [:]
    private var selectedIndex: Int = 0
    private static let rowHeight: CGFloat = 28

    static func preferredHeight(for commandCount: Int) -> CGFloat {
        CGFloat(commandCount) * rowHeight + 8
    }

    struct PaletteTheme {
        let bg: NSColor
        let border: NSColor
        let label: NSColor
        let hint: NSColor
    }

    fileprivate init(frame: NSRect, paletteTheme: PaletteTheme, commands: [CommandPaletteItem]) {
        self.commands = commands
        super.init(frame: frame)
        build(paletteTheme: paletteTheme)
    }

    required init?(coder: NSCoder) {
        self.commands = getCommandPaletteCommands()
        super.init(coder: coder)
        build(paletteTheme: PaletteTheme(
            bg: NSColor(white: 0.12, alpha: 0.96),
            border: NSColor.white.withAlphaComponent(0.12),
            label: NSColor.white.withAlphaComponent(0.9),
            hint: NSColor.white.withAlphaComponent(0.4)
        ))
    }

    private func build(paletteTheme: PaletteTheme) {
        wantsLayer = true
        layer?.backgroundColor = paletteTheme.bg.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = paletteTheme.border.cgColor

        let h = Self.rowHeight
        for (i, cmd) in commands.enumerated() {
            let y = frame.height - CGFloat(i + 1) * h - 4
            let btn = NSButton(frame: NSRect(x: 0, y: y, width: frame.width, height: h))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.title = ""
            btn.wantsLayer = true
            btn.layer?.backgroundColor = NSColor.clear.cgColor
            btn.autoresizingMask = [.width]
            btn.target = self
            btn.action = #selector(rowTapped(_:))
            btn.tag = i
            btn.setButtonType(.momentaryChange)

            let labelField = NSTextField(labelWithString: "/\(cmd.label)")
            labelField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            labelField.textColor = paletteTheme.label
            labelField.frame = NSRect(x: 12, y: (h - 14) / 2, width: 80, height: 14)
            labelField.isEnabled = false
            btn.addSubview(labelField)

            let hintField = NSTextField(labelWithString: cmd.hint)
            hintField.font = NSFont.systemFont(ofSize: 10)
            hintField.textColor = paletteTheme.hint
            hintField.frame = NSRect(x: 100, y: (h - 12) / 2, width: frame.width - 110, height: 12)
            hintField.autoresizingMask = [.width]
            hintField.isEnabled = false
            btn.addSubview(hintField)

            addSubview(btn)
            rows.append(btn)
        }

        applySelection(index: 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for (_, area) in trackingAreasByIndex {
            removeTrackingArea(area)
        }
        trackingAreasByIndex.removeAll()

        for (i, row) in rows.enumerated() {
            let area = NSTrackingArea(
                rect: row.frame,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: ["index": i]
            )
            addTrackingArea(area)
            trackingAreasByIndex[i] = area
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard
            let idx = event.trackingArea?.userInfo?["index"] as? Int,
            idx >= 0,
            idx < rows.count
        else { return }
        applySelection(index: idx)
    }

    func moveSelection(delta: Int) {
        guard !rows.isEmpty else { return }
        let next = (selectedIndex + delta + rows.count) % rows.count
        applySelection(index: next)
    }

    func activateSelection() {
        guard selectedIndex >= 0, selectedIndex < commands.count else { return }
        onSelectCommand?(commands[selectedIndex].command)
    }

    private func applySelection(index: Int) {
        selectedIndex = index
        for (i, row) in rows.enumerated() {
            let alpha: CGFloat = i == selectedIndex ? 1.0 : 0.0
            row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12 * alpha).cgColor
        }
    }

    @objc private func rowTapped(_ sender: NSButton) {
        let idx = sender.tag
        guard idx < commands.count else { return }
        applySelection(index: idx)
        onSelectCommand?(commands[idx].command)
    }
}

// MARK: - ChatInputTextView

class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPlaceholderChange: ((String?) -> Void)?
    var onDismissPalette: (() -> Void)?
    var onPaletteMove: ((Int) -> Bool)?
    var onActivatePalette: (() -> Bool)?
    var placeholderString: String? {
        didSet { onPlaceholderChange?(placeholderString) }
    }

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        // Escape (53) dismisses palette if open
        if key == 53 {
            onDismissPalette?()
            super.keyDown(with: event)
            return
        }
        if key == 125, onPaletteMove?(1) == true { return }   // Down arrow
        if key == 126, onPaletteMove?(-1) == true { return }  // Up arrow
        let wantsSubmit = (key == 36 || key == 76) && !event.modifierFlags.contains(.shift)
        if wantsSubmit {
            if onActivatePalette?() == true { return }
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

class PaddedTextFieldCell: NSTextFieldCell {
    private let inset = NSSize(width: 8, height: 2)
    var fieldBackgroundColor: NSColor?
    var fieldCornerRadius: CGFloat = 4

    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let bg = fieldBackgroundColor {
            let path = NSBezierPath(roundedRect: cellFrame, xRadius: fieldCornerRadius, yRadius: fieldCornerRadius)
            bg.setFill()
            path.fill()
        }
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let base = super.drawingRect(forBounds: rect)
        return base.insetBy(dx: inset.width, dy: inset.height)
    }

    private func configureEditor(_ textObj: NSText) {
        if let color = textColor {
            textObj.textColor = color
        }
        if let tv = textObj as? NSTextView {
            tv.insertionPointColor = textColor ?? .textColor
            tv.drawsBackground = false
            tv.backgroundColor = .clear
        }
        textObj.font = font
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        configureEditor(textObj)
        super.edit(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        configureEditor(textObj)
        super.select(withFrame: rect.insetBy(dx: inset.width, dy: inset.height), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

class TerminalView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView()
    let inputField = ChatInputTextView()
    private let inputScrollView = NSScrollView()
    private let inputPlaceholderLabel = NSTextField(labelWithString: "")
    private let inputMinHeight: CGFloat = 30
    private let inputMaxHeight: CGFloat = 52
    private var currentInputHeight: CGFloat = 30
    private let toastContainer = NSVisualEffectView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var toastHideWorkItem: DispatchWorkItem?
    var onSendMessage: ((String) -> Void)?
    var onInterceptMessage: ((String) -> Bool)?
    private var commandPalette: CommandPaletteView?
    private var activePaletteCommands: [CommandPaletteItem] = []

    private var currentAssistantText = ""
    private var isStreaming = false
    private let maxTranscriptCharacters = 120_000

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    var characterColor: NSColor?
    var themeOverride: PopoverTheme?
    var theme: PopoverTheme {
        var t = themeOverride ?? PopoverTheme.current
        if let color = characterColor { t = t.withCharacterColor(color) }
        t = t.withCustomFont()
        return t
    }

    // MARK: - Setup

    private func setupViews() {
        let t = theme
        let padding: CGFloat = 10

        scrollView.frame = NSRect(
            x: padding, y: currentInputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - currentInputHeight - padding - 10
        )
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        textView.frame = scrollView.contentView.bounds
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.textColor = t.textPrimary
        textView.font = t.font
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 2, height: 4)
        let defaultPara = NSMutableParagraphStyle()
        defaultPara.paragraphSpacing = 8
        textView.defaultParagraphStyle = defaultPara
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: t.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        scrollView.documentView = textView
        addSubview(scrollView)

        inputScrollView.frame = NSRect(
            x: padding, y: 6,
            width: frame.width - padding * 2,
            height: currentInputHeight
        )
        inputScrollView.autoresizingMask = [.width]
        inputScrollView.hasVerticalScroller = false
        inputScrollView.hasHorizontalScroller = false
        inputScrollView.borderType = .noBorder
        inputScrollView.drawsBackground = false

        inputField.frame = NSRect(x: 0, y: 0, width: inputScrollView.contentSize.width, height: currentInputHeight)
        inputField.minSize = NSSize(width: 0, height: inputMinHeight)
        inputField.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputField.isVerticallyResizable = true
        inputField.isHorizontallyResizable = false
        inputField.autoresizingMask = [.width]
        inputField.textContainerInset = NSSize(width: 8, height: 6)
        inputField.drawsBackground = false
        inputField.backgroundColor = .clear
        // Make cursor lighter and more subtle
        inputField.insertionPointColor = t.textPrimary.withAlphaComponent(0.3)
        inputField.font = t.font
        inputField.textColor = t.textPrimary
        inputField.delegate = self
        inputField.onSubmit = { [weak self] in
            self?.hideCommandPalette()
            self?.inputSubmitted()
        }
        inputField.onPlaceholderChange = { [weak self] text in
            self?.inputPlaceholderLabel.stringValue = text ?? ""
            self?.updateInputPlaceholderVisibility()
        }
        inputField.onDismissPalette = { [weak self] in
            self?.hideCommandPalette()
        }
        inputField.onPaletteMove = { [weak self] delta in
            guard let palette = self?.commandPalette else { return false }
            palette.moveSelection(delta: delta)
            return true
        }
        inputField.onActivatePalette = { [weak self] in
            guard let palette = self?.commandPalette else { return false }
            palette.activateSelection()
            return true
        }
        inputField.textContainer?.widthTracksTextView = true
        inputField.textContainer?.lineFragmentPadding = 0
        inputField.textContainer?.lineBreakMode = .byWordWrapping
        inputField.placeholderString = AgentProvider.current.inputPlaceholder
        inputScrollView.documentView = inputField
        addSubview(inputScrollView)

        inputPlaceholderLabel.font = t.font
        inputPlaceholderLabel.textColor = t.textDim
        inputPlaceholderLabel.frame = NSRect(x: padding + 8, y: 12, width: frame.width - padding * 2 - 16, height: 16)
        inputPlaceholderLabel.autoresizingMask = [.width]
        addSubview(inputPlaceholderLabel)
        updateInputPlaceholderVisibility()

        toastContainer.material = .hudWindow
        toastContainer.blendingMode = .withinWindow
        toastContainer.state = .active
        toastContainer.wantsLayer = true
        toastContainer.layer?.cornerRadius = 8
        toastContainer.layer?.masksToBounds = true
        toastContainer.alphaValue = 0
        toastContainer.isHidden = true
        toastContainer.autoresizingMask = [.width, .minYMargin]

        toastLabel.font = t.font
        toastLabel.textColor = t.textPrimary
        toastLabel.alignment = .left
        toastLabel.lineBreakMode = .byTruncatingTail
        toastLabel.frame = NSRect(x: 10, y: 5, width: 340, height: 16)
        toastLabel.autoresizingMask = [.width]
        toastContainer.addSubview(toastLabel)

        addSubview(toastContainer)
        layoutToast()
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 10
        inputScrollView.frame = NSRect(x: padding, y: 6, width: frame.width - padding * 2, height: currentInputHeight)
        inputPlaceholderLabel.frame = NSRect(x: padding + 8, y: 12, width: frame.width - padding * 2 - 16, height: 16)
        scrollView.frame = NSRect(
            x: padding,
            y: currentInputHeight + padding + 6,
            width: frame.width - padding * 2,
            height: frame.height - currentInputHeight - padding - 10
        )
        layoutToast()
    }

    private func layoutToast() {
        let width = min(max(frame.width - 24, 180), 360)
        let height: CGFloat = 26
        let x = (frame.width - width) / 2
        let y = frame.height - height - 8
        toastContainer.frame = NSRect(x: x, y: y, width: width, height: height)
        toastLabel.frame = NSRect(x: 10, y: 5, width: width - 20, height: 16)
    }

    // MARK: - Input

    @objc private func inputSubmitted() {
        if let palette = commandPalette {
            palette.activateSelection()
            return
        }
        let text = inputField.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.string = ""
        updateInputHeightIfNeeded()
        updateInputPlaceholderVisibility()

        appendUser(text)
        if onInterceptMessage?(text) == true {
            return
        }
        isStreaming = true
        currentAssistantText = ""
        onSendMessage?(text)
    }

    func textDidChange(_ notification: Notification) {
        updateInputHeightIfNeeded()
        updateInputPlaceholderVisibility()
        updateCommandPaletteVisibility()
    }

    private func updateCommandPaletteVisibility() {
        let filtered = filteredPaletteCommands(for: inputField.string)
        if filtered.isEmpty {
            hideCommandPalette()
        } else {
            showCommandPalette(commands: filtered)
        }
    }

    private func filteredPaletteCommands(for input: String) -> [CommandPaletteItem] {
        guard input.hasPrefix("/") else { return [] }
        let query = String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let commands = getCommandPaletteCommands()
        guard !query.isEmpty else { return commands }
        return commands.filter {
            $0.label.lowercased().contains(query)
                || $0.command.lowercased().contains(query)
                || $0.hint.lowercased().contains(query)
        }
    }

    private func showCommandPalette(commands: [CommandPaletteItem]) {
        if commandPalette != nil, activePaletteCommands == commands { return }
        hideCommandPalette()
        let t = theme
        let paletteHeight = CommandPaletteView.preferredHeight(for: commands.count)
        let paletteWidth = inputScrollView.frame.width
        let x = inputScrollView.frame.minX
        let y = inputScrollView.frame.maxY + 4
        // Derive palette colors from the active theme so it always matches the popover material
        let brightness = t.popoverBg.redComponent * 0.299 + t.popoverBg.greenComponent * 0.587 + t.popoverBg.blueComponent * 0.114
        let isDark = brightness < 0.5
        let paletteBg = isDark
            ? t.popoverBg.blended(withFraction: 0.15, of: .white) ?? t.popoverBg
            : t.popoverBg.blended(withFraction: 0.08, of: .black) ?? t.popoverBg
        let pt = CommandPaletteView.PaletteTheme(
            bg: paletteBg.withAlphaComponent(0.97),
            border: t.popoverBorder.withAlphaComponent(0.4),
            label: t.textPrimary,
            hint: t.textDim
        )
        let palette = CommandPaletteView(
            frame: NSRect(x: x, y: y, width: paletteWidth, height: paletteHeight),
            paletteTheme: pt,
            commands: commands
        )
        palette.alphaValue = 0
        palette.onSelectCommand = { [weak self] command in
            self?.inputField.string = command
            self?.hideCommandPalette()
            self?.inputField.string = ""
            self?.updateInputHeightIfNeeded()
            self?.updateInputPlaceholderVisibility()
            if let intercept = self?.onInterceptMessage, intercept(command) { return }
            self?.isStreaming = true
            self?.currentAssistantText = ""
            self?.appendUser(command)
            self?.onSendMessage?(command)
        }
        addSubview(palette)
        commandPalette = palette
        activePaletteCommands = commands

        let finalFrame = palette.frame
        palette.frame = finalFrame.offsetBy(dx: 0, dy: -6)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            palette.animator().alphaValue = 1
            palette.animator().frame = finalFrame
        }
    }

    private func hideCommandPalette() {
        commandPalette?.removeFromSuperview()
        commandPalette = nil
        activePaletteCommands = []
    }

    private func updateInputPlaceholderVisibility() {
        inputPlaceholderLabel.isHidden = !inputField.string.isEmpty || !inputField.isEditable
    }

    private func updateInputHeightIfNeeded() {
        guard let layout = inputField.layoutManager, let container = inputField.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height + (inputField.textContainerInset.height * 2)
        let clamped = max(inputMinHeight, min(inputMaxHeight, ceil(used)))
        inputScrollView.hasVerticalScroller = used > inputMaxHeight
        guard abs(clamped - currentInputHeight) > 0.5 else { return }
        currentInputHeight = clamped
        needsLayout = true
    }

    // MARK: - Append Methods

    private var messageSpacing: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = 8
        return p
    }

    private func ensureNewline() {
        if let storage = textView.textStorage, storage.length > 0 {
            if !storage.string.hasSuffix("\n") {
                storage.append(NSAttributedString(string: "\n"))
            }
        }
    }

    func appendUser(_ text: String) {
        let t = theme
        ensureNewline()
        let para = messageSpacing
        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(string: "> ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor, .paragraphStyle: para
        ]))
        attributed.append(NSAttributedString(string: "\(text)\n", attributes: [
            .font: t.fontBold, .foregroundColor: t.textPrimary, .paragraphStyle: para
        ]))
        textView.textStorage?.append(attributed)
        scrollToBottom()
    }

    func appendStreamingText(_ text: String) {
        var cleaned = text
        if currentAssistantText.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: "^\n+", with: "", options: .regularExpression)
        }
        currentAssistantText += cleaned
        if !cleaned.isEmpty {
            textView.textStorage?.append(renderMarkdown(cleaned))
            scrollToBottom()
        }
    }

    func endStreaming() {
        if isStreaming {
            isStreaming = false
        }
    }

    func appendError(_ text: String) {
        let t = theme
        textView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
            .font: t.font, .foregroundColor: t.errorColor
        ]))
        scrollToBottom()
    }

    func showToast(_ text: String) {
        toastHideWorkItem?.cancel()
        toastLabel.stringValue = text
        layoutToast()
        toastContainer.isHidden = false

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toastContainer.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                self.toastContainer.animator().alphaValue = 0
            }, completionHandler: {
                self.toastContainer.isHidden = true
            })
        }
        toastHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }

    func appendToolUse(toolName: String, summary: String) {
        let t = theme
        endStreaming()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "  \(toolName.uppercased()) ", attributes: [
            .font: t.fontBold, .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func appendToolResult(summary: String, isError: Bool) {
        let t = theme
        let color = isError ? t.errorColor : t.successColor
        let prefix = isError ? "  FAIL " : "  DONE "
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: prefix, attributes: [
            .font: t.fontBold, .foregroundColor: color
        ]))
        block.append(NSAttributedString(string: "\(summary.isEmpty ? "" : summary)\n", attributes: [
            .font: t.font, .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func showSignatureIntro(characterName: String) {
        let lower = characterName.lowercased()
        let line: String
        switch lower {
        case "bruce":
            line = "I am Bruce. Tell me what you want to build and I will help step by step."
        case "jazz":
            line = "I am Jazz. Tell me what is on your mind and we will figure it out together."
        default:
            line = "Hi, I am ready to help."
        }

        let t = theme
        ensureNewline()
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "HELLO ", attributes: [
            .font: t.fontBold,
            .foregroundColor: t.accentColor
        ]))
        block.append(NSAttributedString(string: "\(line)  Type / to see helpful commands.\n", attributes: [
            .font: t.font,
            .foregroundColor: t.textDim
        ]))
        textView.textStorage?.append(block)
        scrollToBottom()
    }

    func replayHistory(_ messages: [AgentMessage]) {
        let t = theme
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        for msg in messages {
            switch msg.role {
            case .user:
                appendUser(msg.text)
            case .assistant:
                textView.textStorage?.append(renderMarkdown(msg.text + "\n"))
            case .error:
                appendError(msg.text)
            case .toolUse:
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
            case .toolResult:
                let isErr = msg.text.hasPrefix("ERROR:")
                textView.textStorage?.append(NSAttributedString(string: "  \(msg.text)\n", attributes: [
                    .font: t.font, .foregroundColor: isErr ? t.errorColor : t.successColor
                ]))
            }
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        trimTranscriptIfNeeded()
        textView.scrollToEndOfDocument(nil)
    }

    private func trimTranscriptIfNeeded() {
        guard let storage = textView.textStorage else { return }
        let overflow = storage.length - maxTranscriptCharacters
        guard overflow > 0 else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: overflow))
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let t = theme
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLang = ""
        var codeLines: [String] = []

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let codeText = codeLines.joined(separator: "\n")
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
                    result.append(NSAttributedString(string: codeText + "\n", attributes: [
                        .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
                    ]))
                    inCodeBlock = false
                    codeLines = []
                } else {
                    inCodeBlock = true
                    codeBlockLang = String(line.dropFirst(3))
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            if line.hasPrefix("### ") {
                result.append(NSAttributedString(string: String(line.dropFirst(4)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("## ") {
                result.append(NSAttributedString(string: String(line.dropFirst(3)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 1, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("# ") {
                result.append(NSAttributedString(string: String(line.dropFirst(2)) + suffix, attributes: [
                    .font: NSFont.systemFont(ofSize: t.font.pointSize + 2, weight: .bold), .foregroundColor: t.accentColor
                ]))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let content = String(line.dropFirst(2))
                result.append(NSAttributedString(string: "  \u{2022} ", attributes: [
                    .font: t.font, .foregroundColor: t.accentColor
                ]))
                result.append(renderInlineMarkdown(content + suffix, theme: t))
            } else {
                result.append(renderInlineMarkdown(line + suffix, theme: t))
            }
        }

        if inCodeBlock && !codeLines.isEmpty {
            let codeText = codeLines.joined(separator: "\n")
            let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 1, weight: .regular)
            result.append(NSAttributedString(string: codeText + "\n", attributes: [
                .font: codeFont, .foregroundColor: t.textPrimary, .backgroundColor: t.inputBg
            ]))
        }

        return result
    }

    private func renderInlineMarkdown(_ text: String, theme t: PopoverTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            if text[i] == "`" {
                let afterTick = text.index(after: i)
                if afterTick < text.endIndex, let closeIdx = text[afterTick...].firstIndex(of: "`") {
                    let code = String(text[afterTick..<closeIdx])
                    let codeFont = NSFont.monospacedSystemFont(ofSize: t.font.pointSize - 0.5, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [
                        .font: codeFont, .foregroundColor: t.accentColor, .backgroundColor: t.inputBg
                    ]))
                    i = text.index(after: closeIdx)
                    continue
                }
            }
            if text[i] == "*",
               text.index(after: i) < text.endIndex, text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if start < text.endIndex, let range = text.range(of: "**", range: start..<text.endIndex) {
                    let bold = String(text[start..<range.lowerBound])
                    result.append(NSAttributedString(string: bold, attributes: [
                        .font: t.fontBold, .foregroundColor: t.textPrimary
                    ]))
                    i = range.upperBound
                    continue
                }
            }
            if text[i] == "[" {
                let afterBracket = text.index(after: i)
                if afterBracket < text.endIndex,
                   let closeBracket = text[afterBracket...].firstIndex(of: "]") {
                    let parenStart = text.index(after: closeBracket)
                    if parenStart < text.endIndex && text[parenStart] == "(" {
                        let afterParen = text.index(after: parenStart)
                        if afterParen < text.endIndex,
                           let closeParen = text[afterParen...].firstIndex(of: ")") {
                            let linkText = String(text[afterBracket..<closeBracket])
                            let urlStr = String(text[afterParen..<closeParen])
                            var attrs: [NSAttributedString.Key: Any] = [
                                .font: t.font,
                                .foregroundColor: t.accentColor,
                                .underlineStyle: NSUnderlineStyle.single.rawValue
                            ]
                            if let url = URL(string: urlStr) {
                                attrs[.link] = url
                                attrs[.cursor] = NSCursor.pointingHand
                            }
                            result.append(NSAttributedString(string: linkText, attributes: attrs))
                            i = text.index(after: closeParen)
                            continue
                        }
                    }
                }
            }
            if text[i] == "h" {
                let remaining = String(text[i...])
                if remaining.hasPrefix("https://") || remaining.hasPrefix("http://") {
                    var j = i
                    while j < text.endIndex && !text[j].isWhitespace && text[j] != ")" && text[j] != ">" {
                        j = text.index(after: j)
                    }
                    let urlStr = String(text[i..<j])
                    var attrs: [NSAttributedString.Key: Any] = [
                        .font: t.font,
                        .foregroundColor: t.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ]
                    if let url = URL(string: urlStr) {
                        attrs[.link] = url
                    }
                    result.append(NSAttributedString(string: urlStr, attributes: attrs))
                    i = j
                    continue
                }
            }
            result.append(NSAttributedString(string: String(text[i]), attributes: [
                .font: t.font, .foregroundColor: t.textPrimary
            ]))
            i = text.index(after: i)
        }
        return result
    }
}
