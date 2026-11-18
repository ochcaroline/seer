import AppKit
import SeerCore

/// Unified diff with vim motions. Draws only visible rows; review threads are shown as extra rows under their line.
final class DiffView: NSView {
    private enum DRow: Equatable {
        case diff(Int)
        /// One comment of `threads[thread]`, shown under diff row `anchor`.
        case comment(anchor: Int, thread: Int, comment: Int)
        /// Resolved / hidden-replies line of a thread.
        case info(anchor: Int, thread: Int)
        /// Space reserved for the inline comment editor, under diff row `anchor`.
        case editor(anchor: Int)
    }

    private(set) var diff = Diff()
    var highlights: [Int: [HLSpan]] = [:] { didSet { needsDisplay = true } }
    private(set) var threads: [ReviewThread] = []
    private var display: [DRow] = []
    private var displayIndex: [Int] = []
    private(set) var cursor = 0
    private let editor = CommentEditor()
    /// Row the inline editor opens under.
    private var editorSpot: DRow?
    var editorOpen: Bool { editor.isOpen }
    private var editorHeight: CGFloat { max(150, Theme.rowHeight * 6) }
    private var anchor: Int?
    private var keys = VimKeys()
    /// Query being typed after `/`, nil when not searching; `lastSearch` is what `n`/`N` repeat.
    private var searching: String?
    private var lastSearch = ""
    /// Files (by index) shown with soft wrap, toggled with `w`.
    private var wrapped = Set<Int>()
    /// Row tops plus total height when any file wraps; empty means every row is `Theme.rowHeight`.
    private var offsets: [CGFloat] = []
    private var layoutWidth: CGFloat = 0
    /// Threads (by index) showing only their first comment; resolved ones start collapsed.
    private var collapsed = Set<Int>()
    private var hasNotes = false
    /// Indent of comment text past the thread bar.
    private let noteIndent: CGFloat = 16

    var onComment: ((CommentTarget) -> Void)?
    /// Commands handled by the controller (submit, back, open); return false to beep.
    var onCommand: ((Command) -> Bool)?
    var onMode: ((String) -> Void)?
    /// One-shot capture of the next key, used for prompts like the submit choice.
    var prompt: ((Key) -> Void)?
    /// `c` inside a thread: thread id.
    var onReply: ((String) -> Void)?
    /// `i` on a comment: (thread id, comment id).
    var onEdit: ((String, String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Mouse selection, copied with `y`.
    private var selection: TextSelection? { didSet { needsDisplay = true } }

    private var gutterWidth: CGFloat { Theme.charWidth * 6 + 14 }

    lazy var scrollView: NSScrollView = {
        let s = NSScrollView()
        s.documentView = self
        s.hasVerticalScroller = true
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

    private func resize() {
        let w = scrollView.contentSize.width
        if !offsets.isEmpty && w != layoutWidth { layout(width: w) }
        let total = offsets.last ?? CGFloat(display.count) * Theme.rowHeight
        setFrameSize(NSSize(width: w, height: max(total, scrollView.contentSize.height)))
        positionEditor()
    }

    private func rowY(_ i: Int) -> CGFloat { offsets.isEmpty ? CGFloat(i) * Theme.rowHeight : offsets[i] }
    private func rowH(_ i: Int) -> CGFloat { offsets.isEmpty ? Theme.rowHeight : offsets[i + 1] - offsets[i] }

    /// Row containing `y`.
    private func row(atY y: CGFloat) -> Int {
        guard !offsets.isEmpty else { return Int(y / Theme.rowHeight) }
        var lo = 0, hi = display.count
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] <= y { lo = mid } else { hi = mid }
        }
        return lo
    }

    private func fileOf(_ i: Int) -> Int { diff.rows[diffRow(at: i)].file }

    private func threadAt(_ i: Int) -> Int? {
        guard display.indices.contains(i) else { return nil }
        switch display[i] {
        case .diff, .editor: return nil
        case .comment(_, let t, _), .info(_, let t): return t
        }
    }

    /// Comments always wrap; code rows wrap when their file is toggled with `w`. Headers stay one line.
    private func wraps(_ i: Int) -> Bool {
        guard case .diff(let r) = display[i] else { return true }
        guard !wrapped.isEmpty, wrapped.contains(diff.rows[r].file) else { return false }
        return diff.rows[r].commentable || diff.rows[r].kind == .meta
    }

    private func textX(_ i: Int) -> CGFloat { gutterWidth + 6 + (threadAt(i) != nil ? noteIndent : 0) }
    private func textWidth(_ i: Int) -> CGFloat { max(50, layoutWidth - textX(i) - 4) }

    private func layout(width: CGFloat) {
        layoutWidth = width
        guard !wrapped.isEmpty || hasNotes || editor.isOpen else { return offsets = [] }
        let rh = Theme.rowHeight
        var y: CGFloat = 0
        offsets = [CGFloat]()
        offsets.reserveCapacity(display.count + 1)
        for i in display.indices {
            offsets.append(y)
            if case .editor = display[i] { y += editorHeight; continue }
            guard wraps(i) else { y += rh; continue }
            let h = wrapText(rowContent(i).text).boundingRect(with: NSSize(width: textWidth(i), height: .greatestFiniteMagnitude),
                                                              options: [.usesLineFragmentOrigin]).height
            y += rh * CGFloat(max(1, Int(((h + Settings.lineSpacing) / rh).rounded())))
        }
        offsets.append(y)
    }

    private func wrapText(_ t: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: t)
        m.addAttribute(.paragraphStyle, value: Theme.wrapParagraph, range: NSRange(location: 0, length: m.length))
        return m
    }

