import Foundation

/// In-memory "allow for this session" rules. Never edits Claude settings.
/// A rule = (session_id, tool_name, derived pattern). Rules die with the app
/// process and are cleared when their session Stops.
@MainActor
final class AutoAllowStore {
    private struct Rule: Hashable {
        let sessionId: String
        let toolName: String
        let pattern: String
    }

    private var rules: Set<Rule> = []

    func remember(payload: HookPayload) {
        guard let session = payload.sessionId, let tool = payload.toolName else { return }
        rules.insert(Rule(sessionId: session, toolName: tool, pattern: Self.pattern(for: payload)))
    }

    func matches(_ payload: HookPayload) -> Bool {
        guard let session = payload.sessionId, let tool = payload.toolName else { return false }
        let pattern = Self.pattern(for: payload)
        return rules.contains(Rule(sessionId: session, toolName: tool, pattern: pattern))
    }

    func clearSession(_ sessionId: String) {
        rules = rules.filter { $0.sessionId != sessionId }
    }

    func clearAll() { rules.removeAll() }

    var count: Int { rules.count }

    /// Derive the match key from the tool input. Conservative: Bash keys on the
    /// first command token, file tools on the path, everything else on tool name.
    private static func pattern(for payload: HookPayload) -> String {
        let input = payload.toolInput
        switch payload.toolName {
        case "Bash":
            let cmd = input?["command"]?.stringValue ?? ""
            return cmd.split(separator: " ").first.map(String.init) ?? cmd
        case "Edit", "MultiEdit", "Write", "Read":
            return input?["file_path"]?.stringValue ?? ""
        default:
            return payload.toolName ?? ""
        }
    }
}
