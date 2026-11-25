import Foundation
import Testing
@testable import SeerCore

let sampleDiff = """
diff --git a/a.go b/a.go
index 1111111..2222222 100644
--- a/a.go
+++ b/a.go
@@ -1,4 +1,5 @@ package a
 package a
-func old() {}
+func new1() {}
+func new2() {}

 var x = 1
@@ -10,2 +11,2 @@ func f() {
-	a := 1
+	a := 2
 }
\\ No newline at end of file
diff --git a/old name.txt b/new name.txt
similarity index 90%
rename from old name.txt
rename to new name.txt
index 3333333..4444444 100644
--- a/old name.txt
+++ b/new name.txt
@@ -1 +1 @@
--- dashes
+++ pluses
diff --git a/img.png b/img.png
new file mode 100644
index 0000000..5555555
Binary files /dev/null and b/img.png differ
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
index 6666666..0000000
--- a/gone.txt
+++ /dev/null
@@ -1,2 +0,0 @@
-x
-y
"""

@Suite struct DiffParserTests {
    let diff = DiffParser.parse(sampleDiff)

    @Test func files() {
        #expect(diff.files.map(\.path) == ["a.go", "new name.txt", "img.png", "gone.txt"])
        #expect(diff.files[1].oldPath == "old name.txt")
        #expect(diff.files[2].isBinary)
        #expect(diff.files.map(\.adds) == [3, 1, 0, 0])
        #expect(diff.files.map(\.dels) == [2, 1, 0, 2])
        #expect(diff.files[0].oldBlob == "1111111" && diff.files[0].newBlob == "2222222")
        #expect(diff.files[2].oldBlob == nil && diff.files[3].newBlob == nil)
    }

    @Test func numbering() {
        let rows = Array(diff.rows[diff.rowRange(file: 0)])
        #expect(rows.map(\.kind) == [.file, .hunk, .context, .del, .add, .add, .context, .context,
                                     .hunk, .del, .add, .context, .meta])
        #expect(rows[3].old == 2 && rows[3].new == nil)
        #expect(rows[5].new == 3)
        #expect(rows[6].old == 3 && rows[6].new == 4 && rows[6].text == "")
        #expect(rows[10].new == 11 && rows[9].old == 10)
        #expect(rows[11].old == 11 && rows[11].new == 12)
    }

    @Test func dashesInsideHunk() {
        let rows = Array(diff.rows[diff.rowRange(file: 1)])
        #expect(rows.map(\.kind) == [.file, .hunk, .del, .add])
        #expect(rows[2].text == "-- dashes" && rows[3].text == "++ pluses")
    }

    @Test func lineLookup() {
        let r0 = diff.rowRange(file: 0)
        #expect(diff.row(forLine: 3, file: 0) == r0.lowerBound + 5)
        #expect(diff.row(forLine: 12, file: 0) == r0.lowerBound + 11)
        // line 7 isn't in the diff; closest shown is 5 (dist 2) vs 11 (dist 4)
        #expect(diff.row(forLine: 7, file: 0) == r0.lowerBound + 7)
        let r3 = diff.rowRange(file: 3)
        #expect(diff.row(forLine: 2, file: 3) == r3.lowerBound + 3)
        #expect(diff.row(forLine: 1, file: 2) == nil)
    }
}

@Suite struct QuotedPathTests {
    // git C-quotes non-ASCII paths: "ż" is \305\274, "ó" is \303\263.
    let diff = DiffParser.parse("""
    diff --git "a/docs/\\305\\274\\303\\263\\305\\202w.md" "b/docs/\\305\\274\\303\\263\\305\\202w.md"
    index 1111111..2222222 100644
    --- "a/docs/\\305\\274\\303\\263\\305\\202w.md"
    +++ "b/docs/\\305\\274\\303\\263\\305\\202w.md"
    @@ -1 +1 @@
    -a
    +b
    diff --git "a/tab\\there" b/plain.txt
    similarity index 100%
    rename from "tab\\there"
    rename to plain.txt
    diff --git a/x.txt "b/say \\"hi\\".txt"
    deleted file mode 100644
    """)

    @Test func paths() {
        #expect(diff.files.map(\.path) == ["docs/żółw.md", "plain.txt", "say \"hi\".txt"])
        #expect(diff.files[1].oldPath == "tab\there")
        #expect(diff.files[0].adds == 1 && diff.files[0].dels == 1)
    }

    @Test func unquote() {
        #expect(DiffParser.unquote("plain") == "plain")
        #expect(DiffParser.unquote(#""a\\b\"c\101""#) == "a\\b\"cA")
    }
}