    private func toggleWrap() {
        guard !display.isEmpty else { return }
        let f = fileOf(cursor)
        if wrapped.remove(f) == nil { wrapped.insert(f) }
        layout(width: scrollView.contentSize.width)
        resize()
        needsDisplay = true
        moveCursor(to: cursor)
    }

    func load(diff: Diff, threads: [ReviewThread]) {
        self.diff = diff
        self.threads = threads
        highlights = [:]
        anchor = nil
        wrapped = []
        collapsed = Set(threads.indices.filter { threads[$0].resolved })
        rebuild()
        moveCursor(to: 0, top: true)
    }

    /// Re-layout after a font/spacing change.
    func reload() {
        let keep = cursor
        rebuild()
        moveCursor(to: keep)
    }

    func addThread(_ t: ReviewThread) {
        threads.append(t)
        rebuild()
        moveCursor(to: threads.count - 1, comment: 0)
    }

    func appendComment(thread id: String, _ c: ReviewComment) {
        guard let t = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[t].comments.append(c)
        collapsed.remove(t)
        rebuild()
        moveCursor(to: t, comment: threads[t].comments.count - 1)
    }

    func updateComment(thread id: String, comment cid: String, body: String) {
        guard let t = threads.firstIndex(where: { $0.id == id }),
              let c = threads[t].comments.firstIndex(where: { $0.id == cid }) else { return }
        threads[t].comments[c].body = body
        rebuild()
        moveCursor(to: t, comment: c)
    }

    private func moveCursor(to thread: Int, comment: Int) {
        let i = display.firstIndex {
            if case .comment(_, thread, comment) = $0 { return true }
            return false
        } ?? display.firstIndex { if case .info(_, thread) = $0 { return true }; return false }
        if let i { moveCursor(to: i) }
    }

    private func rebuild() {
        var fileByPath: [String: Int] = [:]
        for (i, f) in diff.files.enumerated() where fileByPath[f.path] == nil { fileByPath[f.path] = i }
        var byRow: [Int: [Int]] = [:]
        for (ti, t) in threads.enumerated() {
            guard let fi = fileByPath[t.path] else { continue }
            let hit = diff.rowRange(file: fi).first {
                diff.rows[$0].commentable && (t.side == .left ? diff.rows[$0].old : diff.rows[$0].new) == t.line
            }
            if let hit { byRow[hit, default: []].append(ti) }
        }
        display = []
        displayIndex = []
        selection = nil
        display.reserveCapacity(diff.rows.count)
        func add(_ d: DRow, _ r: Int) {
            display.append(d)
            if editor.isOpen && d == editorSpot { display.append(.editor(anchor: r)) }
        }
        for r in diff.rows.indices {
            displayIndex.append(display.count)
            add(.diff(r), r)
            for t in byRow[r] ?? [] where !threads[t].comments.isEmpty {
                let shown = collapsed.contains(t) ? 1 : threads[t].comments.count
                for c in 0..<shown { add(.comment(anchor: r, thread: t, comment: c), r) }
                if collapsed.contains(t) || threads[t].resolved { add(.info(anchor: r, thread: t), r) }
            }
        }
        hasNotes = !byRow.isEmpty
        layout(width: scrollView.contentSize.width)
        resize()
        needsDisplay = true
    }

