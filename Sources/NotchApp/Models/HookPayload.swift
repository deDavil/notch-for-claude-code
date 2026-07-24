import Foundation

/// The JSON Claude Code sends on stdin for a hook, forwarded verbatim by the
/// hook script into POST /v1/permission or /v1/notify. Only the fields we use
/// are decoded; unknown fields are ignored (and `toolInput` is kept as raw
/// JSONValue so we can echo it back on "allow").
struct HookPayload: Codable, Sendable {
    let hookEventName: String?
    let sessionId: String?
    let cwd: String?
    let permissionMode: String?
    let transcriptPath: String?

    // Tool events (PermissionRequest / PreToolUse)
    let toolName: String?
    let toolInput: JSONValue?
    let toolUseId: String?

    // Notification / Stop
    let notificationType: String?
    let message: String?
    let lastAssistantMessage: String?

    // Hosting GUI app, attached by notch-notify.sh from process ancestry.
    let hostPid: Int?
    let hostComm: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case permissionMode = "permission_mode"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case hostPid = "host_pid"
        case hostComm = "host_comm"
    }

    /// A short, human label for the session: the basename of its cwd, else a
    /// truncated session id.
    var sessionLabel: String {
        if let cwd, !cwd.isEmpty {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty { return base }
        }
        if let sessionId, !sessionId.isEmpty {
            return String(sessionId.prefix(8))
        }
        return "session"
    }
}
