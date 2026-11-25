import AppKit

final class BodyTextView: BlockCursorTextView {
    var onEscape: (() -> Void)?

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onEscape?() } else { super.keyDown(with: e) }
    }
}

struct ChoiceConfig {
    struct Mode {
        let id: String
        let name: String
    }

    let title: String
    let modes: [Mode]
    /// j/k move the selection.
    let navigate: Bool
    let pickHint: String
    let idleHint: String
    let editHint: String
    /// Mode id → reason the text can't be edited in that mode.
    var locked: [String: String] = [:]

    static let submit = ChoiceConfig(
        title: "Submit review",
        modes: [.init(id: "APPROVE", name: "Approve"), .init(id: "REQUEST_CHANGES", name: "Request changes"),
                .init(id: "COMMENT", name: "Comment")],
        navigate: true, pickHint: "Pick a mode first: j or k",
        idleHint: "j/k mode · i edit comment (optional) · Enter submit · Esc discard",
        editHint: "Editing comment · Esc stop editing")

    static let close = ChoiceConfig(
        title: "Close pull request",
        modes: [.init(id: "CLOSE", name: "Close without merging")],
        navigate: false, pickHint: "",
        idleHint: "i edit comment (optional) · Enter close · Esc cancel",
        editHint: "Editing comment · Esc stop editing")

    static let merge = ChoiceConfig(
        title: "Merge pull request",
        modes: [.init(id: "MERGE", name: "Merge commit"), .init(id: "SQUASH", name: "Squash and merge"),
                .init(id: "REBASE", name: "Rebase and merge")],
        navigate: true, pickHint: "Pick a merge method first: j or k",
        idleHint: "j/k method · i edit message · Enter merge · Esc discard",
        editHint: "Editing commit message · Esc stop editing",
        locked: ["REBASE": "Rebase merges don't take a commit message"])
}

/// Pick-a-mode dialog with an editable text. Enter confirms, Esc leaves the text (or discards), i edits.
final class ChoiceModal: NSView {
    var onChoose: ((_ id: String, _ name: String, _ text: String) -> Void)?
    var onClose: (() -> Void)?
    private let config: ChoiceConfig
    private let titleLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let body = BodyTextView()
    /// Mode id → generated text; picking a mode replaces the text with its draft. Nil keeps the text across modes.
    private var drafts: [String: String]?
    private var mode: Int?
    private var editing = false

    override var acceptsFirstResponder: Bool { true }

    init(_ config: ChoiceConfig) {
        self.config = config
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.panel.cgColor
        panel.layer?.borderColor = Theme.border.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.cornerRadius = 10

        body.isRichText = false
        body.font = Theme.font
        body.textColor = Theme.text
        body.insertionPointColor = Theme.text
        body.drawsBackground = false
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false
        body.allowsUndo = true
        body.textContainerInset = NSSize(width: 6, height: 6)
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.onEscape = { [weak self] in self?.setEditing(false) }

        let scroll = NSScrollView()
        scroll.documentView = body
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = Theme.bg.cgColor
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.border.cgColor

        for v in [panel, titleLabel, modeLabel, hint, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(panel)
        [titleLabel, modeLabel, scroll, hint].forEach(panel.addSubview)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 600),
            panel.heightAnchor.constraint(equalToConstant: 380),
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            modeLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            modeLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            modeLabel.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: modeLabel.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),
            hint.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `mode` and `text` restore a previous attempt.
    func begin(drafts: [String: String]? = nil, mode id: String? = nil, text: String? = nil, note: String = "") {
        self.drafts = drafts
        mode = config.modes.firstIndex { $0.id == id }
        body.string = text ?? ""
        setEditing(false)
        if !note.isEmpty { hint.stringValue = note + hint.stringValue }
        window?.makeFirstResponder(self)
    }

    private func pick(_ i: Int) {
        guard i != mode else { return }
        mode = i
        if let drafts { body.string = drafts[config.modes[i].id] ?? "" }
        refresh()
    }

    private func setEditing(_ on: Bool) {
        editing = on
        refresh()
        window?.makeFirstResponder(on ? body : self)
    }

    private func warn(_ s: String) {
        hint.stringValue = s
        hint.textColor = Theme.red
    }

    private func refresh() {
        titleLabel.attributedStringValue = NSMutableAttributedString().ui(config.title, Theme.text, bold: true)
        let t = NSMutableAttributedString()
        for (i, m) in config.modes.enumerated() {
            let on = i == mode
            t.ui(on ? "● " : "○ ", on ? Theme.accent : Theme.dim)
            t.ui(m.name + (i < config.modes.count - 1 ? "\n" : ""),
                 on ? Theme.text : Theme.dim, bold: on)
        }
        modeLabel.attributedStringValue = t
        hint.font = Theme.uiFont
        hint.textColor = editing ? Theme.accent : Theme.dim
        hint.stringValue = editing ? config.editHint : config.idleHint
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { return onClose?() ?? () }
        if e.keyCode == 36 || e.keyCode == 76 {
            guard let mode else { return warn(config.pickHint) }
            let m = config.modes[mode]
            return onChoose?(m.id, m.name, body.string) ?? ()
        }
        guard let c = e.charactersIgnoringModifiers?.first else { return }
        if c == "i" {
            if drafts != nil, mode == nil { return warn(config.pickHint) }
            if let mode, let why = config.locked[config.modes[mode].id] { return warn(why) }
            return setEditing(true)
        }
        guard config.navigate else { return }
        if c == "j" { pick(min((mode ?? -1) + 1, config.modes.count - 1)) }
        if c == "k" { pick(max((mode ?? config.modes.count) - 1, 0)) }
    }
}
