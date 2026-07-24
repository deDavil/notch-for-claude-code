import Foundation
import Combine

/// The core arbiter. Holds the FIFO queue of pending permission requests and
/// resolves each exactly once — whichever input (notch click, hotkey, Telegram
/// tap, timeout, or client-drop) arrives first wins. Answers the parked HTTP
/// response with the correct hook JSON on resolve.
@MainActor
final class RequestStore: ObservableObject {
    @Published private(set) var pending: [PendingRequest] = []
    @Published private(set) var toast: Toast?
    /// Privacy pause: while true, every request falls straight through to the
    /// terminal (noOpinion), nothing is displayed or announced anywhere.
    @Published var paused = false
    /// Auto-pause driven by MicMonitor (operator is on a call). Same effect as
    /// `paused`, tracked separately so resuming a call doesn't clear a manual pause.
    @Published var autoPaused = false

    var effectivePaused: Bool { paused || autoPaused }

    private let settings: AppSettings
    private var timeouts: [UUID: DispatchWorkItem] = [:]
    private var toastClear: DispatchWorkItem?

    /// Notifications for presentation layers (notch UI, Telegram relay). `decision`
    /// is nil when the request went away without a verdict (client dropped).
    var onEnqueue: ((PendingRequest) -> Void)?
    var onResolve: ((PendingRequest, Decision?, DecisionSource) -> Void)?
    /// Fired on EVERY terminal outcome — including auto-allow short-circuits and
    /// client drops, which never reach onResolve/onEnqueue respectively. Audit hook.
    var onOutcome: ((PendingRequest, Decision?, DecisionSource) -> Void)?

    var autoAllow: AutoAllowStore?
    var projectRules: ProjectRuleStore?

    init(settings: AppSettings) {
        self.settings = settings
    }

    var frontRequest: PendingRequest? { pending.first }

    /// Register a new permission request. If an auto-allow rule matches, it is
    /// resolved immediately and never shown. Returns the request id (nil if it
    /// was auto-resolved and never enqueued).
    @discardableResult
    func enqueue(payload: HookPayload, respond: @escaping (Data?) -> Void) -> UUID? {
        let request = PendingRequest(payload: payload, receivedAt: Date(), respond: respond)

        // Privacy pause: silently hand the decision back to the terminal.
        // Checked BEFORE auto-allow so nothing at all happens on this machine's
        // screen or the phone while paused.
        if effectivePaused {
            request.fulfil(with: nil)
            onOutcome?(request, .noOpinion, .paused)
            return nil
        }

        let sessionHit = autoAllow?.matches(payload) ?? false
        let projectHit = projectRules?.matches(payload) ?? false
        if sessionHit || projectHit {
            Log.store.info("auto-allow (\(projectHit ? "project" : "session", privacy: .public)) for \(payload.toolName ?? "?", privacy: .public)")
            let body = HookResponse.body(for: .allow, payload: payload)
            request.fulfil(with: body)
            onOutcome?(request, .allow, .autoAllow)
            return nil
        }

        pending.append(request)
        scheduleTimeout(for: request)
        Log.store.info("enqueued \(request.sessionLabel, privacy: .public) tool=\(payload.toolName ?? "?", privacy: .public) pending=\(self.pending.count)")
        onEnqueue?(request)
        return request.id
    }

    /// Resolve a request by id. Idempotent: only the first call for a given id
    /// takes effect; later calls (races between devices) are ignored.
    @discardableResult
    func resolve(id: UUID, decision: Decision, source: DecisionSource) -> Bool {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return false }
        let request = pending.remove(at: idx)
        cancelTimeout(id: id)

        if case .allowForSession = decision {
            autoAllow?.remember(payload: request.payload)
        }
        if case .allowForProject = decision {
            projectRules?.remember(payload: request.payload)
        }

        let body = HookResponse.body(for: decision, payload: request.payload)
        request.fulfil(with: body)
        Log.store.info("resolved \(request.sessionLabel, privacy: .public) via \(source.rawValue, privacy: .public) pending=\(self.pending.count)")
        onResolve?(request, decision, source)
        onOutcome?(request, decision, source)
        return true
    }

    /// The peer closed before answering (session Ctrl-C'd). Drop the card without
    /// writing a response — the connection is already gone.
    func clientDropped(id: UUID) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: idx)
        cancelTimeout(id: id)
        Log.store.info("client dropped \(request.sessionLabel, privacy: .public) pending=\(self.pending.count)")
        onResolve?(request, nil, .clientDropped)
        onOutcome?(request, nil, .clientDropped)
    }

    /// When a session Stops, clear its auto-allow rules (scope = one session).
    func sessionStopped(sessionId: String) {
        autoAllow?.clearSession(sessionId)
    }

    /// Show a passive toast for a few seconds (suppressed while a card is up
    /// and while paused).
    func showToast(_ toast: Toast?, duration: TimeInterval = 4) {
        guard let toast, !effectivePaused else { return }
        self.toast = toast
        toastClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Timeout

    private func scheduleTimeout(for request: PendingRequest) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resolve(id: request.id, decision: .noOpinion, source: .timeout)
        }
        timeouts[request.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.answerTimeout, execute: work)
    }

    private func cancelTimeout(id: UUID) {
        timeouts[id]?.cancel()
        timeouts[id] = nil
    }
}
