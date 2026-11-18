import AppKit

/// TextKit layout of a string drawn with `draw(with:options: .usesLineFragmentOrigin)`, for mouse hit-testing and
/// selection highlights. Points and rects are relative to the text's drawing origin.
struct TextLayout {
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container: NSTextContainer

    init(_ text: NSAttributedString, width: CGFloat) {
        storage = NSTextStorage(attributedString: text)
        container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    /// Caret position nearest to `p`: before or after the glyph under it, whichever side is closer.
    func index(at p: NSPoint) -> Int {
        guard storage.length > 0 else { return 0 }
        var fraction: CGFloat = 0
        let i = manager.characterIndex(for: p, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        return min(storage.length, i + (fraction > 0.5 ? 1 : 0))
    }

    func rects(_ range: NSRange) -> [NSRect] {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var out: [NSRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { r, _ in out.append(r) }
        return out
    }
}
