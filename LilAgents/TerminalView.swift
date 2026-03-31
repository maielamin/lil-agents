import AppKit

class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPlaceholderChange: ((String?) -> Void)?
    var placeholderString: String? {
        didSet { onPlaceholderChange?(placeholderString) }
    }

    override func keyDown(with event: NSEvent) {
        let key = event.keyCode
        let wantsSubmit = (key == 36 || key == 76) && !event.modifierFlags.contains(.shift)
        if wantsSubmit {
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
        inputField.insertionPointColor = t.textPrimary
        inputField.font = t.font
        inputField.textColor = t.textPrimary
        inputField.delegate = self
        inputField.onSubmit = { [weak self] in
            self?.inputSubmitted()
        }
        inputField.onPlaceholderChange = { [weak self] text in
            self?.inputPlaceholderLabel.stringValue = text ?? ""
            self?.updateInputPlaceholderVisibility()
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