    private func positionEditor() {
        guard let i = display.firstIndex(where: { if case .editor = $0 { return true }; return false }) else { return editor.frame = .zero }
        editor.frame = NSRect(x: gutterWidth + 6, y: rowY(i) + 4, width: max(200, bounds.width - gutterWidth - 18), height: editorHeight - 8)
    }

    func applyEditorFont() { editor.applyFont() }

    /// Opens the editor under the row chosen by the last comment/reply/edit key; stays in the diff's scroll view.
    func openEditor(title: String, text: String, onSave: @escaping (String) -> Void) {
        if editor.superview == nil {
            addSubview(editor)
            editor.onClose = { [weak self] in
                guard let self else { return }
                var keep = cursor
                if case .editor = display[keep] { keep -= 1 }
                rebuild()
                moveCursor(to: keep)
                window?.makeFirstResponder(self)
            }
        }
        editor.begin(title: title, text: text, onSave: onSave)
        rebuild()
        if let i = display.firstIndex(where: { if case .editor = $0 { return true }; return false }) { moveCursor(to: i) }
    }

    private func diffRow(at i: Int) -> Int {
        guard display.indices.contains(i) else { return 0 }
        switch display[i] {
        case .diff(let r): return r
        case .comment(let a, _, _), .info(let a, _), .editor(let a): return a
        }
    }

    /// Context sent to Copilot: the visual selection, else the chosen file, else the whole PR.
    func aiContext(file selectedFile: Int? = nil) -> (label: String, text: String) {
        guard !diff.rows.isEmpty else { return ("none (no diff loaded)", "No diff is loaded.") }
        func body(_ rows: ClosedRange<Int>) -> String {
            rows.compactMap { r -> String? in
                guard diff.rows.indices.contains(r) else { return nil }
                let row = diff.rows[r]
                let sign = row.kind == .add ? "+" : row.kind == .del ? "-" : " "
                return row.new.map { "\($0): \(sign)\(row.text)" } ?? row.old.map { "\($0): \(sign)\(row.text)" } ?? row.text
            }.joined(separator: "\n")
        }
        func fileRows(_ f: Int) -> ClosedRange<Int> {
            let r = diff.rowRange(file: f)
            return r.lowerBound...max(r.lowerBound, r.upperBound - 1)
        }
        // shortcut: capped in UTF-8 bytes so the prompt stays under the 1 MB argv limit; chunk or use stdin if that bites
        let cap = 400_000
        func capped(_ label: String, _ text: String) -> (label: String, text: String) {
            text.utf8.count <= cap ? (label, text) : (label + ", truncated", String(decoding: text.utf8.prefix(cap), as: UTF8.self))
        }
        if selectedFile == nil, let anchor {
            let rows = min(diffRow(at: anchor), diffRow(at: cursor))...max(diffRow(at: anchor), diffRow(at: cursor))
            let file = fileOf(cursor)
            guard diff.files.indices.contains(file) else { return ("none", "No file is selected.") }
            return capped("\(rows.count) selected lines in \(diff.files[file].path)", "File: \(diff.files[file].path)\n\(body(rows))")
        }
        if let file = selectedFile {
            guard diff.files.indices.contains(file) else { return ("none", "No file is selected.") }
            return capped("file \(diff.files[file].path)", "File: \(diff.files[file].path)\n\(body(fileRows(file)))")
        }
        var text = ""
        var included = 0
        for (i, f) in diff.files.enumerated() where text.utf8.count < cap {
            text += "File: \(f.path)\n\(body(fileRows(i)))\n\n"
            included += 1
        }
        return capped("whole PR (\(included)/\(diff.files.count) files\(included < diff.files.count ? ", truncated" : ""))", text)
    }

    // MARK: Drawing

