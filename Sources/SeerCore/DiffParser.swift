import Foundation

public enum RowKind: Sendable, Equatable {
    case file, hunk, context, add, del, meta
}

public struct DiffRow: Sendable, Equatable {
    public let kind: RowKind
    public let file: Int
    public let old: Int?
    public let new: Int?
    public let text: String

    public var commentable: Bool { kind == .add || kind == .del || kind == .context }
}

public struct DiffFile: Sendable, Equatable {
    public var path: String
    public var oldPath: String?
    public var adds = 0
    public var dels = 0
    public var isBinary = false
    public var oldBlob: String?
    public var newBlob: String?
    /// Index of this file's header in `Diff.rows`; rows run until the next file's header.
    public var headerRow: Int
}

public struct Diff: Sendable, Equatable {
    public var files: [DiffFile] = []
    public var rows: [DiffRow] = []

    public init() {}

    public func rowRange(file i: Int) -> Range<Int> {
        let end = i + 1 < files.count ? files[i + 1].headerRow : rows.count
        return files[i].headerRow..<end
    }

    /// Row showing new-file line `n` in file `i`, or the closest line shown in the diff.
    /// Deleted files only have old numbers, so those are used instead.
    public func row(forLine n: Int, file i: Int) -> Int? {
        let range = rowRange(file: i)
        let hasNew = range.contains { rows[$0].new != nil && rows[$0].kind != .file }
        var best: (row: Int, dist: Int)?
        for r in range where rows[r].commentable {
            guard let num = hasNew ? rows[r].new : rows[r].old else { continue }
            let d = abs(num - n)
            if best == nil || d < best!.dist { best = (r, d) }
            if d == 0 { break }
        }
        return best?.row
    }
}

