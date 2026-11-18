import TreeSitter
import Foundation

/// A highlighted range within one line, in UTF-16 offsets, tagged with a palette group.
public struct HLSpan: Sendable, Equatable {
    public let start: Int
    public let length: Int
    public let group: String
}

public enum HighlightError: Error, Equatable {
    case parserNotFound(String)
    case symbolMissing(String)
    case incompatibleABI(String, UInt32)
    case queryNotFound(String)
    case badQuery(String, offset: UInt32, type: UInt32)
}

/// A loaded parser plus its compiled highlights query. Queries are immutable, so these are shared across threads.
public final class TSLang: @unchecked Sendable {
    let name: String
    let language: OpaquePointer
    let query: OpaquePointer
    let groups: [String?]
    let predicates: [[Predicate]]

    init(name: String, language: OpaquePointer, query: OpaquePointer) {
        self.name = name
        self.language = language
        self.query = query
        groups = (0..<ts_query_capture_count(query)).map { id in
            var len: UInt32 = 0
            let p = ts_query_capture_name_for_id(query, id, &len)!
            return Highlighter.group(forCapture: String(cString: p))
        }
        predicates = (0..<ts_query_pattern_count(query)).map { Predicate.parse(query: query, pattern: $0) }
    }
}

enum PredArg {
    case capture(UInt32)
    case string(String)
}

struct Predicate {
    enum Op {
        case eq(PredArg)
        case anyOf(Set<String>)
        case match(NSRegularExpression)
    }
    let capture: UInt32
    let op: Op
    let negated: Bool

    static func parse(query: OpaquePointer, pattern: UInt32) -> [Predicate] {
        var count: UInt32 = 0
        guard let steps = ts_query_predicates_for_pattern(query, pattern, &count) else { return [] }
        func str(_ id: UInt32) -> String {
            var len: UInt32 = 0
            return String(cString: ts_query_string_value_for_id(query, id, &len))
        }
        var result: [Predicate] = []
        var group: [TSQueryPredicateStep] = []
        for i in 0..<Int(count) {
            let step = steps[i]
            guard step.type == TSQueryPredicateStepTypeDone else {
                group.append(step)
                continue
            }
            defer { group = [] }
            guard group.count >= 2, group[0].type == TSQueryPredicateStepTypeString,
                  group[1].type == TSQueryPredicateStepTypeCapture else { continue }
            var name = str(group[0].value_id)
            let negated = name.hasPrefix("not-")
            if negated { name.removeFirst(4) }
            let cap = group[1].value_id
            let args: [PredArg] = group.dropFirst(2).map {
                $0.type == TSQueryPredicateStepTypeCapture ? .capture($0.value_id) : .string(str($0.value_id))
            }
            let strings = args.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
            switch name {
            case "eq?":
                if let a = args.first { result.append(Predicate(capture: cap, op: .eq(a), negated: negated)) }
            case "any-of?":
                result.append(Predicate(capture: cap, op: .anyOf(Set(strings)), negated: negated))
            case "match?", "lua-match?", "vim-match?":
                guard let pat = strings.first else { continue }
                let src = name == "lua-match?" ? Highlighter.translateLuaPattern(pat) : pat
                if let re = try? NSRegularExpression(pattern: src) {
                    result.append(Predicate(capture: cap, op: .match(re), negated: negated))
                }
            default:
                // shortcut: has-ancestor?, has-parent?, contains? etc. are treated as passing; implement one if it mis-colors
                continue
            }
        }
        return result
    }
}

public enum Highlighter {
    /// Grammars built by scripts/grammars.sh; `make build` bundles them into Seer.app.
    public static var dir = (Bundle.main.resourcePath ?? "") + "/grammars"
    static var parserDir: String { dir + "/parser" }
    static var queryDir: String { dir + "/queries" }

    static let byExtension: [String: String] = [
        "go": "go", "ts": "typescript", "mts": "typescript", "cts": "typescript", "tsx": "tsx",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "py": "python", "rb": "ruby", "lua": "lua", "sh": "bash", "bash": "bash", "zsh": "zsh",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "css": "css",
        "html": "html", "htm": "html", "xml": "xml", "sql": "sql", "vue": "vue",
        "md": "markdown", "vim": "vim", "ps1": "powershell", "psm1": "powershell",
    ]
    static let byFilename: [String: String] = [
        "Dockerfile": "dockerfile", "go.mod": "gomod", "go.sum": "gosum", "go.work": "gowork",
        ".gitignore": "gitignore", ".gitattributes": "gitattributes", ".editorconfig": "editorconfig",
    ]

    public static func language(forPath path: String) -> String? {
        let file = (path as NSString).lastPathComponent
        if let l = byFilename[file] { return l }
        return byExtension[(file as NSString).pathExtension.lowercased()]
    }