    override func draw(_ dirty: NSRect) {
        Theme.bg.setFill()
        dirty.fill()
        guard !display.isEmpty else { return }
        let first = max(0, row(atY: dirty.minY))
        let last = min(display.count, row(atY: dirty.maxY) + 1)
        guard first < last else { return }
        let rh = Theme.rowHeight
        let focused = window?.firstResponder === self
        let sel = anchor.map { min($0, cursor)...max($0, cursor) }
        let gw = gutterWidth
        for i in first..<last {
            let rect = NSRect(x: 0, y: rowY(i), width: bounds.width, height: rowH(i))
            let gutter = NSRect(x: 0, y: rect.minY, width: gw - 4, height: rect.height)
            let c = rowContent(i)
            if let bg = c.bg { bg.setFill(); rect.fill(using: .sourceOver) }
            (c.gutter ?? Theme.panel).setFill()
            gutter.fill(using: .sourceOver)
            if c.isFile {
                Theme.border.setFill()
                NSRect(x: 0, y: rect.minY, width: rect.width, height: 1).fill()
                NSRect(x: 0, y: rect.maxY - 1, width: rect.width, height: 1).fill()
            }
            if sel?.contains(i) == true { Theme.visual.setFill(); rect.fill(using: .sourceOver) }
            if i == cursor {
                (focused ? Theme.cursor : Theme.cursorUnfocused).setFill()
                rect.fill(using: .sourceOver)
                if focused {
                    Theme.accent.setFill()
                    NSRect(x: 0, y: rect.minY, width: 3, height: rect.height).fill()
                }
            }
            Theme.border.setFill()
            NSRect(x: gw - 4, y: rect.minY, width: 1, height: rect.height).fill()

            let numText: NSAttributedString
            if i == cursor {
                numText = NSAttributedString(string: c.number.map(String.init) ?? "", attributes: Theme.attrs(Theme.yellow, bold: true))
            } else {
                numText = NSAttributedString(string: String(abs(i - cursor)), attributes: Theme.attrs(Theme.dim))
            }
            let w = numText.size().width
            let ty = rect.minY + (rh - (Theme.font.ascender - Theme.font.descender)) / 2
            numText.draw(at: NSPoint(x: i == cursor ? 8 : gw - 12 - w, y: ty))
            if let bar = c.bar {
                bar.setFill()
                NSRect(x: gw + 6, y: rect.minY + 2, width: 3, height: rect.height - 4).fill()
            }
            if wraps(i) {
                let lines = Int((rect.height / rh).rounded())
                let mark = NSAttributedString(string: "↪", attributes: Theme.attrs(Theme.dim))
                for k in stride(from: 1, to: lines, by: 1) where c.bar == nil {
                    mark.draw(at: NSPoint(x: gw - 12 - mark.size().width, y: ty + CGFloat(k) * rh))
                }
            }
            let frame = textFrame(i, c)
            if let r = selection?.range(row: i, length: c.text.length) {
                Theme.visual.setFill()
                for sel in TextLayout(frame.text, width: frame.rect.width).rects(r) {
                    sel.offsetBy(dx: frame.rect.minX, dy: frame.rect.minY).fill(using: .sourceOver)
                }
            }
            frame.text.draw(with: frame.rect, options: [.usesLineFragmentOrigin])
        }
    }

    /// Row `i`'s text as drawn (wrapped rows get the wrapping style) and the rect it's drawn in.
    private func textFrame(_ i: Int, _ c: Content) -> (text: NSAttributedString, rect: NSRect) {
        let y = rowY(i) + (Theme.rowHeight - (Theme.font.ascender - Theme.font.descender)) / 2
        if wraps(i) { return (wrapText(c.text), NSRect(x: textX(i), y: y, width: textWidth(i), height: rowH(i))) }
        return (c.text, NSRect(x: gutterWidth + 6, y: y, width: bounds.width - gutterWidth - 6, height: Theme.rowHeight))
    }

    // MARK: Mouse selection

