import Foundation

/// Where a decision came from (for display + Telegram attribution).
enum DecisionSource: String, Sendable {
    case notch
    case hotkey
    case telegram
    case autoAllow
    case timeout
    case clientDropped
}

/// A resolved verdict on a pending permission request.
enum Decision: Sendable {
    /// Approve once.
    case allow
    /// Approve and remember an auto-allow rule for this session.
    case allowForSession
    /// Deny with a message shown to Claude.
    case deny(reason: String)
    /// No opinion — respond with empty body so Claude falls back to its own prompt.
    case noOpinion
}