@Suite struct CommentTargetTests {
    let diff = DiffParser.parse(sampleDiff)

    @Test func single() {
        let r0 = diff.rowRange(file: 0).lowerBound
        #expect(diff.commentTarget(r0 + 4, r0 + 4) ==
            CommentTarget(path: "a.go", line: 2, side: .right, startLine: nil, startSide: nil, row: r0 + 4))
        #expect(diff.commentTarget(r0 + 3, r0 + 3)?.side == .left)
        #expect(diff.commentTarget(r0, r0 + 1) == nil)
    }

    @Test func range() {
        let r0 = diff.rowRange(file: 0).lowerBound
        let t = diff.commentTarget(r0 + 6, r0 + 3)
        #expect(t == CommentTarget(path: "a.go", line: 4, side: .right, startLine: 2, startSide: .left, row: r0 + 6))
        #expect(t?.label == "a.go:2-4")
        #expect(diff.commentTarget(r0 + 11, diff.rowRange(file: 1).lowerBound + 2) == nil)
    }
}

@Suite struct VimKeysTests {
    func run(_ s: String) -> [Command] {
        var v = VimKeys()
        return s.compactMap { v.feed(.char($0)) }
    }

    @Test func counts() {
        #expect(run("20k") == [.up(20)])
        #expect(run("j") == [.down(1)])
        #expect(run("105j") == [.down(105)])
        #expect(run("0") == [.other("0")])
    }

    @Test func gMotions() {
        #expect(run("gg") == [.top])
        #expect(run("G") == [.bottom])
        #expect(run("20g") == [.gotoLine(20)])
        #expect(run("20G") == [.gotoLine(20)])
        #expect(run("gj") == [])
        #expect(run("]f[f") == [.nextFile, .prevFile])
        #expect(run(" ai") == [.ai])
        #expect(run(" d") == [.description])
    }

    @Test func visual() {
        #expect(run("V3jc") == [.visual, .down(3), .comment])
        var v = VimKeys()
        _ = v.feed(.char("5"))
        #expect(v.feed(.escape) == .escape)
        #expect(v.feed(.char("j")) == .down(1))
        #expect(v.feed(.ctrl("d")) == .halfDown)
    }
}