public enum DiffParser {
    public static func parse(_ text: String) -> Diff {
        var diff = Diff()
        var cur: DiffFile?
        var curRows: [DiffRow] = []
        var oldLeft = 0, newLeft = 0, oldNo = 0, newNo = 0

        func flush() {
            guard var f = cur else { return }
            f.headerRow = diff.rows.count
            let fi = diff.files.count
            let label = f.oldPath.map { "\(f.path)  (renamed from \($0))" } ?? f.path
            diff.rows.append(DiffRow(kind: .file, file: fi, old: nil, new: nil, text: label))
            if f.isBinary {
                diff.rows.append(DiffRow(kind: .meta, file: fi, old: nil, new: nil, text: "Binary file"))
            }
            for r in curRows {
                diff.rows.append(DiffRow(kind: r.kind, file: fi, old: r.old, new: r.new, text: r.text))
            }
            diff.files.append(f)
            cur = nil
            curRows = []
        }

        for sub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(sub)
            if line.hasSuffix("\r") { line.removeLast() }

            if oldLeft > 0 || newLeft > 0 {
                let body = String(line.dropFirst())
                switch line.first {
                case "+":
                    curRows.append(DiffRow(kind: .add, file: 0, old: nil, new: newNo, text: body))
                    newNo += 1; newLeft -= 1; cur?.adds += 1
                    continue
                case "-":
                    curRows.append(DiffRow(kind: .del, file: 0, old: oldNo, new: nil, text: body))
                    oldNo += 1; oldLeft -= 1; cur?.dels += 1
                    continue
                case " ", nil:
                    curRows.append(DiffRow(kind: .context, file: 0, old: oldNo, new: newNo, text: body))
                    oldNo += 1; newNo += 1; oldLeft -= 1; newLeft -= 1
                    continue
                case "\\":
                    curRows.append(DiffRow(kind: .meta, file: 0, old: nil, new: nil, text: line))
                    continue
                default:
                    oldLeft = 0; newLeft = 0
                }
            }

            if line.hasPrefix("diff --git ") {
                flush()
                let rest = line.dropFirst("diff --git ".count)
                var path = String(rest)
                if rest.last == "\"", let r = rest.range(of: " \"", options: .backwards) {
                    path = String(unquote(rest[rest.index(after: r.lowerBound)...]).dropFirst(2))
                } else if let r = rest.range(of: " b/", options: .backwards) {
                    path = String(rest[r.upperBound...])
                }
                cur = DiffFile(path: path, headerRow: 0)
            } else if cur == nil {
                continue
            } else if line.hasPrefix("@@") {
                let (o, n) = parseHunkHeader(line)
                oldNo = o.start; oldLeft = o.count
                newNo = n.start; newLeft = n.count
                curRows.append(DiffRow(kind: .hunk, file: 0, old: nil, new: nil, text: line))
            } else if line.hasPrefix("\\") {
                curRows.append(DiffRow(kind: .meta, file: 0, old: nil, new: nil, text: line))
            } else if line.hasPrefix("rename from ") {
                cur?.oldPath = unquote(line.dropFirst("rename from ".count))
            } else if line.hasPrefix("rename to ") {
                cur?.path = unquote(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("+++ b/") || line.hasPrefix("+++ \"b/") {
                cur?.path = String(unquote(line.dropFirst(4)).dropFirst(2))
            } else if line.hasPrefix("index ") {
                let shas = line.dropFirst(6).split(separator: " ").first?.components(separatedBy: "..") ?? []
                if shas.count == 2 {
                    cur?.oldBlob = shas[0].allSatisfy({ $0 == "0" }) ? nil : shas[0]
                    cur?.newBlob = shas[1].allSatisfy({ $0 == "0" }) ? nil : shas[1]
                }
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                cur?.isBinary = true
            }
        }
        flush()
        return diff
    }

    /// A path as git prints it: plain, or C-quoted (`"b/\303\274.txt"`) when it has non-ASCII or special characters.
    static func unquote(_ s: Substring) -> String {
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return String(s) }
        var it = Array(s.utf8.dropFirst().dropLast())[...]
        var out: [UInt8] = []
        let escapes: [UInt8: UInt8] = [UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "t"): 9, UInt8(ascii: "n"): 10,
                                       UInt8(ascii: "v"): 11, UInt8(ascii: "f"): 12, UInt8(ascii: "r"): 13]
        let octal = UInt8(ascii: "0")...UInt8(ascii: "7")
        while let b = it.popFirst() {
            guard b == UInt8(ascii: "\\"), let e = it.popFirst() else { out.append(b); continue }
            if octal.contains(e) {
                var v = Int(e - 48)
                for _ in 0..<2 { if let d = it.first, octal.contains(d) { v = v * 8 + Int(d - 48); it.removeFirst() } }
                out.append(UInt8(truncatingIfNeeded: v))
            } else {
                out.append(escapes[e] ?? e)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func parseHunkHeader(_ line: String) -> (old: (start: Int, count: Int), new: (start: Int, count: Int)) {
        func range(_ s: Substring) -> (Int, Int) {
            let p = s.dropFirst().split(separator: ",")
            let start = Int(p.first ?? "") ?? 0
            let count = p.count > 1 ? (Int(p[1]) ?? 0) : 1
            return (start, count)
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 3 else { return ((0, 0), (0, 0)) }
        return (range(parts[1]), range(parts[2]))
    }
}

public struct CommentTarget: Sendable, Equatable {
    public let path: String
    public let line: Int
    public let side: Side
    public let startLine: Int?
    public let startSide: Side?
    /// Diff row the comment shows under (the last selected line).
    public let row: Int

    public var label: String {
        let s = startLine.map { "\($0)-" } ?? ""
        return "\(path):\(s)\(line)"
    }
}

extension Diff {
    /// Comment target for the commentable rows between diff rows `a` and `b` (any order), or nil
    /// if there are none or they span files. Deleted lines use the old number on the LEFT side.
    public func commentTarget(_ a: Int, _ b: Int) -> CommentTarget? {
        let lo = min(a, b), hi = max(a, b)
        guard lo >= 0, hi < rows.count else { return nil }
        let picked = (lo...hi).filter { rows[$0].commentable }
        guard let first = picked.first, let last = picked.last, rows[first].file == rows[last].file else { return nil }
        func pos(_ r: Int) -> (Int, Side) {
            rows[r].kind == .del ? (rows[r].old!, .left) : (rows[r].new!, .right)
        }
        let (line, side) = pos(last)
        let path = files[rows[last].file].path
        guard first != last else {
            return CommentTarget(path: path, line: line, side: side, startLine: nil, startSide: nil, row: last)
        }
        let (sl, ss) = pos(first)
        return CommentTarget(path: path, line: line, side: side, startLine: sl, startSide: ss, row: last)
    }
}
