import AppKit

final class HelpView: NSView {
    var onClose: (() -> Void)?

    private let lines: [(String, NSColor, Bool)] = [
        ("KEYBOARD HELP", Theme.accent, true),
        ("", Theme.text, false),
        ("NAVIGATION (lists and diff)", Theme.yellow, true),
        ("  j / k         move down / up (count prefix: 5j)", Theme.text, false),
        ("  Ctrl-d / u    half page down / up", Theme.text, false),
        ("  gg / G        first / last item", Theme.text, false),
        ("  {n}G          diff: go to line n of the current file", Theme.text, false),
        ("", Theme.text, false),
        ("GENERAL", Theme.yellow, true),
        ("  ?             show / hide this help", Theme.text, false),
        ("  Esc           clear visual selection, clear the list filter, close help", Theme.text, false),
        ("  q             back to the pull request list (from a PR)", Theme.text, false),
        ("  o             open in browser: PR, or the selected check", Theme.text, false),
        ("  r / R         PR list: refresh the selected PR / refresh all. PR: R reloads", Theme.text, false),
        ("  Space g h     copy a `gh pr checkout` command", Theme.text, false),
        ("  Space g t     open in a terminal: tmux session with the PR checked out", Theme.text, false),
        ("  ,             Settings (also Cmd-,)", Theme.text, false),
        ("", Theme.text, false),
        ("PULL REQUEST LIST", Theme.yellow, true),
        ("  Enter         open the selected pull request", Theme.text, false),
        ("  h / l         previous / next repository", Theme.text, false),
        ("  /             filter by repository or title (Enter keep, Esc clear)", Theme.text, false),
        ("", Theme.text, false),
        ("DIFF REVIEW", Theme.yellow, true),
        ("  h / l         previous / next file  (also [f / ]f)", Theme.text, false),
        ("  Ctrl-h/j/k/l  focus sidebar / files / checks / diff", Theme.text, false),
        ("  /  n / N      search the diff, next / previous match", Theme.text, false),
        ("  w             toggle wrapping for the current file", Theme.text, false),
        ("  V             start / stop visual line selection", Theme.text, false),
        ("  mouse / y     drag to select text, y copies it", Theme.text, false),
        ("  c             comment on the line(s); on a thread: reply", Theme.text, false),
        ("  e             edit your comment", Theme.text, false),
        ("  Enter         expand / collapse a comment thread", Theme.text, false),
        ("  Space s       submit the pending review", Theme.text, false),
        ("  Space m       merge the pull request", Theme.text, false),
        ("  Space d       show the PR description", Theme.text, false),
        ("  X             close the pull request", Theme.text, false),
        ("", Theme.text, false),
        ("COMMENT FIELD (opens under the line, in normal mode)", Theme.yellow, true),
        ("  i             type", Theme.text, false),
        ("  Esc           typing: back to normal mode. Normal mode: cancel", Theme.text, false),
        ("  Enter         normal mode: send", Theme.text, false),
        ("", Theme.text, false),
        ("SUBMIT / MERGE DIALOGS", Theme.yellow, true),
        ("  j / k         submit: pick approve / request changes / comment", Theme.text, false),
        ("  j / k         merge: choose merge / squash / rebase", Theme.text, false),
        ("  i             edit the text. Esc stops editing", Theme.text, false),
        ("  Enter         confirm.  Esc closes the dialog", Theme.text, false),
        ("", Theme.text, false),
        ("FILES / CHECKS (sidebar)", Theme.yellow, true),
        ("  Enter         files: jump to the file", Theme.text, false),
        ("  o             checks: open the check; files: open the PR", Theme.text, false),
        ("", Theme.text, false),
        ("COPILOT PANE", Theme.yellow, true),
        ("  Space a i     open / close (hides the sidebar)", Theme.text, false),
        ("  Ctrl-h / l    move between the diff and the pane", Theme.text, false),
        ("  i             type a prompt under the response", Theme.text, false),
        ("  Enter         new line.  Esc: normal mode, then Enter sends", Theme.text, false),
        ("  j / k         move the line cursor.  Ctrl-d/u, g/G also work", Theme.text, false),
        ("  V / y         select lines (or drag the mouse) / copy them", Theme.text, false),
        ("  Esc           clear selection, cancel a request, then close", Theme.text, false),
        ("  q             close", Theme.text, false),
        ("", Theme.text, false),
        ("Press ? or Esc to close", Theme.dim, false),
    ]

    private var offset = 0
    private var lineHeight: CGFloat { Theme.uiRowHeight }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirty: NSRect) {
        Theme.bg.withAlphaComponent(0.82).setFill()
        bounds.fill()

        let panel = bounds.insetBy(dx: max(24, bounds.width * 0.18), dy: 28)
        Theme.panel.setFill()
        panel.fill()
        Theme.border.setStroke()
        NSBezierPath(rect: panel).stroke()

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: panel).addClip()
        let content = panel.insetBy(dx: 24, dy: 18)
        let first = max(0, Int(-content.minY / lineHeight) + offset)
        let last = min(lines.count, first + Int(content.height / lineHeight) + 2)
        for i in first..<last {
            let y = content.minY + CGFloat(i - offset) * lineHeight
            let (text, color, bold) = lines[i]
            NSAttributedString(string: text, attributes: Theme.attrs(color, bold: bold, ui: true))
                .draw(at: NSPoint(x: content.minX, y: y))
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    override func keyDown(with e: NSEvent) {
        guard let key = e.charactersIgnoringModifiers?.first else { return }
        let visible = max(1, Int((bounds.height - 56) / lineHeight))
        switch key {
        case "j", "l": scroll(by: 1)
        case "k", "h": scroll(by: -1)
        case "d" where e.modifierFlags.contains(.control): scroll(by: visible / 2)
        case "u" where e.modifierFlags.contains(.control): scroll(by: -(visible / 2))
        case "g":
            if e.characters == "G" { scroll(to: lines.count) } else { scroll(to: 0) }
        case "?": onClose?()
        case "q": onClose?()
        default:
            if e.keyCode == 53 { onClose?() }
        }
    }

    private func scroll(by amount: Int) { scroll(to: offset + amount) }

    private func scroll(to value: Int) {
        let visible = max(1, Int((bounds.height - 56) / lineHeight))
        offset = max(0, min(value, max(0, lines.count - visible)))
        needsDisplay = true
    }
}
