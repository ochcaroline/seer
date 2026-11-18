import AppKit
import SeerCore

struct ListRow {
    let text: NSAttributedString
    var selectable = true
    var background: NSColor?
}

/// Keyboard-driven list (PR list, checks, files). Draws only visible rows.
final class ListView: NSView {
    var rows: [ListRow] = [] {
        didSet {
            if !(rows.indices.contains(cursor) && rows[cursor].selectable) { cursor = rows.firstIndex(where: \.selectable) ?? 0 }
            resize()
            needsDisplay = true
        }
    }
    private(set) var cursor = 0
    var onEnter: ((Int) -> Void)?
    var onCursor: ((Int) -> Void)?
    /// Commands the list doesn't handle itself; return false to beep.
    var onCommand: ((Command) -> Bool)?
    private var keys = VimKeys()

    lazy var scrollView: NSScrollView = {
        let s = NSScrollView()
        s.documentView = self
        s.hasVerticalScroller = true
        s.drawsBackground = true
        s.backgroundColor = Theme.bg
        s.autohidesScrollers = true
        s.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: s.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resize() }
        }
        return s
    }()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { needsDisplay = true; onFocus?(true); return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; onFocus?(false); return true }

    /// Re-layout after a font/spacing change.
    func reload() {
        resize()
        needsDisplay = true
    }

    private func resize() {
        let w = scrollView.contentSize.width
        setFrameSize(NSSize(width: w, height: max(CGFloat(rows.count) * Theme.uiRowHeight, scrollView.contentSize.height)))
    }


    override func draw(_ dirty: NSRect) {
        Theme.bg.setFill()
        dirty.fill()
        let first = max(0, Int(dirty.minY / Theme.uiRowHeight))
        let last = min(rows.count, Int(dirty.maxY / Theme.uiRowHeight) + 1)
        guard first < last else { return }
        let focused = window?.firstResponder === self
        for i in first..<last {
            let r = NSRect(x: 0, y: CGFloat(i) * Theme.uiRowHeight, width: bounds.width, height: Theme.uiRowHeight)
            if let bg = rows[i].background {
                bg.setFill()
                r.fill()
                Theme.border.setFill()
                NSRect(x: 0, y: r.maxY - 1, width: r.width, height: 1).fill()
            }
            if i == cursor && rows[i].selectable {
                (focused ? Theme.cursor : Theme.cursorUnfocused).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
                if focused {
                    Theme.accent.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 4, y: r.minY + 3, width: 3, height: r.height - 6), xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            let h = rows[i].text.size().height
            rows[i].text.draw(with: NSRect(x: 14, y: r.minY + (r.height - h) / 2, width: r.width - 22, height: h + 2),
                              options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    func setCursor(_ i: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(i, rows.count - 1))
        let rect = NSRect(x: 0, y: CGFloat(cursor) * Theme.uiRowHeight, width: 1, height: Theme.uiRowHeight)
        scrollToVisible(rect.insetBy(dx: 0, dy: -Theme.uiRowHeight * 2))
        needsDisplay = true
        onCursor?(cursor)
    }

    private func step(_ n: Int) {
        var i = cursor
        var left = abs(n)
        while left > 0 {
            var j = i + (n > 0 ? 1 : -1)
            while rows.indices.contains(j) && !rows[j].selectable { j += n > 0 ? 1 : -1 }
            guard rows.indices.contains(j) else { break }
            i = j
            left -= 1
        }
        setCursor(i)
    }

    override func keyDown(with e: NSEvent) {
        guard let k = key(from: e) else { return super.keyDown(with: e) }
        guard let cmd = keys.feed(k) else { return }
        let half = max(1, Int(visibleRect.height / Theme.uiRowHeight / 2))
        switch cmd {
        case .down(let n): step(n)
        case .up(let n): step(-n)
        case .halfDown: step(half)
        case .halfUp: step(-half)
        case .top: setCursor(rows.firstIndex(where: \.selectable) ?? 0)
        case .bottom: setCursor(rows.lastIndex(where: \.selectable) ?? 0)
        case .enter:
            if rows.indices.contains(cursor) && rows[cursor].selectable { onEnter?(cursor) }
        default:
            if onCommand?(cmd) != true, cmd != .escape { NSSound.beep() }
        }
    }
}
