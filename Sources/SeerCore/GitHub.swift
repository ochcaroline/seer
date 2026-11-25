import Foundation

public enum GitHubError: Error, CustomStringConvertible {
    case noToken(String)
    case http(Int, String)
    case graphQL([String])
    case decode(String)

    public var description: String {
        switch self {
        case .noToken(let why): return "No GitHub token: \(why). Run `gh auth login` or set GITHUB_TOKEN."
        case .http(let code, let body): return "GitHub HTTP \(code): \(body.prefix(300))"
        case .graphQL(let msgs): return "GitHub: " + msgs.joined(separator: "; ")
        case .decode(let why): return "Unexpected GitHub response: \(why)"
        }
    }
}

public struct PRSummary: Codable, Sendable, Hashable {
    public let repo: Repo
    public let number: Int
    public let title: String
    public let url: String
    public let author: String
    public let isDraft: Bool
    public let createdAt: String
    public let updatedAt: String
    public let headSha: String
    public let isApproved: Bool
    public let changesRequested: Bool
    public let headRef: String
    public let baseRef: String
    public let reviewRequested: Bool
    public let additions: Int
    public let deletions: Int
}

public struct PRList: Codable, Sendable {
    public let viewer: String
    public let prs: [PRSummary]
    /// Repos GitHub returned no data for (renamed, deleted or no access); `warnings` says why.
    public let unavailable: [Repo]
    public let warnings: [String]

    /// This list with `old` swapped for `new`, or dropped when `new` is nil.
    public func replacing(_ old: PRSummary, with new: PRSummary?) -> PRList {
        let prs = self.prs.compactMap { $0 == old ? new : $0 }
        return PRList(viewer: viewer, prs: prs, unavailable: unavailable, warnings: warnings)
    }
}

/// Diff side of a review comment.
/// Compact age of an ISO-8601 timestamp: "5m", "3h", "12d", "4mo", "2y". Empty if unparsable.
public func relativeAge(_ iso: String, now: Date = Date()) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    let s = max(0, Int(now.timeIntervalSince(date)))
    switch s {
    case ..<3600: return "\(max(1, s / 60))m"
    case ..<86400: return "\(s / 3600)h"
    case ..<(30 * 86400): return "\(s / 86400)d"
    case ..<(365 * 86400): return "\(s / (30 * 86400))mo"
    default: return "\(s / (365 * 86400))y"
    }
}

public enum Side: String, Sendable {
    case left = "LEFT", right = "RIGHT"
}

public enum ReviewEvent: String, Sendable {
    case approve = "APPROVE", requestChanges = "REQUEST_CHANGES", comment = "COMMENT"
}

public enum MergeMethod: String, Sendable {
    case merge = "MERGE", squash = "SQUASH", rebase = "REBASE"
}

public enum CheckStatus: Sendable {
    case success, neutral, failure, pending
}

public struct Check: Sendable {
    public let name: String
    public let state: String
    public let url: String?

    public var status: CheckStatus {
        switch state {
        case "SUCCESS": return .success
        case "NEUTRAL", "SKIPPED": return .neutral
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failure
        default: return .pending
        }
    }

    public var symbol: String {
        switch status {
        case .success: return "✓"
        case .neutral: return "○"
        case .failure: return "✗"
        case .pending: return "●"
        }
    }
}

public struct ReviewComment: Sendable {
    public let id: String
    public let author: String
    public var body: String
    public let canEdit: Bool

    public init(id: String, author: String, body: String, canEdit: Bool) {
        self.id = id
        self.author = author
        self.body = body
        self.canEdit = canEdit
    }
}

public struct ReviewThread: Sendable {
    public let id: String
    public let path: String
    public let line: Int
    public let side: Side
    public let resolved: Bool
    public let resolvedBy: String?
    public var comments: [ReviewComment]

    public init(id: String, path: String, line: Int, side: Side, resolved: Bool, resolvedBy: String?,
                comments: [ReviewComment]) {
        self.id = id
        self.resolvedBy = resolvedBy
        self.path = path
        self.line = line
        self.side = side
        self.resolved = resolved
        self.comments = comments
    }
}