    nonisolated(unsafe) private static var cache: [String: Result<TSLang, HighlightError>] = [:]
    private static let lock = NSLock()

    public static func load(_ name: String) throws -> TSLang {
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[name] { return try r.get() }
        let r = Result { try loadUncached(name) }.mapError { $0 as! HighlightError }
        cache[name] = r
        return try r.get()
    }

    private static func loadUncached(_ name: String) throws -> TSLang {
        guard let handle = dlopen(parserDir + "/\(name).so", RTLD_NOW | RTLD_LOCAL) else {
            throw HighlightError.parserNotFound(name)
        }
        guard let sym = dlsym(handle, "tree_sitter_\(name)") else { throw HighlightError.symbolMissing(name) }
        typealias LangFn = @convention(c) () -> OpaquePointer?
        guard let language = unsafeBitCast(sym, to: LangFn.self)() else { throw HighlightError.symbolMissing(name) }
        let abi = ts_language_abi_version(language)
        guard abi >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION, abi <= TREE_SITTER_LANGUAGE_VERSION else {
            throw HighlightError.incompatibleABI(name, abi)
        }
        var seen = Set<String>()
        guard let source = queryText(name, seen: &seen) else { throw HighlightError.queryNotFound(name) }
        var offset: UInt32 = 0
        var type = TSQueryErrorNone
        let q = source.withCString { ts_query_new(language, $0, UInt32(strlen($0)), &offset, &type) }
        guard let q else { throw HighlightError.badQuery(name, offset: offset, type: type.rawValue) }
        return TSLang(name: name, language: language, query: q)
    }

    /// highlights.scm with its `; inherits: a,(b)` bases prepended.
    static func queryText(_ name: String, seen: inout Set<String>) -> String? {
        guard seen.insert(name).inserted,
              let text = try? String(contentsOfFile: queryDir + "/\(name)/highlights.scm", encoding: .utf8)
        else { return nil }
        var out = ""
        for line in text.split(separator: "\n", maxSplits: 5).prefix(5) where line.hasPrefix("; inherits:") {
            for base in line.dropFirst("; inherits:".count).split(separator: ",") {
                let b = base.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                if let t = queryText(b, seen: &seen) { out += t + "\n" }
            }
        }
        return out + text
    }

    static func group(forCapture name: String) -> String? {
        if name == "variable.member" || name.hasPrefix("property") || name.hasPrefix("field") { return "property" }
        if name == "variable.builtin" { return "keyword" }
        let head = name.split(separator: ".").first.map(String.init) ?? name
        switch head {
        case "keyword", "conditional", "repeat", "include", "exception", "tag": return "keyword"
        case "string", "character": return "string"
        case "comment": return "comment"
        case "type", "constructor", "module", "namespace": return "type"
        case "function", "method": return "function"
        case "number", "float", "boolean", "constant": return "number"
        case "attribute": return "property"
        case "operator": return "operator"
        case "punctuation": return "punctuation"
        case "none": return "none"
        default: return nil
        }
    }

    /// Lua pattern -> ICU regex, enough for the patterns used in nvim highlight queries.
    static func translateLuaPattern(_ pat: String) -> String {
        let classes: [Character: String] = [
            "a": "[A-Za-z]", "A": "[^A-Za-z]", "d": "[0-9]", "D": "[^0-9]", "l": "[a-z]", "L": "[^a-z]",
            "u": "[A-Z]", "U": "[^A-Z]", "w": "[A-Za-z0-9]", "W": "[^A-Za-z0-9]", "x": "[0-9A-Fa-f]", "X": "[^0-9A-Fa-f]",
            "s": "\\s", "S": "\\S", "p": "\\p{P}", "P": "\\P{P}",
        ]
        var out = ""
        var inSet = false
        var it = Array(pat).makeIterator()
        while let c = it.next() {
            switch c {
            case "%":
                guard let n = it.next() else { break }
                if let cls = classes[n] {
                    out += inSet && cls.hasPrefix("[") ? String(cls.dropFirst().dropLast()) : cls
                } else {
                    out += n.isLetter || n.isNumber ? String(n) : "\\" + String(n)
                }
            case "[" where !inSet:
                inSet = true
                out.append(c)
            case "]" where inSet:
                inSet = false
                out.append(c)
            case "-" where !inSet:
                out += "*?"
            case "\\", "{", "}", "|":
                out += "\\" + String(c)
            case "[" where inSet:
                out += "\\["
            default:
                out.append(c)
            }
        }
        return out
    }

