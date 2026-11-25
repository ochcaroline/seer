import AppKit
import SeerCore

private final class DescriptionTextView: NSTextView {
    var onClose: (() -> Void)?
    private var keys = VimKeys()

    override func keyDown(with e: NSEvent) {
        if e.modifierFlags.contains(.command) { return super.keyDown(with: e) }
        guard let k = key(from: e), let cmd = keys.feed(k) else { return }
        let page = enclosingScrollView?.contentSize.height ?? 0
        switch cmd {
        case .down(let n): scroll(by: CGFloat(n) * Theme.uiRowHeight)
        case .up(let n): scroll(by: -CGFloat(n) * Theme.uiRowHeight)
        case .halfDown: scroll(by: page / 2)
        case .halfUp: scroll(by: -page / 2)
        case .top: scroll(by: -.greatestFiniteMagnitude)
        case .bottom: scroll(by: .greatestFiniteMagnitude)
        case .escape, .back, .description: onClose?()
        default: break
        }
    }

    private func scroll(by dy: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, clip.bounds.minY + dy), maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Read-only overlay with the PR title and description, 80% of the window.
final class DescriptionView: NSView {
    var onClose: (() -> Void)? {
        get { text.onClose }
        set { text.onClose = newValue }
    }
    private let text = DescriptionTextView()
    private let scroll = NSScrollView()

    override var isFlipped: Bool { true }

    init(title: String, body: String) {
        super.init(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 16)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let s = NSMutableAttributedString().ui(title + "\n\n", Theme.accent, bold: true)
            .ui(body.isEmpty ? "No description provided." : body, body.isEmpty ? Theme.dim : Theme.text)
            .ui("\n\nj/k scroll · Ctrl-d/u half page · gg/G top/bottom · q or Esc close", Theme.dim)
        text.textStorage?.setAttributedString(s)

        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panel
        scroll.wantsLayer = true
        scroll.layer?.borderColor = Theme.border.cgColor
        scroll.layer?.borderWidth = 1
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.centerXAnchor.constraint(equalTo: centerXAnchor),
            scroll.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.8),
            scroll.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// View that should receive keys while the overlay is open.
    var focusTarget: NSView { text }

    override func draw(_ dirty: NSRect) {
        Theme.bg.withAlphaComponent(0.82).setFill()
        dirty.fill()
    }

    // Swallow clicks on the dimmed backdrop so they don't reach the views underneath.
    override func mouseDown(with event: NSEvent) {}
}
