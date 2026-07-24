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
        rules.insert(Rule(sessionId: session, toolName: tool, pattern: RulePattern.derive(payload)))
    }

    func matches(_ payload: HookPayload) -> Bool {
        guard let session = payload.sessionId, let tool = payload.toolName else { return false }
        return rules.contains(Rule(sessionId: session, toolName: tool, pattern: RulePattern.derive(payload)))
    }

    func clearSession(_ sessionId: String) {
        rules = rules.filter { $0.sessionId != sessionId }
    }

    func clearAll() { rules.removeAll() }

    var count: Int { rules.count }
}
