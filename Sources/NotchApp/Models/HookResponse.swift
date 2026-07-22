import Foundation

/// Builds the exact stdout JSON Claude Code expects from a hook, given the
/// decision and the originating event. Schema verified against the CLI's own
/// consumer (see notch/README.md → "Verified hook facts").
enum HookResponse {
    /// Returns the JSON body (as Data) to write back to the hook script, or nil
    /// for "no opinion" (empty body → Claude shows its own prompt).
    static func body(for decision: Decision, payload: HookPayload) -> Data? {
        let event = payload.hookEventName ?? "PermissionRequest"
        switch decision {
        case .noOpinion:
            return nil
        case .allow, .allowForSession:
            return allow(event: event, toolInput: payload.toolInput)
        case .answer(let answers):
            // Approve AskUserQuestion with the chosen answers merged into the input.
            let merged = mergeAnswers(into: payload.toolInput, answers: answers)
            return allow(event: event, toolInput: merged)
        case .deny(let reason):
            return deny(event: event, reason: reason)
        }
    }

    /// Merge `answers` (question text → label) into the tool input's `answers` map.
    private static func mergeAnswers(into input: JSONValue?, answers: [String: String]) -> JSONValue {
        var obj: [String: JSONValue] = {
            if case .object(let o)? = input { return o }
            return [:]
        }()
        var answerMap: [String: JSONValue] = {
            if case .object(let a)? = obj["answers"] { return a }
            return [:]
        }()
        for (q, a) in answers { answerMap[q] = .string(a) }
        obj["answers"] = .object(answerMap)
        return .object(obj)
    }

    private static func allow(event: String, toolInput: JSONValue?) -> Data? {
        switch event {
        case "PreToolUse":
            let out = HookSpecificOutput(
                hookEventName: "PreToolUse",
                permissionDecision: "allow",
                permissionDecisionReason: "Approved via notch overlay",
                decision: nil)
            return encode(Envelope(hookSpecificOutput: out))
        default: // PermissionRequest
            let decision = PermDecision(
                behavior: "allow",
                updatedInput: toolInput,
                message: nil)
            let out = HookSpecificOutput(
                hookEventName: "PermissionRequest",
                permissionDecision: nil,
                permissionDecisionReason: nil,
                decision: decision)
            return encode(Envelope(hookSpecificOutput: out))
        }
    }

    private static func deny(event: String, reason: String) -> Data? {
        switch event {
        case "PreToolUse":
            let out = HookSpecificOutput(
                hookEventName: "PreToolUse",
                permissionDecision: "deny",
                permissionDecisionReason: reason,
                decision: nil)
            return encode(Envelope(hookSpecificOutput: out))
        default: // PermissionRequest
            let decision = PermDecision(
                behavior: "deny",
                updatedInput: nil,
                message: reason)
            let out = HookSpecificOutput(
                hookEventName: "PermissionRequest",
                permissionDecision: nil,
                permissionDecisionReason: nil,
                decision: decision)
            return encode(Envelope(hookSpecificOutput: out))
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let enc = JSONEncoder()
        return try? enc.encode(value)
    }

    // MARK: - Wire types

    private struct Envelope: Encodable {
        let hookSpecificOutput: HookSpecificOutput
    }

    private struct HookSpecificOutput: Encodable {
        let hookEventName: String
        let permissionDecision: String?
        let permissionDecisionReason: String?
        let decision: PermDecision?

        enum CodingKeys: String, CodingKey {
            case hookEventName, permissionDecision, permissionDecisionReason, decision
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(hookEventName, forKey: .hookEventName)
            try c.encodeIfPresent(permissionDecision, forKey: .permissionDecision)
            try c.encodeIfPresent(permissionDecisionReason, forKey: .permissionDecisionReason)
            try c.encodeIfPresent(decision, forKey: .decision)
        }
    }

    private struct PermDecision: Encodable {
        let behavior: String
        let updatedInput: JSONValue?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case behavior, updatedInput, message
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(behavior, forKey: .behavior)
            try c.encodeIfPresent(updatedInput, forKey: .updatedInput)
            try c.encodeIfPresent(message, forKey: .message)
        }
    }
}
