import Foundation

/// Shared derivation of the match key an allow-rule stores for a tool call.
/// Conservative on purpose: Bash keys on the first command token, file tools on
/// the exact path, everything else on the tool name.
enum RulePattern {
    static func derive(_ payload: HookPayload) -> String {
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
