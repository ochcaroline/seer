import Foundation

public enum ReviewBlock: Error, Equatable, CustomStringConvertible {
    /// The PR has commits that weren't loaded when it was reviewed.
    case newCommits
    /// The pending review was started on an older commit, so submitting it would approve that commit.
    case pendingOnOldCommit

    public var description: String {
        switch self {
        case .newCommits:
            return "PR has new commits since you loaded it. Press Shift+R and review them first."
        case .pendingOnOldCommit:
            return "Your pending review is on an older commit. Submit it as Comment or Request changes, then approve in a new review."
        }
    }
}

/// Review state of one opened PR. A new session per load keeps late async results from leaking into another PR.
@MainActor
public final class ReviewSession {
    public let pr: PRSummary
    public let detail: PRDetail
    public private(set) var pendingReviewId: String?
    private var pendingCommit: String?
    private var creating: Task<String, Error>?
    private let createReview: @Sendable (_ prId: String, _ commit: String) async throws -> String

    public init(pr: PRSummary, detail: PRDetail,
                createReview: @escaping @Sendable (_ prId: String, _ commit: String) async throws -> String) {
        self.pr = pr
        self.detail = detail
        pendingReviewId = detail.pendingReviewId
        pendingCommit = detail.pendingReviewCommit
        self.createReview = createReview
    }

    /// The pending review, created on the loaded head if there is none. Concurrent callers share one creation.
    public func ensureReview() async throws -> String {
        if let id = pendingReviewId { return id }
        if let t = creating { return try await t.value }
        let (prId, head, create) = (detail.id, detail.headSha, createReview)
        let t = Task { try await create(prId, head) }
        creating = t
        defer { creating = nil }
        let id = try await t.value
        pendingReviewId = id
        pendingCommit = head
        return id
    }

    public func submitted() {
        pendingReviewId = nil
        pendingCommit = nil
    }

    /// Throws unless the loaded commit is still the PR's head (and, when approving, the pending review is on it).
    public func checkCurrent(latestHead: String, approving: Bool) throws {
        if latestHead != detail.headSha { throw ReviewBlock.newCommits }
        if approving, let c = pendingCommit, c != detail.headSha { throw ReviewBlock.pendingOnOldCommit }
    }
}
