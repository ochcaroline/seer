import AppKit
import SeerCore

private final class PromptView: BlockCursorTextView {
    var placeholder = ""

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        guard string.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: [.font: Theme.uiFont, .foregroundColor: Theme.dim])
    }
}

private final class DocView: NSView { override var isFlipped: Bool { true } }

/// Response rendered as numbered rows with a line cursor and `V` line selection, like the diff.
private final class ResponseView: NSView {
    private var lines: [NSAttributedString] = []
    private var tops: [CGFloat] = []
    private var heights: [CGFloat] = []
    private var total: CGFloat = 0
    private var laidWidth: CGFloat = 0
    private(set) var cursor = 0
    private var anchor: Int?
    var focused = false { didSet { needsDisplay = true } }
    var hasSelection: Bool { anchor != nil }
    /// Mouse selection; `y` copies it in preference to the line selection.
    private var selection: TextSelection? { didSet { needsDisplay = true } }
    var hasMouseSelection: Bool { selection != nil }
    var onMouseDown: (() -> Void)?
    private var gutter: CGFloat { Theme.charWidth * 4 + 10 }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: total) }

    func set(_ text: NSAttributedString) {
        lines = []
        var start = 0
        let ns = text.string as NSString
        while start <= ns.length {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            let end = r.location == NSNotFound ? ns.length : r.location
            lines.append(text.attributedSubstring(from: NSRange(location: start, length: end - start)))
            start = end + 1
        }
        if text.length == 0 { lines = [] }
        cursor = 0
        anchor = nil
        selection = nil
        relayout()
    }

    private func relayout() {
        laidWidth = bounds.width
        let w = max(50, laidWidth - gutter - 10)
        tops = []
        heights = []
        var y: CGFloat = 0
        for l in lines {
            let h = l.length == 0 ? 0 : l.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
            let rh = max(Theme.uiRowHeight, ceil(h) + 4)
            tops.append(y)
            heights.append(rh)
            y += rh
        }
        total = y
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - laidWidth) > 0.5 { relayout() }
    }

    private func reveal() {
        guard lines.indices.contains(cursor) else { return }
        scrollToVisible(NSRect(x: 0, y: tops[cursor], width: bounds.width, height: heights[cursor]).insetBy(dx: 0, dy: -Theme.uiRowHeight))
        needsDisplay = true
    }

    func move(to i: Int) {
        guard !lines.isEmpty else { return }
        cursor = min(max(i, 0), lines.count - 1)
        reveal()
    }

    func toggleVisual() {
        guard !lines.isEmpty else { return }
        anchor = anchor == nil ? cursor : nil
        needsDisplay = true
    }

    func clearSelection() {
        anchor = nil
        selection = nil
    }

    /// Copies the mouse selection, else the selected lines (or the cursor line); returns a status message.
    func copySelection() -> String? {
        if let sel = selection {
            let text = sel.text { lines[$0].string }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            selection = nil
            return "Copied \(text.count) character\(text.count == 1 ? "" : "s")"
        }
        guard lines.indices.contains(cursor) else { return nil }
        let range = min(anchor ?? cursor, cursor)...max(anchor ?? cursor, cursor)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(range.map { lines[$0].string }.joined(separator: "\n"), forType: .string)
        anchor = nil
        needsDisplay = true
        return "Copied \(range.count) line\(range.count == 1 ? "" : "s")"
    }

    private func textRect(_ i: Int) -> NSRect {
        NSRect(x: gutter + 4, y: tops[i] + 2, width: bounds.width - gutter - 10, height: heights[i])
    }

    private func textPos(at p: NSPoint) -> TextSelection.Pos? {
        guard !lines.isEmpty else { return nil }
        let i = tops.lastIndex { $0 <= p.y } ?? 0
        let r = textRect(i)
        let index = TextLayout(lines[i], width: r.width).index(at: NSPoint(x: p.x - r.minX, y: p.y - r.minY))
        return TextSelection.Pos(row: i, index: index)
    }

    override func mouseDown(with e: NSEvent) {
        onMouseDown?()
        guard let pos = textPos(at: convert(e.locationInWindow, from: nil)) else { return }
        selection = TextSelection(anchor: pos, head: pos)
        cursor = pos.row
    }

    override func mouseDragged(with e: NSEvent) {
        autoscroll(with: e)
        guard var sel = selection, let pos = textPos(at: convert(e.locationInWindow, from: nil)) else { return }
        sel.head = pos
        selection = sel
    }

    override func mouseUp(with _: NSEvent) {
        if selection?.isEmpty == true { selection = nil }
    }

    override func draw(_ dirty: NSRect) {
        let sel = anchor.map { min($0, cursor)...max($0, cursor) }
        for i in lines.indices where tops[i] + heights[i] >= dirty.minY && tops[i] <= dirty.maxY {
            let row = NSRect(x: 0, y: tops[i], width: bounds.width, height: heights[i])
            if let sel, sel.contains(i) { Theme.accent.withAlphaComponent(0.3).setFill(); row.fill() }
            else if focused && i == cursor { Theme.raised.setFill(); row.fill() }
            let num = NSAttributedString(string: "\(i + 1)", attributes: [.font: Theme.uiFont, .foregroundColor: Theme.dim])
            num.draw(at: NSPoint(x: gutter - 6 - num.size().width, y: row.minY + 2))
            let text = textRect(i)
            if let r = selection?.range(row: i, length: lines[i].length) {
                Theme.visual.setFill()
                for rect in TextLayout(lines[i], width: text.width).rects(r) {
                    rect.offsetBy(dx: text.minX, dy: text.minY).fill(using: .sourceOver)
                }
            }
            lines[i].draw(with: text, options: [.usesLineFragmentOrigin])
        }
    }
}

