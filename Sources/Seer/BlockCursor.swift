import AppKit

/// Block drawn over the character under the caret, with that character redrawn in the background color.
private final class CursorBlock: NSView {
    var color = NSColor.white
    var glyph: NSAttributedString?

    override var isFlipped: Bool { true }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func draw(_ dirty: NSRect) {
        color.setFill()
        bounds.fill()
        glyph?.draw(at: .zero)
    }
}

/// Text view with a terminal-style block cursor (the character under it shown inverted, like neovim).
/// The system caret is suppressed; its draw calls position the overlay (blink is ignored: the block stays solid), so layout and selection are untouched.
class BlockCursorTextView: NSTextView {
    private let block = CursorBlock()

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard selectedRange().length == 0, window?.firstResponder === self else { return block.isHidden = true }
        if block.superview == nil { addSubview(block) }
        let loc = selectedRange().location
        let ns = string as NSString
        var glyph: NSAttributedString?
        var width = NSAttributedString(string: " ", attributes: [.font: font ?? Theme.font]).size().width
        if loc < ns.length, ns.character(at: loc) != 10, let lm = layoutManager, let tc = textContainer, let ts = textStorage {
            let range = ns.rangeOfComposedCharacterSequence(at: loc)
            let w = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: tc).width
            if w > 1 { width = w }
            let g = NSMutableAttributedString(attributedString: ts.attributedSubstring(from: range))
            g.addAttribute(.foregroundColor, value: Theme.bg, range: NSRange(location: 0, length: g.length))
            glyph = g
        }
        block.color = color
        block.glyph = glyph
        block.frame = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        block.needsDisplay = true
        block.isHidden = false
    }

    override func resignFirstResponder() -> Bool {
        block.isHidden = true
        return super.resignFirstResponder()
    }
}