    /// Per-line spans for `source`, applied in order (later spans win).
    public static func highlight(_ source: String, lang: TSLang) -> [[HLSpan]] {
        let bytes = Array(source.utf8)
        var lineStarts = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { lineStarts.append(i + 1) }
        var lines = [[HLSpan]](repeating: [], count: lineStarts.count)
        var utf16Maps: [Int: [Int]] = [:]
        var asciiRows = Set<Int>()

        func lineEnd(_ row: Int) -> Int {
            row + 1 < lineStarts.count ? lineStarts[row + 1] - 1 : bytes.count
        }
        func utf16(_ row: Int, _ col: Int) -> Int {
            let start = lineStarts[row]
            let end = lineEnd(row)
            if asciiRows.contains(row) { return col }
            if let m = utf16Maps[row] { return m[min(col, m.count - 1)] }
            if !bytes[start..<end].contains(where: { $0 >= 0x80 }) {
                asciiRows.insert(row)
                return col
            }
            var map = [Int](repeating: 0, count: end - start + 1)
            var u = 0, i = start
            while i < end {
                let b = bytes[i]
                let len = b < 0x80 ? 1 : b < 0xE0 ? 2 : b < 0xF0 ? 3 : 4
                for k in 0..<len where i - start + k < map.count { map[i - start + k] = u }
                u += len == 4 ? 2 : 1
                i += len
            }
            map[end - start] = u
            utf16Maps[row] = map
            return map[min(col, map.count - 1)]
        }
        func text(_ node: TSNode) -> String {
            let s = Int(ts_node_start_byte(node)), e = Int(ts_node_end_byte(node))
            return String(decoding: bytes[min(s, bytes.count)..<min(e, bytes.count)], as: UTF8.self)
        }
        func passes(_ match: TSQueryMatch) -> Bool {
            let caps = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            func nodes(_ id: UInt32) -> [TSNode] { caps.filter { $0.index == id }.map(\.node) }
            for p in lang.predicates[Int(match.pattern_index)] {
                for node in nodes(p.capture) {
                    let t = text(node)
                    var ok: Bool
                    switch p.op {
                    case .eq(.string(let s)): ok = t == s
                    case .eq(.capture(let other)): ok = nodes(other).allSatisfy { text($0) == t }
                    case .anyOf(let set): ok = set.contains(t)
                    case .match(let re):
                        ok = re.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil
                    }
                    if ok == p.negated { return false }
                }
            }
            return true
        }

        guard let parser = ts_parser_new() else { return lines }
        defer { ts_parser_delete(parser) }
        ts_parser_set_language(parser, lang.language)
        let tree = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                ts_parser_parse_string(parser, nil, $0, UInt32(buf.count))
            }
        }
        guard let tree else { return lines }
        defer { ts_tree_delete(tree) }
        guard let cursor = ts_query_cursor_new() else { return lines }
        defer { ts_query_cursor_delete(cursor) }
        ts_query_cursor_exec(cursor, lang.query, ts_tree_root_node(tree))

        var match = TSQueryMatch()
        var capIndex: UInt32 = 0
        var lastMatch: (id: UInt32, ok: Bool)?
        while ts_query_cursor_next_capture(cursor, &match, &capIndex) {
            let cap = match.captures[Int(capIndex)]
            guard let group = lang.groups[Int(cap.index)] else { continue }
            if lastMatch?.id != match.id { lastMatch = (match.id, passes(match)) }
            guard lastMatch!.ok else { continue }
            let s = ts_node_start_point(cap.node), e = ts_node_end_point(cap.node)
            for row in Int(s.row)...Int(e.row) where row < lines.count {
                let from = row == Int(s.row) ? Int(s.column) : 0
                let to = row == Int(e.row) ? Int(e.column) : lineEnd(row) - lineStarts[row]
                let a = utf16(row, from), b = utf16(row, to)
                if b > a { lines[row].append(HLSpan(start: a, length: b - a, group: group)) }
            }
        }
        return lines
    }

    /// Spans per diff row: new-side lines for added/context rows, old-side lines for deleted rows.
    public static func highlight(diff: Diff, sources: [Int: (old: String?, new: String?)]) -> [Int: [HLSpan]] {
        var out: [Int: [HLSpan]] = [:]
        for (fi, src) in sources {
            guard fi < diff.files.count, let name = language(forPath: diff.files[fi].path),
                  let lang = try? load(name) else { continue }
            let old = src.old.map { highlight($0, lang: lang) } ?? []
            let new = src.new.map { highlight($0, lang: lang) } ?? []
            for r in diff.rowRange(file: fi) {
                let row = diff.rows[r]
                switch row.kind {
                case .add, .context:
                    if let n = row.new, n - 1 < new.count, n >= 1 { out[r] = new[n - 1] }
                case .del:
                    if let o = row.old, o - 1 < old.count, o >= 1 { out[r] = old[o - 1] }
                default: break
                }
            }
        }
        return out
    }
}