public struct PRDetail: Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let url: String
    /// Head commit the loaded diff and threads belong to.
    public let headSha: String
    public let mergeable: String
    /// Commits on the base branch that the PR head lacks (0 = up to date).
    public let behindBy: Int
    public let reviewDecision: String?
    /// Merge method and enabler when auto-merge is on, e.g. "SQUASH by @bob".
    public let autoMerge: String?
    public let headOwner: String
    /// First line of each commit message (up to 100), oldest first.
    public let commitHeadlines: [String]
    /// Message body of each commit, parallel to `commitHeadlines`.
    public let commitBodies: [String]
    public let commitCount: Int
    public let checks: [Check]
    public let threads: [ReviewThread]
    public let pendingReviewId: String?
    /// Commit the pending review is attached to; submitting it approves that commit.
    public let pendingReviewCommit: String?
    public let viewer: String
}

/// GraphQL variable values (kept Sendable, unlike [String: Any]).
public indirect enum GQLValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case object([String: GQLValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct GQLBody: Encodable { let query: String; let variables: [String: GQLValue] }
struct GQLError: Decodable { let message: String }
struct GQLResponse<T: Decodable>: Decodable { let data: T?; let errors: [GQLError]? }

struct Login: Decodable { let login: String? }
struct IDNode: Decodable { let id: String }
struct Nodes<T: Decodable>: Decodable { let nodes: [T?] }

public struct GitHub: Sendable {
    let token: String

    public init(token: String) { self.token = token }

    /// `gh auth token --user account` when `account` is set, else `GITHUB_TOKEN`, else gh's active account.
    public static func loadToken(account: String = "", env: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if account.isEmpty, let t = env["GITHUB_TOKEN"], !t.isEmpty { return t }
        let (status, data) = try runGh(["auth", "token"] + (account.isEmpty ? [] : ["--user", account]), env: env)
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !token.isEmpty else { throw GitHubError.noToken("`gh auth token\(account.isEmpty ? "" : " --user \(account)")` failed") }
        return token
    }

    /// Logins gh knows for github.com, from `gh auth status --json hosts`; empty when gh is missing or too old for `--json`.
    public static func ghAccounts(env: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard let (_, data) = try? runGh(["auth", "status", "--json", "hosts"], env: env) else { return [] }
        return parseAccounts(data)
    }

    static func parseAccounts(_ data: Data) -> [String] {
        struct Out: Decodable { struct A: Decodable { let login: String }; let hosts: [String: [A]] }
        return (try? JSONDecoder().decode(Out.self, from: data))?.hosts["github.com"]?.map(\.login) ?? []
    }

    /// GUI apps don't inherit the shell PATH, so common gh locations are tried.
    private static func runGh(_ args: [String], env: [String: String]) throws -> (Int32, Data) {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + (env["PATH"] ?? "").split(separator: ":").map(String.init)
        guard let gh = dirs.map({ $0 + "/gh" }).first(where: FileManager.default.isExecutableFile) else {
            throw GitHubError.noToken("gh not found")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    private func send(_ req: URLRequest) async throws -> Data {
        var req = req
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("seer", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitHubError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    func graphQL<T: Decodable>(_ query: String, _ vars: [String: GQLValue] = [:], as: T.Type,
                               partial: Bool = false) async throws -> (data: T, errors: [String]) {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(GQLBody(query: query, variables: vars))
        return try Self.decode(try await send(req), as: T.self, partial: partial)
    }

    func graphQL<T: Decodable>(_ query: String, _ vars: [String: GQLValue] = [:], as: T.Type) async throws -> T {
        try await graphQL(query, vars, as: T.self, partial: false).data
    }

    /// With `partial`, data GitHub returned alongside errors (e.g. one missing repo) is kept and the messages returned.
    static func decode<T: Decodable>(_ data: Data, as: T.Type, partial: Bool) throws -> (data: T, errors: [String]) {
        let resp: GQLResponse<T>
        do {
            resp = try JSONDecoder().decode(GQLResponse<T>.self, from: data)
        } catch {
            throw GitHubError.decode("\(error)")
        }
        let errs = resp.errors?.map(\.message) ?? []
        if let d = resp.data, partial || errs.isEmpty { return (d, errs) }
        if !errs.isEmpty { throw GitHubError.graphQL(errs) }
        throw GitHubError.decode("no data")
    }

    // MARK: PR list

    /// "org/slug" (lowercased) of the teams `viewer` belongs to. Best effort: orgs that fail to load are skipped.
    func teams(of viewer: String, owners: Set<String>) async -> Set<String> {
        struct Org: Decodable { struct T: Decodable { let slug: String }; let teams: Nodes<T> }
        var out = Set<String>()
        for owner in owners {
            let q = "query($u: String!) { organization(login: \"\(owner)\") { teams(first: 100, userLogins: [$u]) { nodes { slug } } } }"
            struct D: Decodable { let organization: Org? }
            if let d = try? await graphQL(q, ["u": .string(viewer)], as: D.self) {
                for t in d.organization?.teams.nodes ?? [] { if let t { out.insert("\(owner)/\(t.slug)".lowercased()) } }
            }
        }
        return out
    }

    private struct RawPR: Decodable {
        struct RR: Decodable { struct R: Decodable { let login: String?; let slug: String?; let organization: Login? }; let requestedReviewer: R? }
        let state: String, number: Int, title: String, url: String, isDraft: Bool, createdAt: String, updatedAt: String, headRefOid: String, reviewDecision: String?, headRefName: String, baseRefName: String
        let author: Login?
        let additions: Int, deletions: Int
        let reviewRequests: Nodes<RR>

        static let fields = """
        state number title url isDraft createdAt updatedAt headRefOid reviewDecision headRefName baseRefName author { login } additions deletions
        reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { slug organization { login } } } } }
        """

        func summary(_ repo: Repo, viewer: String, myTeams: Set<String>) -> PRSummary {
            let requested = reviewRequests.nodes.contains {
                guard let r = $0?.requestedReviewer else { return false }
                if let slug = r.slug, let org = r.organization?.login { return myTeams.contains("\(org)/\(slug)".lowercased()) }
                return r.login == viewer
            }
            return PRSummary(repo: repo, number: number, title: title, url: url,
                             author: author?.login ?? "ghost", isDraft: isDraft, createdAt: createdAt, updatedAt: updatedAt, headSha: headRefOid, isApproved: reviewDecision == "APPROVED", changesRequested: reviewDecision == "CHANGES_REQUESTED",
                             headRef: headRefName, baseRef: baseRefName,
                             reviewRequested: requested, additions: additions, deletions: deletions)
        }
    }

    /// Fresh summary of one PR, or nil when it is no longer open.
    public func refreshPR(_ pr: PRSummary, viewer: String) async throws -> PRSummary? {
        struct Data: Decodable { struct R: Decodable { let pullRequest: RawPR }; let repository: R }
        let q = "query($o: String!, $n: String!, $num: Int!) { repository(owner: $o, name: $n) { pullRequest(number: $num) { \(RawPR.fields) } } }"
        let vars: [String: GQLValue] = ["o": .string(pr.repo.owner), "n": .string(pr.repo.name), "num": .int(pr.number)]
        let raw = try await graphQL(q, vars, as: Data.self).repository.pullRequest
        guard raw.state == "OPEN" else { return nil }
        return raw.summary(pr.repo, viewer: viewer, myTeams: await teams(of: viewer, owners: [pr.repo.owner]))
    }

    public func listPRs(_ repos: [Repo]) async throws -> PRList {
        struct RawRepo: Decodable { let pullRequests: Nodes<RawPR> }
        struct Data: Decodable {
            let viewer: String
            let repos: [String: RawRepo?]
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: DynamicKey.self)
                viewer = try c.decode(Login.self, forKey: DynamicKey(stringValue: "viewer")).login ?? ""
                var r: [String: RawRepo?] = [:]
                for k in c.allKeys where k.stringValue != "viewer" { r[k.stringValue] = try c.decode(RawRepo?.self, forKey: k) }
                repos = r
            }
        }
        // Repo names are validated by Config to [A-Za-z0-9._-], so inlining them is safe.
        let fields = repos.enumerated().map { i, r in
            """
            r\(i): repository(owner: "\(r.owner)", name: "\(r.name)") {
              pullRequests(states: OPEN, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
                nodes { \(RawPR.fields) }
              }
            }
            """
        }.joined(separator: "\n")
        let (d, warnings) = try await graphQL("query { viewer { login }\n\(fields)\n}", as: Data.self, partial: true)
        let myTeams = await teams(of: d.viewer, owners: Set(repos.map(\.owner)))
        var prs: [PRSummary] = []
        var unavailable: [Repo] = []
        for (i, repo) in repos.enumerated() {
            guard let raw = d.repos["r\(i)"] ?? nil else {
                unavailable.append(repo)
                continue
            }
            for case let pr? in raw.pullRequests.nodes {
                prs.append(pr.summary(repo, viewer: d.viewer, myTeams: myTeams))
            }
        }
        return PRList(viewer: d.viewer, prs: prs, unavailable: unavailable, warnings: warnings)
    }

    // MARK: PR detail

    /// Current head commit of `pr` on GitHub.
    public func headSha(_ pr: PRSummary) async throws -> String {
        struct D: Decodable {
            struct R: Decodable { struct P: Decodable { let headRefOid: String }; let pullRequest: P }
            let repository: R
        }
        let q = "query($o: String!, $n: String!, $num: Int!) { repository(owner: $o, name: $n) { pullRequest(number: $num) { headRefOid } } }"
        return try await graphQL(q, ["o": .string(pr.repo.owner), "n": .string(pr.repo.name), "num": .int(pr.number), "sha": .string(pr.headSha)],
                                 as: D.self).repository.pullRequest.headRefOid
    }

    public func diff(_ pr: PRSummary) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(pr.repo.full)/pulls/\(pr.number)")!)
        req.setValue("application/vnd.github.diff", forHTTPHeaderField: "Accept")
        return String(decoding: try await send(req), as: UTF8.self)
    }

    public func detail(_ pr: PRSummary) async throws -> PRDetail {
        struct Ctx: Decodable {
            let __typename: String
            let name: String?, status: String?, conclusion: String?, detailsUrl: String?
            let context: String?, state: String?, targetUrl: String?
        }
        struct Rollup: Decodable { let contexts: Nodes<Ctx> }
        struct Commit: Decodable { struct C: Decodable { let statusCheckRollup: Rollup? }; let commit: C }
        struct Comment: Decodable { let id: String; let author: Login?; let body: String; let viewerCanUpdate: Bool }
        struct Thread: Decodable {
            let id: String, path: String, line: Int?, diffSide: String, isResolved: Bool
            let resolvedBy: Login?
            let comments: Nodes<Comment>
        }
        struct Review: Decodable { struct C: Decodable { let oid: String }; let id: String; let author: Login?; let commit: C? }
        struct PR: Decodable {
            let id: String, title: String, body: String, url: String, headRefOid: String, mergeable: String, reviewDecision: String?
            struct Auto: Decodable { let mergeMethod: String; let enabledBy: Login? }
            let autoMergeRequest: Auto?
            struct Base: Decodable { struct Cmp: Decodable { let behindBy: Int }; let compare: Cmp? }
            let baseRef: Base?
            let headRepositoryOwner: Login?
            struct Msg: Decodable { struct C: Decodable { let messageHeadline: String; let messageBody: String }; let commit: C }
            struct All: Decodable { let totalCount: Int; let nodes: [Msg?] }
            let allCommits: All
            let commits: Nodes<Commit>
            let reviewThreads: Nodes<Thread>
            let reviews: Nodes<Review>
        }
        struct Repo: Decodable { let pullRequest: PR }
        struct Data: Decodable { let viewer: Login; let repository: Repo }
        let q = """
        query($o: String!, $n: String!, $num: Int!, $sha: String!) {
          viewer { login }
          repository(owner: $o, name: $n) { pullRequest(number: $num) {
            id title body url headRefOid mergeable reviewDecision
            autoMergeRequest { mergeMethod enabledBy { login } }
            baseRef { compare(headRef: $sha) { behindBy } }
            headRepositoryOwner { login }
            allCommits: commits(first: 100) { totalCount nodes { commit { messageHeadline messageBody } } }
            commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
              __typename
              ... on CheckRun { name status conclusion detailsUrl }
              ... on StatusContext { context state targetUrl }
            } } } } } }
            reviewThreads(first: 100) { nodes { id path line diffSide isResolved resolvedBy { login }
              comments(first: 50) { nodes { id author { login } body viewerCanUpdate } } } }
            reviews(states: PENDING, first: 10) { nodes { id author { login } commit { oid } } }
          } }
        }
        """
        let d = try await graphQL(q, ["o": .string(pr.repo.owner), "n": .string(pr.repo.name), "num": .int(pr.number), "sha": .string(pr.headSha)],
                                  as: Data.self)
        let p = d.repository.pullRequest
        let viewer = d.viewer.login ?? ""
        let ctxs = p.commits.nodes.last??.commit.statusCheckRollup?.contexts.nodes.compactMap { $0 } ?? []
        let checks = ctxs.map { c -> Check in
            if c.__typename == "CheckRun" {
                let state = c.status == "COMPLETED" ? (c.conclusion ?? "NEUTRAL") : "PENDING"
                return Check(name: c.name ?? "?", state: state, url: c.detailsUrl)
            }
            return Check(name: c.context ?? "?", state: c.state ?? "PENDING", url: c.targetUrl)
        }
        let threads = p.reviewThreads.nodes.compactMap { t -> ReviewThread? in
            guard let t, let line = t.line else { return nil }
            return ReviewThread(id: t.id, path: t.path, line: line, side: Side(rawValue: t.diffSide) ?? .right,
                                resolved: t.isResolved,
                                resolvedBy: t.resolvedBy?.login,
                                comments: t.comments.nodes.compactMap { $0.map {
                                    ReviewComment(id: $0.id, author: $0.author?.login ?? "ghost", body: $0.body,
                                                  canEdit: $0.viewerCanUpdate)
                                } })
        }
        let pending = p.reviews.nodes.first { $0?.author?.login == viewer } ?? nil
        return PRDetail(id: p.id, title: p.title, body: p.body, url: p.url, headSha: p.headRefOid, mergeable: p.mergeable, behindBy: p.baseRef?.compare?.behindBy ?? 0,
                        reviewDecision: p.reviewDecision,
                        autoMerge: p.autoMergeRequest.map { "\($0.mergeMethod)" + ($0.enabledBy?.login.map { " by @\($0)" } ?? "") },
                        headOwner: p.headRepositoryOwner?.login ?? pr.repo.owner,
                        commitHeadlines: p.allCommits.nodes.compactMap { $0?.commit.messageHeadline },
                        commitBodies: p.allCommits.nodes.compactMap { $0?.commit.messageBody },
                        commitCount: p.allCommits.totalCount,
                        checks: checks, threads: threads, pendingReviewId: pending?.id,
                        pendingReviewCommit: pending?.commit?.oid, viewer: viewer)
    }

    /// Blob texts by (abbreviated) SHA. Binary and >1 MB blobs are left out.
    public func blobs(_ repo: Repo, shas: [String]) async throws -> [String: String] {
        struct Blob: Decodable { let text: String?; let byteSize: Int?; let isBinary: Bool? }
        struct R: Decodable {
            let objs: [String: Blob?]
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: DynamicKey.self)
                var o: [String: Blob?] = [:]
                for k in c.allKeys { o[k.stringValue] = try c.decode(Blob?.self, forKey: k) }
                objs = o
            }
        }
        struct Data: Decodable { let repository: R }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        let unique = Array(Set(shas.filter { $0.unicodeScalars.allSatisfy(hex.contains) }))
        var out: [String: String] = [:]
        for start in stride(from: 0, to: unique.count, by: 40) {
            let chunk = Array(unique[start..<min(start + 40, unique.count)])
            let fields = chunk.enumerated().map { i, sha in
                "b\(i): object(expression: \"\(sha)\") { ... on Blob { text byteSize isBinary } }"
            }.joined(separator: "\n")
            let d = try await graphQL("query($o: String!, $n: String!) { repository(owner: $o, name: $n) {\n\(fields)\n} }",
                                      ["o": .string(repo.owner), "n": .string(repo.name)], as: Data.self)
            for (i, sha) in chunk.enumerated() {
                guard let b = d.repository.objs["b\(i)"] ?? nil, b.isBinary != true, (b.byteSize ?? 0) <= 1_000_000,
                      let t = b.text else { continue }
                out[sha] = t
            }
        }
        return out
    }

    // MARK: Reviews

    /// Starts a pending review on `commit`, so later comments and an approval refer to the code that was reviewed.
    public func addReview(prId: String, commit: String) async throws -> String {
        struct D: Decodable {
            struct A: Decodable { struct R: Decodable { let id: String }; let pullRequestReview: R }
            let addPullRequestReview: A
        }
        let q = """
        mutation($id: ID!, $sha: GitObjectID!) {
          addPullRequestReview(input: {pullRequestId: $id, commitOID: $sha}) { pullRequestReview { id } }
        }
        """
        return try await graphQL(q, ["id": .string(prId), "sha": .string(commit)], as: D.self)
            .addPullRequestReview.pullRequestReview.id
    }

    /// Returns the new thread's id and its first comment's id.
    public func addThread(reviewId: String, path: String, line: Int, side: Side,
                          startLine: Int?, startSide: Side?, body: String) async throws -> (thread: String, comment: String) {
        struct D: Decodable {
            struct A: Decodable {
                struct T: Decodable { let id: String; let comments: Nodes<IDNode> }
                let thread: T
            }
            let addPullRequestReviewThread: A
        }
        var input: [String: GQLValue] = [
            "pullRequestReviewId": .string(reviewId), "path": .string(path), "line": .int(line),
            "side": .string(side.rawValue), "body": .string(body),
        ]
        if let startLine, let startSide {
            input["startLine"] = .int(startLine)
            input["startSide"] = .string(startSide.rawValue)
        }
        let q = """
        mutation($in: AddPullRequestReviewThreadInput!) {
          addPullRequestReviewThread(input: $in) { thread { id comments(first: 1) { nodes { id } } } }
        }
        """
        let t = try await graphQL(q, ["in": .object(input)], as: D.self).addPullRequestReviewThread.thread
        guard let c = t.comments.nodes.first??.id else { throw GitHubError.decode("thread without comment") }
        return (t.id, c)
    }

    /// Adds a reply to an existing thread as part of the pending review `reviewId`; returns the comment id.
    public func reply(threadId: String, reviewId: String, body: String) async throws -> String {
        struct D: Decodable {
            struct A: Decodable { let comment: IDNode }
            let addPullRequestReviewThreadReply: A
        }
        let q = """
        mutation($t: ID!, $r: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $t, pullRequestReviewId: $r, body: $body}) {
            comment { id }
          }
        }
        """
        return try await graphQL(q, ["t": .string(threadId), "r": .string(reviewId), "body": .string(body)], as: D.self)
            .addPullRequestReviewThreadReply.comment.id
    }

    public func editComment(id: String, body: String) async throws {
        struct D: Decodable {}
        let q = """
        mutation($id: ID!, $body: String!) {
          updatePullRequestReviewComment(input: {pullRequestReviewCommentId: $id, body: $body}) { pullRequestReviewComment { id } }
        }
        """
        _ = try await graphQL(q, ["id": .string(id), "body": .string(body)], as: D.self)
    }

    /// A non-empty `comment` is posted first, so a failed close retried from the modal may repeat it.
    public func closePR(id: String, comment: String = "") async throws {
        struct D: Decodable {}
        if !comment.isEmpty {
            let c = "mutation($id: ID!, $b: String!) { addComment(input: {subjectId: $id, body: $b}) { clientMutationId } }"
            _ = try await graphQL(c, ["id": .string(id), "b": .string(comment)], as: D.self)
        }
        let q = "mutation($id: ID!) { closePullRequest(input: {pullRequestId: $id}) { pullRequest { state } } }"
        _ = try await graphQL(q, ["id": .string(id)], as: D.self)
    }

    /// Fails if the head is no longer `expectedHead`. A nil headline/body lets GitHub use its default message.
    public func mergePR(id: String, method: MergeMethod, expectedHead: String, headline: String?, body: String?) async throws {
        struct D: Decodable {}
        let q = """
        mutation($id: ID!, $m: PullRequestMergeMethod!, $sha: GitObjectID!, $h: String, $b: String) {
          mergePullRequest(input: {pullRequestId: $id, mergeMethod: $m, expectedHeadOid: $sha,
                                   commitHeadline: $h, commitBody: $b}) { pullRequest { state } }
        }
        """
        _ = try await graphQL(q, ["id": .string(id), "m": .string(method.rawValue), "sha": .string(expectedHead),
                                  "h": headline.map(GQLValue.string) ?? .null, "b": body.map(GQLValue.string) ?? .null], as: D.self)
    }

    public func submitReview(reviewId: String, event: ReviewEvent, body: String) async throws {
        struct D: Decodable {}
        let q = """
        mutation($id: ID!, $ev: PullRequestReviewEvent!, $body: String) {
          submitPullRequestReview(input: {pullRequestReviewId: $id, event: $ev, body: $body}) { pullRequestReview { id } }
        }
        """
        _ = try await graphQL(q, ["id": .string(reviewId), "ev": .string(event.rawValue), "body": body.isEmpty ? .null : .string(body)],
                              as: D.self)
    }
}

public enum PRCache {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("seer/prs.json")
    }

    public static func load() -> PRList? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PRList.self, from: d)
    }

    public static func save(_ list: PRList) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(list).write(to: url, options: .atomic)
    }
}