    private func textPos(at p: NSPoint) -> TextSelection.Pos? {
        guard !display.isEmpty else { return nil }
        let i = max(0, min(row(atY: p.y), display.count - 1))
        let f = textFrame(i, rowContent(i))
        let index = TextLayout(f.text, width: f.rect.width).index(at: NSPoint(x: p.x - f.rect.minX, y: p.y - f.rect.minY))
        return TextSelection.Pos(row: i, index: index)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let pos = textPos(at: convert(e.locationInWindow, from: nil)) else { return }
        selection = TextSelection(anchor: pos, head: pos)
        // Not moveCursor: scrolling under the pointer would shift the drag start.
        cursor = pos.row
        reportMode()
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

    private func copySelection() {
        guard let sel = selection else { return NSSound.beep() }
        let text = sel.text { r in
            if case .editor = display[r] { return nil }
            return rowContent(r).text.string
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        selection = nil
        onStatus?("Copied \(text.count) character\(text.count == 1 ? "" : "s")")
    }

    private struct Content {
        var bg: NSColor?
        var gutter: NSColor?
        var text: NSAttributedString
        var number: Int?
        var isFile = false
        /// Thread bar color for comment rows.
        var bar: NSColor?
    }

    private func rowContent(_ i: Int) -> Content {
        let r: Int
        switch display[i] {
        case .comment(_, let t, let ci):
            let c = threads[t].comments[ci]
            let s = NSMutableAttributedString().add(c.author, Theme.yellow, bold: true)
                .add(ci > 0 ? "  replied" : "", Theme.dim).add("\n")
                .add(c.body.replacingOccurrences(of: "\r", with: ""), Theme.text)
            return Content(bg: Theme.commentBg, text: s, bar: Theme.yellow)
        case .info(_, let t):
            let th = threads[t]
            let s = NSMutableAttributedString()
            if th.resolved { s.add("✓ Resolved" + (th.resolvedBy.map { " by @\($0)" } ?? ""), Theme.green, bold: true) }
            let replies = th.comments.count - 1
            if collapsed.contains(t) {
                s.add(th.resolved ? "  ·  " : "", Theme.dim)
                    .add(replies == 0 ? "no replies" : replies == 1 ? "1 reply" : "\(replies) replies", Theme.text)
                    .add("  ·  ⏎ expand", Theme.dim)
            } else {
                s.add("  ·  ⏎ collapse", Theme.dim)
            }
            return Content(bg: Theme.commentBg, text: s, bar: Theme.yellow)
        case .editor:
            return Content(bg: Theme.panel, text: NSAttributedString())
        case .diff(let d): r = d
        }
        let row = diff.rows[r]
        switch row.kind {
        case .file:
            let f = diff.files[row.file]
            let s = NSMutableAttributedString().add("▾ ", Theme.dim).add(row.text, Theme.text, bold: true)
                .add("   +\(f.adds)", Theme.green).add(" −\(f.dels) ", Theme.red)
            s.append(Theme.diffstat(f.adds, f.dels, ui: false))
            if wrapped.contains(row.file) { s.add("   wrap", Theme.accent) }
            return Content(bg: Theme.panel, gutter: Theme.panel, text: s, isFile: true)
        case .hunk:
            return Content(bg: Theme.hunkBg, gutter: Theme.hunkBg,
                           text: NSAttributedString(string: row.text, attributes: Theme.attrs(Theme.hunkFg)))
        case .meta:
            return Content(text: NSAttributedString(string: row.text, attributes: Theme.attrs(Theme.dim)))
        case .add, .del, .context:
            let sign = row.kind == .add ? "+ " : row.kind == .del ? "- " : "  "
            let s = NSMutableAttributedString(string: sign + row.text, attributes: Theme.attrs())
            s.addAttribute(.foregroundColor, value: row.kind == .add ? Theme.green : row.kind == .del ? Theme.red : Theme.dim,
                           range: NSRange(location: 0, length: 1))
            let len = s.length
            for span in highlights[r] ?? [] {
                guard let color = Theme.groups[span.group], span.start + 2 < len else { continue }
                s.addAttribute(.foregroundColor, value: color,
                               range: NSRange(location: span.start + 2, length: min(span.length, len - span.start - 2)))
            }
            switch row.kind {
            case .add: return Content(bg: Theme.addBg, gutter: Theme.addGutter, text: s, number: row.new)
            case .del: return Content(bg: Theme.delBg, gutter: Theme.delGutter, text: s, number: row.old)
            default: return Content(text: s, number: row.new)
            }
        }
    }

    // MARK: Movement

    func moveCursor(to i: Int, top: Bool = false) {
        guard !display.isEmpty else { return }
        cursor = max(0, min(i, display.count - 1))
        let rect = NSRect(x: 0, y: rowY(cursor), width: 1, height: rowH(cursor))
        if top {
            scroll(NSPoint(x: 0, y: rect.minY))
        } else {
            scrollToVisible(rect.insetBy(dx: 0, dy: -Theme.rowHeight * 3))
        }
        needsDisplay = true
        reportMode()
    }

    /// Scrolls the file's header to the top; with `firstLine`, puts the cursor on its first diff line.
    func scrollToFile(_ fi: Int, firstLine: Bool = false) {
        guard diff.files.indices.contains(fi) else { return }
        moveCursor(to: displayIndex[diff.files[fi].headerRow], top: true)
        if firstLine, let r = diff.rowRange(file: fi).first(where: { diff.rows[$0].commentable }) {
            moveCursor(to: displayIndex[r])
        }
    }

    private func reportMode() {
        onMode?((anchor != nil ? "-- VISUAL LINE --  " : "") + (searching.map { "/" + $0 } ?? keys.pendingText))
    }

    private func jumpFile(_ dir: Int) {
        let headers = diff.files.map { displayIndex[$0.headerRow] }
        let target = dir > 0 ? headers.first { $0 > cursor } : headers.last { $0 < cursor }
        if let target { moveCursor(to: target, top: true) } else { NSSound.beep() }
    }

    private func findNext(_ dir: Int) {
        guard !display.isEmpty else { return NSSound.beep() }
        let q = lastSearch.lowercased()
        let n = display.count
        for step in 1...max(n, 1) {
            let i = ((cursor + dir * step) % n + n) % n
            if rowContent(i).text.string.lowercased().contains(q) { return moveCursor(to: i) }
        }
        NSSound.beep()
    }

    private func typeSearch(_ k: Key) {
        switch k {
        case .enter:
            lastSearch = searching ?? ""
            searching = nil
            if !lastSearch.isEmpty { findNext(1) }
        case .escape: searching = nil
        case .char("\u{7f}"): searching = searching.map { String($0.dropLast()) }
        case .char(let c): searching?.append(c)
        default: break
        }
        reportMode()
    }

    override func keyDown(with e: NSEvent) {
        guard let k = key(from: e) else { return super.keyDown(with: e) }
        if let p = prompt {
            prompt = nil
            return p(k)
        }
        if searching != nil { return typeSearch(k) }
        guard let cmd = keys.feed(k) else { return reportMode() }
        let half = max(1, Int(visibleRect.height / Theme.rowHeight / 2))
        switch cmd {
        case .down(let n): moveCursor(to: cursor + n)
        case .up(let n): moveCursor(to: cursor - n)
        case .halfDown: moveCursor(to: cursor + half)
        case .halfUp: moveCursor(to: cursor - half)
        case .top: moveCursor(to: 0)
        case .bottom: moveCursor(to: display.count - 1)
        case .gotoLine(let n):
            guard !diff.rows.isEmpty, let r = diff.row(forLine: n, file: diff.rows[diffRow(at: cursor)].file) else {
                return NSSound.beep()
            }
            moveCursor(to: displayIndex[r])
        case .nextFile, .other("l"): jumpFile(1)
        case .prevFile, .other("h"): jumpFile(-1)
        case .visual:
            anchor = anchor == nil ? cursor : nil
            needsDisplay = true
        case .escape:
            anchor = nil
            selection = nil
            needsDisplay = true
        case .other("y"): copySelection()
        case .other("/"): searching = ""
        case .other("n") where !lastSearch.isEmpty: findNext(1)
        case .other("N") where !lastSearch.isEmpty: findNext(-1)
        case .other("w"): toggleWrap()
        case .enter:
            guard let t = threadAt(cursor) else { return NSSound.beep() }
            if collapsed.remove(t) == nil { collapsed.insert(t) }
            rebuild()
            moveCursor(to: t, comment: 0)
        case .other("e"):
            guard display.indices.contains(cursor), case .comment(_, let t, let c) = display[cursor] else { return NSSound.beep() }
            editorSpot = display[cursor]
            onEdit?(threads[t].id, threads[t].comments[c].id)
        case .comment where anchor == nil && threadAt(cursor) != nil:
            let t = threadAt(cursor)!
            editorSpot = display.last { if case .comment(_, t, _) = $0 { return true }; if case .info(_, t) = $0 { return true }; return false }
            onReply?(threads[t].id)
        case .comment:
            guard let t = diff.commentTarget(diffRow(at: anchor ?? cursor), diffRow(at: cursor)) else { return NSSound.beep() }
            editorSpot = display[max(anchor ?? cursor, cursor)]
            anchor = nil
            needsDisplay = true
            onComment?(t)
        default:
            if onCommand?(cmd) != true { NSSound.beep() }
        }
        reportMode()
    }
}
