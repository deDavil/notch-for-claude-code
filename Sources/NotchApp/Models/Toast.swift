import Foundation

/// A transient passive notification (idle / session finished) shown under the
/// notch when nothing needs a decision.
struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let icon: String

    static func from(_ payload: HookPayload) -> Toast? {
        switch payload.hookEventName {
        case "Stop":
            return Toast(text: "\(payload.sessionLabel) finished", icon: "checkmark.circle")
        case "Notification":
            switch payload.notificationType {
            case "idle_prompt":
                return Toast(text: "\(payload.sessionLabel) is waiting for you", icon: "hourglass")
            case "permission_prompt":
                // A permission is pending but arrived via Notification, not the
                // blocking hook (e.g. already-answered elsewhere). Surface softly.
                return Toast(text: "\(payload.sessionLabel) needs permission", icon: "lock")
            default:
                if let msg = payload.message, !msg.isEmpty {
                    return Toast(text: msg, icon: "bell")
                }
                return nil
            }
        default:
            return nil
        }
    }
}
