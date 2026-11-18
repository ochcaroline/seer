import AppKit

private final class EditorTextView: BlockCursorTextView {
    var onCancel: (() -> Void)?
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool { onFocus?(true); return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { onFocus?(false); return super.resignFirstResponder() }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { return onCancel?() ?? () }
        super.keyDown(with: e)
    }
}

/// Inline panel under a diff row for writing a comment. Opens in normal mode: `i` types, Esc leaves typing, Enter sends, Esc cancels.
final class CommentEditor: NSView {
    private let label = NSTextField(labelWithString: "")
    private let textView = EditorTextView()
    private var onSave: ((String) -> Void)?
    private var title = ""
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor
        layer?.borderColor = Theme.border.cgColor
        layer?.borderWidth = 1
        isHidden = true

        label.textColor = Theme.accent
        applyFont()
        textView.textColor = Theme.text
        textView.backgroundColor = Theme.bg

        textView.insertionPointColor = Theme.text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onCancel = { [weak self] in self?.enterNormal() }
        textView.onFocus = { [weak self] focused in if focused { self?.setHint(insert: true) } }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderColor = Theme.border.cgColor
        scroll.layer?.borderWidth = 1

        for v in [label, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var isOpen: Bool { !isHidden }

    func applyFont() {
        label.font = Theme.uiBold
        textView.font = Theme.font
    }

    func begin(title: String, text: String = "", onSave: @escaping (String) -> Void) {
        self.title = title
        textView.string = text
        self.onSave = onSave
        isHidden = false
        enterNormal()
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { setHint(insert: false); return true }

    private func enterNormal() {
        window?.makeFirstResponder(self)
        setHint(insert: false)
    }

    private func setHint(insert: Bool) {
        label.stringValue = title + "   " + (insert ? "Esc normal mode" : "i insert · ⏎ send · Esc cancel")
    }

    override func keyDown(with e: NSEvent) {
        guard let k = key(from: e) else { return super.keyDown(with: e) }
        switch k {
        case .char("i"): window?.makeFirstResponder(textView)
        case .enter: save()
        case .escape: close()
        default: NSSound.beep()
        }
    }

    private func save() {
        let text = textView.string
        let cb = onSave
        close()
        cb?(text)
    }

    private func close() {
        isHidden = true
        onSave = nil
        onClose?()
    }
}
