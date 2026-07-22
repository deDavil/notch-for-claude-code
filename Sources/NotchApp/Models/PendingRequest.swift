import Foundation

/// One in-flight permission request the operator must resolve. Holds the parsed
/// payload, a display summary, and the continuation that answers the parked
/// HTTP response once a decision arrives.
final class PendingRequest: Identifiable {
    let id = UUID()
    let payload: HookPayload
    let summary: ToolSummary
    let receivedAt: Date

    /// Called exactly once when the request is resolved; writes the hook body
    /// (or nil for no-opinion) back to the waiting connection. The store guards
    /// one-shot semantics, but this is also idempotent-safe.
    private var respond: ((Data?) -> Void)?

    init(payload: HookPayload, receivedAt: Date, respond: @escaping (Data?) -> Void) {
        self.payload = payload
        self.summary = ToolSummary.make(from: payload)
        self.receivedAt = receivedAt
        self.respond = respond
    }

    var sessionId: String { payload.sessionId ?? "" }
    var sessionLabel: String { payload.sessionLabel }

    /// Fulfil the parked HTTP response. Safe to call once; subsequent calls no-op.
    func fulfil(with body: Data?) {
        guard let r = respond else { return }
        respond = nil
        r(body)
    }
}