/// Vim-style pane: normal mode moves a line cursor (j/k, Ctrl-d/u, V/y to copy), `i` types a prompt right under the response, Esc returns to normal mode.
/// Enter sends, Shift+Enter adds a line (up to `maxLines` visible, then scrolls).
final class AIDrawerView: NSView, NSTextViewDelegate {
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onCancel: (() -> Void)?
    private let response = ResponseView()
    var onStatus: ((String) -> Void)?
    var onModeChange: (() -> Void)?
    var isVisual: Bool { response.hasSelection }
    private let scroll = NSScrollView()
    private let input = PromptView()
    private let inputScroll = NSScrollView()
    private var inputBoxHeight: NSLayoutConstraint?
    private let maxLines = 10
    private let header = PaneHeader()
    private let contextLabel = NSTextField(labelWithString: "")
    private let inputBox = NSView()
    private let leftBorder = NSView()
    private let separator = NSView()
    private let modelLabel = NSTextField(labelWithString: "")
    var isBusy = false {
        didSet {
            input.placeholder = isBusy ? "Copilot is thinking…  (Esc to cancel)" : Self.idlePlaceholder
            inputBox.alphaValue = isBusy ? 0.5 : 1
            input.needsDisplay = true
        }
    }
    private static let idlePlaceholder = "Ask Copilot about this PR…  (Shift+Enter for a new line)"
    var inputIsEmpty: Bool { input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor

        updateTitle()

        contextLabel.lineBreakMode = .byTruncatingMiddle
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.border.cgColor
        modelLabel.lineBreakMode = .byTruncatingTail

        response.onMouseDown = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        input.delegate = self
        input.font = Theme.uiFont
        input.textColor = Theme.text
        input.insertionPointColor = Theme.text
        input.drawsBackground = false
        input.isRichText = false
        input.allowsUndo = true
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.textContainerInset = NSSize(width: 0, height: 0)
        input.isVerticallyResizable = true
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.placeholder = Self.idlePlaceholder
        inputScroll.documentView = input
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.scrollerStyle = .overlay

        leftBorder.wantsLayer = true
        leftBorder.layer?.backgroundColor = Theme.border.cgColor

        inputBox.addSubview(inputScroll)
        let doc = DocView()
        let stack = NSStackView(views: [response, modelLabel, separator, inputBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setHuggingPriority(.required, for: .vertical)
        response.setContentHuggingPriority(.required, for: .vertical)
        response.setContentCompressionResistancePriority(.required, for: .vertical)
        for v in [response, modelLabel, separator, inputBox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
        scroll.documentView = doc
        doc.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, contextLabel, scroll, leftBorder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            contextLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            inputScroll.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor),
            inputScroll.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor),
            inputScroll.topAnchor.constraint(equalTo: inputBox.topAnchor),
            inputScroll.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor),
            leftBorder.topAnchor.constraint(equalTo: topAnchor),
            leftBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftBorder.widthAnchor.constraint(equalToConstant: 1),
        ])
        let h = inputBox.heightAnchor.constraint(equalToConstant: 0)
        inputBoxHeight = h
        h.isActive = true
        fitInput()
    }

    required init?(coder: NSCoder) { fatalError() }

    private var spaceSeq = ""

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { header.focused = true; response.focused = true; return true }
    override func resignFirstResponder() -> Bool { header.focused = false; response.focused = false; return true }

    override func keyDown(with e: NSEvent) {
        guard let k = key(from: e) else { return super.keyDown(with: e) }
        let half = max(1, Int(scroll.contentSize.height / Theme.uiRowHeight / 2))
        let seq = spaceSeq
        spaceSeq = ""
        switch k {
        case .char(" "): spaceSeq = " "
        case .char("a") where seq == " ": spaceSeq = " a"
        case .char("i") where seq == " a": onClose?()
        case .char("i"):
            window?.makeFirstResponder(input)
            header.focused = true
            response.focused = false
            inputBox.scrollToVisible(inputBox.bounds)
        case .char("j"): response.move(to: response.cursor + 1)
        case .char("k"): response.move(to: response.cursor - 1)
        case .ctrl("d"): response.move(to: response.cursor + half)
        case .ctrl("u"): response.move(to: response.cursor - half)
        case .char("g"): response.move(to: 0)
        case .char("G"): response.move(to: .max / 2)
        case .char("V"): response.toggleVisual(); onModeChange?()
        case .char("y"):
            if let msg = response.copySelection() { onStatus?(msg) }
            onModeChange?()
        case .char("q"): onClose?()
        case .escape:
            if response.hasSelection || response.hasMouseSelection { response.clearSelection(); onModeChange?() } else { onCancel?() }
        default: NSSound.beep()
        }
    }

    func setContext(_ label: String) {
        contextLabel.attributedStringValue = NSMutableAttributedString().ui("Context: ", Theme.dim).ui(label, Theme.text)
    }

    private func updateTitle() {
        modelLabel.attributedStringValue = NSMutableAttributedString().ui("✦ ", Theme.accent).ui(Settings.copilotModel, Theme.dim)
        header.title = NSMutableAttributedString().ui("✦ Copilot", Theme.text, bold: true)
            .ui("  \(Settings.copilotModel)", Theme.accent).ui("   i type · q close", Theme.dim)
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
            if isBusy { onCancel?() } else { window?.makeFirstResponder(self) }
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            submit()
        default:
            return false
        }
        return true
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool { !isBusy }

    func textDidChange(_ notification: Notification) { fitInput() }

    private func fitInput() {
        guard let lm = input.layoutManager, let tc = input.textContainer else { return }
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: Theme.uiFont)
        let lines = min(max(round(lm.usedRect(for: tc).height / line), 1), CGFloat(maxLines))
        inputBoxHeight?.constant = lines * line
        input.needsDisplay = true
    }

    private func submit() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        onSubmit?(text)
        clearInput()
    }

    func begin() {
        updateTitle()
        clearInput()
        response.set(NSAttributedString())
    }

    func show(_ text: String) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        let status = text == "Thinking…" || text == "Cancelled."
        let size = status ? Settings.uiFontSize : Settings.uiFontSize + 1
        let color = status ? Theme.dim : Theme.text
        let src = (status ? nil : try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in src.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular) : NSFont.systemFont(ofSize: size)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
            if let url = run.link { attrs[.link] = url }
            if intent.contains(.code) { attrs[.backgroundColor] = Theme.bg }
            out.append(NSAttributedString(string: String(src.characters[run.range]), attributes: attrs))
        }
        response.set(out)
        let clip = scroll.contentView
        let toBottom = { [self] in
            layoutSubtreeIfNeeded()
            let y = status ? 0 : max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        toBottom()
        DispatchQueue.main.async(execute: toBottom)
    }

    func clearInput() {
        input.string = ""
        fitInput()
    }
}
