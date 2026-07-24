import Foundation

/// Live state of a Claude Code session, as inferred from its hook stream.
enum SessionState: String {
    case working          // Claude is processing (after a prompt, before Stop)
    case waitingApproval  // a permission decision is pending
    case waitingInput     // idle_prompt — waiting for the user to say something
    case idle             // finished responding, nothing pending

    var label: String {
        switch self {
        case .working: return "working"
        case .waitingApproval: return "needs approval"
        case .waitingInput: return "waiting for you"
        case .idle: return "idle"
        }
    }
    /// Sort/priority rank — lower = more urgent, shown first.
    var rank: Int {
        switch self {
        case .waitingApproval: return 0
        case .waitingInput: return 1
        case .working: return 2
        case .idle: return 3
        }
    }
}

struct SessionInfo: Identifiable {
    let id: String            // session_id
    var label: String         // cwd basename
    var cwd: String?
    var baseState: SessionState
    var pending: Int          // outstanding permission requests
    var lastActivity: Date
    /// Hosting GUI app (Terminal / iTerm / VS Code …), from the notify hook's
    /// process-ancestry walk. Enables cockpit jump-to-session.
    var hostPid: Int?
    var hostApp: String?      // display name derived from host_comm

    /// A pending approval always outranks the event-derived base state.
    var displayState: SessionState { pending > 0 ? .waitingApproval : baseState }
}
