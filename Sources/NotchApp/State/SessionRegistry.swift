import Foundation
import Combine

/// Tracks every known Claude Code session and its live state, driven by the
/// hook stream (SessionStart / UserPromptSubmit / Stop / SessionEnd / idle
/// notifications) plus the permission queue. Powers the notch cockpit.
@MainActor
final class SessionRegistry: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    /// User toggled the cockpit open by clicking the collapsed pill.
    @Published var cockpitOpen = false

    /// Idle sessions with no activity for this long are pruned.
    private let staleAfter: TimeInterval = 30 * 60
    private var pruneTimer: Timer?

    init() {
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
    }

    /// Sessions ordered by urgency then recency.
    var ordered: [SessionInfo] {
        sessions.sorted { a, b in
            if a.displayState.rank != b.displayState.rank {
                return a.displayState.rank < b.displayState.rank
            }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Aggregate state for the collapsed pill dot (nil when no sessions).
    var aggregate: SessionState? {
        for s in [SessionState.waitingApproval, .waitingInput, .working, .idle] {
            if sessions.contains(where: { $0.displayState == s }) { return s }
        }
        return nil
    }

    // MARK: - Event ingestion (from /v1/notify)

    func noteEvent(_ p: HookPayload) {
        guard let sid = p.sessionId else { return }
        if p.hookEventName == "SessionEnd" {
            sessions.removeAll { $0.id == sid }
            return
        }
        var s = session(for: sid, seed: p)
        if let cwd = p.cwd, !cwd.isEmpty { s.cwd = cwd; s.label = p.sessionLabel }
        s.lastActivity = Date()
        switch p.hookEventName {
        case "SessionStart": s.baseState = .idle
        case "UserPromptSubmit": s.baseState = .working
        case "Stop": s.baseState = .idle
        case "Notification":
            if p.notificationType == "idle_prompt" { s.baseState = .waitingInput }
        default: break
        }
        upsert(s)
        prune()
    }

    // MARK: - Permission linkage (from the blocking queue)

    func incPending(_ p: HookPayload) {
        guard let sid = p.sessionId else { return }
        var s = session(for: sid, seed: p)
        s.pending += 1
        s.lastActivity = Date()
        upsert(s)
    }

    func decPending(_ p: HookPayload) {
        guard let sid = p.sessionId, var s = sessions.first(where: { $0.id == sid }) else { return }
        s.pending = max(0, s.pending - 1)
        s.lastActivity = Date()
        upsert(s)
    }

    // MARK: -

    private func session(for id: String, seed p: HookPayload) -> SessionInfo {
        sessions.first(where: { $0.id == id })
            ?? SessionInfo(id: id, label: p.sessionLabel, cwd: p.cwd,
                           baseState: .idle, pending: 0, lastActivity: Date())
    }

    private func upsert(_ s: SessionInfo) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        else { sessions.append(s) }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        sessions.removeAll { $0.pending == 0 && $0.displayState == .idle && $0.lastActivity < cutoff }
    }
}
