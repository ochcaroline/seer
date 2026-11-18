public enum Key: Equatable, Sendable {
    case char(Character)
    case ctrl(Character)
    case enter
    case escape
}

public enum Command: Equatable, Sendable {
    case down(Int), up(Int)
    case top, bottom
    case gotoLine(Int)
    case halfDown, halfUp
    case nextFile, prevFile
    case visual, comment, submit
    case enter, escape
    case open, back, refresh
    case ai, merge, checkout
    case other(Character)
}

/// Turns key presses into commands, handling count prefixes and two-key sequences.
public struct VimKeys: Sendable {
    private var count: Int?
    private var pending: String?

    public init() {}

    public var pendingText: String {
        (count.map(String.init) ?? "") + (pending ?? "")
    }

    public mutating func feed(_ key: Key) -> Command? {
        let n = count
        let p = pending
        pending = nil
        switch key {
        case .escape:
            count = nil
            return .escape
        case .enter:
            count = nil
            return .enter
        case .ctrl(let c):
            count = nil
            switch c {
            case "d": return .halfDown
            case "u": return .halfUp
            default: return nil
            }
        case .char(let c):
            if let p {
                count = nil
                switch (p, c) {
                case (" ", "a"): pending = " a"; return nil
                case (" a", "i"): return .ai
                case (" ", "g"): pending = " g"; return nil
                case (" g", "h"): return .checkout
                case (" ", "m"): return .merge
                case (" ", "s"): return .submit
                case ("g", "g"): return .top
                case ("]", "f"): return .nextFile
                case ("[", "f"): return .prevFile
                default: return nil
                }
            }
            if let d = c.wholeNumberValue, c.isASCII, d > 0 || n != nil {
                count = min((n ?? 0) * 10 + d, 9_999_999)
                return nil
            }
            count = nil
            switch c {
            case " ": pending = " "; return nil
            case "j": return .down(n ?? 1)
            case "k": return .up(n ?? 1)
            case "g":
                if let n { return .gotoLine(n) }
                pending = "g"
                return nil
            case "G": return n.map(Command.gotoLine) ?? .bottom
            case "]", "[":
                pending = String(c)
                return nil
            case "V": return .visual
            case "c": return .comment
            case "o": return .open
            case "q": return .back
            case "r": return .refresh
            default: return .other(c)
            }
        }
    }
}
