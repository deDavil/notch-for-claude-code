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

    private let settings: AppSettings
    private var timeouts: [UUID: DispatchWorkItem] = [:]
    private var toastClear: DispatchWorkItem?

    /// Notifications for presentation layers (notch UI, Telegram relay). `decision`
    /// is nil when the request went away without a verdict (client dropped).
    var onEnqueue: ((PendingRequest) -> Void)?
    var onResolve: ((PendingRequest, Decision?, DecisionSource) -> Void)?

    var autoAllow: AutoAllowStore?

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

        if let autoAllow, autoAllow.matches(payload) {
            Log.store.info("auto-allow match for \(payload.toolName ?? "?", privacy: .public)")
            let body = HookResponse.body(for: .allow, payload: payload)
            request.fulfil(with: body)
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

        let body = HookResponse.body(for: decision, payload: request.payload)
        request.fulfil(with: body)
        Log.store.info("resolved \(request.sessionLabel, privacy: .public) via \(source.rawValue, privacy: .public) pending=\(self.pending.count)")
        onResolve?(request, decision, source)
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
    }

    /// When a session Stops, clear its auto-allow rules (scope = one session).
    func sessionStopped(sessionId: String) {
        autoAllow?.clearSession(sessionId)
    }

    /// Show a passive toast for a few seconds (suppressed while a card is up).
    func showToast(_ toast: Toast?, duration: TimeInterval = 4) {
        guard let toast else { return }
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
