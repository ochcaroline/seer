import Foundation

/// Character selection across rows, from `anchor` (where the drag started) to `head`.
public struct TextSelection: Equatable, Sendable {
    /// A row and a UTF-16 offset into its text.
    public struct Pos: Comparable, Sendable {
        public var row: Int
        public var index: Int

        public init(row: Int, index: Int) {
            self.row = row
            self.index = index
        }

        public static func < (a: Pos, b: Pos) -> Bool { (a.row, a.index) < (b.row, b.index) }
    }

    public var anchor: Pos
    public var head: Pos

    public init(anchor: Pos, head: Pos) {
        self.anchor = anchor
        self.head = head
    }

    public var start: Pos { min(anchor, head) }
    public var end: Pos { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }

    /// Selected part of row `r` (whose text is `length` UTF-16 units), nil if none of it is.
    public func range(row r: Int, length: Int) -> NSRange? {
        guard (start.row...end.row).contains(r) else { return nil }
        let from = r == start.row ? min(start.index, length) : 0
        let to = r == end.row ? min(end.index, length) : length
        return to > from ? NSRange(location: from, length: to - from) : nil
    }

    /// Selected text with rows joined by newlines; `rowText` returns nil for rows that have no text (they're skipped).
    public func text(_ rowText: (Int) -> String?) -> String {
        (start.row...end.row).compactMap { r -> String? in
            guard let s = rowText(r) else { return nil }
            let ns = s as NSString
            return range(row: r, length: ns.length).map { ns.substring(with: $0) } ?? ""
        }.joined(separator: "\n")
    }
}