@Suite struct ConfigTests {
    @Test func valid() throws {
        let c = try Config.parse(Data(#"{"repos":["a/b","c-d/e.f"]}"#.utf8), path: "p")
        #expect(c.repos == [Repo(owner: "a", name: "b"), Repo(owner: "c-d", name: "e.f")])
    }

    @Test func invalid() throws {
        #expect(throws: ConfigError.badRepos(path: "p", entries: ["nope", "a/b/c", "/x"])) {
            try Config.parse(Data(#"{"repos":["ok/fine","nope","a/b/c","/x"]}"#.utf8), path: "p")
        }
        #expect(try Config.parse(Data(#"{"repos":[]}"#.utf8), path: "p").repos.isEmpty)
        #expect(throws: (any Error).self) { try Config.parse(Data("{".utf8), path: "p") }
    }

    @Test func missingIsEmptyAndSaveRoundTrips() throws {
        let dir = NSTemporaryDirectory() + "seer-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let env = ["XDG_CONFIG_HOME": dir]
        #expect(try Config.load(env: env).repos.isEmpty)
        #expect(throws: ConfigError.badRepos(path: Config.path(env: env), entries: ["bad"])) { try Config.save(["a/b", "bad"], env: env) }
        #expect(!FileManager.default.fileExists(atPath: Config.path(env: env)))
        _ = try Config.save(["a/b", "c/d"], env: env)
        #expect(try Config.load(env: env).repos.map(\.full) == ["a/b", "c/d"])
        #expect(Config.rawRepos(env: env) == ["a/b", "c/d"])
    }

    @Test func path() {
        #expect(Config.path(env: ["XDG_CONFIG_HOME": "/x"]) == "/x/seer/config.json")
        #expect(Config.path(env: [:]) == NSHomeDirectory() + "/.config/seer/config.json")
    }
}

/// Grammars built by `make grammars` (scripts/grammars.sh).
let useBuiltGrammars: Void = {
    Highlighter.dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../.build/grammars").standardized.path
}()

@Suite struct HighlighterTests {
    init() { _ = useBuiltGrammars }

    @Test func luaPatterns() throws {
        #expect(Highlighter.translateLuaPattern("^[A-Z][A-Z%d_]*$") == "^[A-Z][A-Z0-9_]*$")
        #expect(Highlighter.translateLuaPattern("^%a-%.") == "^[A-Za-z]*?\\.")
        #expect(Highlighter.translateLuaPattern("%s+%w") == "\\s+[A-Za-z0-9]")
        let re = try NSRegularExpression(pattern: Highlighter.translateLuaPattern("^_*[A-Z][A-Z%d_]*$"))
        #expect(re.firstMatch(in: "MAX_SIZE", range: NSRange(location: 0, length: 8)) != nil)
        #expect(re.firstMatch(in: "MaxSize", range: NSRange(location: 0, length: 7)) == nil)
    }

    @Test func goSnippet() throws {
        let lang = try Highlighter.load("go")
        let src = "package main\n\nfunc main() {\n\ts := \"héllo\" // hi\n\treturn\n}\n"
        let lines = Highlighter.highlight(src, lang: lang)
        func groups(_ line: Int, _ start: Int) -> [String] {
            lines[line].filter { $0.start == start }.map(\.group)
        }
        #expect(groups(2, 0).last == "keyword")
        #expect(groups(3, 6).last == "string")
        // "héllo" is 7 UTF-16 units including quotes; comment starts after it and a space
        #expect(lines[3].contains { $0.group == "string" && $0.length == 7 })
        #expect(groups(3, 14).last == "comment")
    }

    @Test func diffMapping() throws {
        let diff = DiffParser.parse(sampleDiff)
        let spans = Highlighter.highlight(diff: diff, sources: [0: (
            old: "package a\nfunc old() {}\nvar x = 1\n",
            new: "package a\nfunc new1() {}\nfunc new2() {}\n\nvar x = 1\n"
        )])
        let r0 = diff.rowRange(file: 0).lowerBound
        #expect(spans[r0 + 3]?.contains { $0.group == "keyword" && $0.start == 0 } == true)
        #expect(spans[r0 + 4]?.contains { $0.group == "function" } == true)
    }

    @Test func allBundledQueriesCompile() {
        let langs = Set(Highlighter.byExtension.values).union(Highlighter.byFilename.values)
        for l in langs.sorted() {
            #expect(throws: Never.self, "\(l)") { _ = try Highlighter.load(l) }
        }
    }
}

@Suite struct GraphQLDecodeTests {
    struct D: Decodable, Equatable { let r0: Int?; let r1: Int? }
    let body = Data(#"{"data":{"r0":1,"r1":null},"errors":[{"message":"Could not resolve to a Repository"}]}"#.utf8)

    @Test func partialKeepsData() throws {
        let (d, errs) = try GitHub.decode(body, as: D.self, partial: true)
        #expect(d == D(r0: 1, r1: nil))
        #expect(errs == ["Could not resolve to a Repository"])
    }

    @Test func strictThrows() {
        #expect(throws: (any Error).self) { try GitHub.decode(body, as: D.self, partial: false) }
        #expect(throws: (any Error).self) {
            try GitHub.decode(Data(#"{"errors":[{"message":"x"}]}"#.utf8), as: D.self, partial: true)
        }
    }
}

@Suite struct TerminalTests {
    let repo = Repo(owner: "o", name: "my.repo")

    @Test func sessionNameIsTmuxSafe() { #expect(Terminal.sessionName(repo, 7) == "seer-my_repo-7") }

    @Test func scriptQuotesPaths() {
        let s = Terminal.script(dir: "/a b/it's", repo: repo, number: 7)
        #expect(s.hasPrefix(#"cd '/a b/it'\''s' && gh pr checkout 7 -R 'o/my.repo'"#))
        #expect(s.contains("exec tmux attach -t '=seer-my_repo-7'"))
    }

    @Test func commandsPerTerminal() {
        #expect(Terminal.ghostty.command(shell: "/bin/zsh", script: "x").args == ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-lc", "x"])
        #expect(Terminal.kitty.command(shell: "/bin/zsh", script: "x").args.suffix(3) == ["/bin/zsh", "-lc", "x"])
        #expect(Terminal.terminal.command(shell: "/bin/zsh", script: "a\"b").args.last!.contains(#"a\"b"#))
    }
}

@Suite struct GhAccountsTests {
    @Test func parsesGithubComLogins() {
        let json = #"{"hosts":{"github.com":[{"login":"a","active":true},{"login":"b","active":false}],"ghe.x":[{"login":"c"}]}}"#
        #expect(GitHub.parseAccounts(Data(json.utf8)) == ["a", "b"])
        #expect(GitHub.parseAccounts(Data("nope".utf8)).isEmpty)
    }
}

@MainActor @Suite struct ReviewSessionTests {
    func detail(head: String = "new", pending: String? = nil, pendingCommit: String? = nil) -> PRDetail {
        PRDetail(id: "PR1", title: "t", body: "", url: "u", headSha: head, mergeable: "MERGEABLE", behindBy: 0, reviewDecision: nil, autoMerge: nil,
                 headOwner: "o", commitHeadlines: [], commitBodies: [], commitCount: 1, checks: [], threads: [],
                 pendingReviewId: pending, pendingReviewCommit: pendingCommit, viewer: "me")
    }
    let pr = PRSummary(repo: Repo(owner: "o", name: "n"), number: 1, title: "t", url: "u", author: "a", isDraft: false,
                       createdAt: "", updatedAt: "", headSha: "stale", isApproved: false, changesRequested: false, headRef: "h",
                       baseRef: "main", reviewRequested: false, additions: 0, deletions: 0)

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func add(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    @Test func concurrentCommentsCreateOneReviewOnLoadedHead() async throws {
        let calls = Calls()
        let s = ReviewSession(pr: pr, detail: detail()) { id, sha in
            calls.add("\(id)@\(sha)")
            try await Task.sleep(for: .milliseconds(20))
            return "R1"
        }
        async let a = s.ensureReview()
        async let b = s.ensureReview()
        #expect(try await [a, b] == ["R1", "R1"])
        #expect(calls.all == ["PR1@new"])
        #expect(try await s.ensureReview() == "R1")
        s.submitted()
        #expect(s.pendingReviewId == nil)
    }

    @Test func blocksApprovingOrMergingOldCommits() throws {
        let s = ReviewSession(pr: pr, detail: detail()) { _, _ in "R" }
        #expect(throws: Never.self) { try s.checkCurrent(latestHead: "new", approving: true) }
        #expect(throws: ReviewBlock.newCommits) { try s.checkCurrent(latestHead: "newer", approving: false) }
        let old = ReviewSession(pr: pr, detail: detail(pending: "R0", pendingCommit: "old")) { _, _ in "R" }
        #expect(throws: ReviewBlock.pendingOnOldCommit) { try old.checkCurrent(latestHead: "new", approving: true) }
        #expect(throws: Never.self) { try old.checkCurrent(latestHead: "new", approving: false) }
    }
}

@Suite struct TextSelectionTests {
    let rows = ["hello", "", "world"]

    @Test func acrossRows() {
        let sel = TextSelection(anchor: .init(row: 2, index: 3), head: .init(row: 0, index: 1))
        #expect(sel.range(row: 0, length: 5) == NSRange(location: 1, length: 4))
        #expect(sel.range(row: 1, length: 0) == nil)
        #expect(sel.range(row: 2, length: 5) == NSRange(location: 0, length: 3))
        #expect(sel.text { rows[$0] } == "ello\n\nwor")
        #expect(sel.text { $0 == 1 ? nil : rows[$0] } == "ello\nwor")
    }

    @Test func withinRow() {
        let sel = TextSelection(anchor: .init(row: 0, index: 1), head: .init(row: 0, index: 3))
        #expect(sel.text { rows[$0] } == "el")
        #expect(sel.range(row: 2, length: 5) == nil)
        #expect(TextSelection(anchor: .init(row: 0, index: 2), head: .init(row: 0, index: 2)).isEmpty)
    }
}

@Test func relativeAgeBuckets() {
    let now = ISO8601DateFormatter().date(from: "2026-11-18T12:00:00Z")!
    #expect(relativeAge("2026-11-18T11:30:00Z", now: now) == "30m")
    #expect(relativeAge("2026-11-18T09:00:00Z", now: now) == "3h")
    #expect(relativeAge("2026-11-06T12:00:00Z", now: now) == "12d")
    #expect(relativeAge("2026-07-18T12:00:00Z", now: now) == "4mo")
    #expect(relativeAge("2024-11-18T12:00:00Z", now: now) == "2y")
    #expect(relativeAge("nonsense", now: now) == "")
}

@Test func fileTreeMergesSingleChildFolders() {
    let rows = fileTree(["packages/app/src/a.ts", "packages/app/src/lib/b.ts", "packages/app/src/lib/c.ts", "README.md"])
    #expect(rows == [
        TreeRow(depth: 0, name: "packages/app/src/", file: nil),
        TreeRow(depth: 1, name: "lib/", file: nil),
        TreeRow(depth: 2, name: "b.ts", file: 1),
        TreeRow(depth: 2, name: "c.ts", file: 2),
        TreeRow(depth: 1, name: "a.ts", file: 0),
        TreeRow(depth: 0, name: "README.md", file: 3),
    ])
}
