import Foundation

/// Wires HTTP requests to the RequestStore. Token-authed; loopback only.
/// Endpoints:
///   POST /v1/permission  — long-poll; parked until the operator decides
///   POST /v1/notify      — fire-and-forget passive notification
///   GET  /v1/health      — liveness for installer + smoke tests
@MainActor
final class Router {
    private let store: RequestStore
    private let registry: SessionRegistry
    private let settings: AppSettings
    var onNotify: ((HookPayload) -> Void)?

    init(store: RequestStore, registry: SessionRegistry, settings: AppSettings) {
        self.store = store
        self.registry = registry
        self.settings = settings
    }

    /// Called on the HTTP queue. Hops to main for anything touching the store.
    nonisolated func handle(_ request: HTTPRequest, _ client: HTTPClient) {
        // Route + auth without touching the actor for GET /v1/health.
        if request.method == "GET", request.path.hasPrefix("/v1/health") {
            Task { @MainActor in self.health(client) }
            return
        }

        // Token check for state-changing endpoints.
        Task { @MainActor in
            if let token = self.settings.token {
                let provided = request.header("x-notch-token")
                guard provided == token else {
                    client.respond(.text(403, "forbidden"))
                    return
                }
            }
            switch (request.method, request.path) {
            case ("POST", "/v1/permission"):
                self.permission(request, client)
            case ("POST", "/v1/notify"):
                self.notify(request, client)
            default:
                client.respond(.text(404, "not found"))
            }
        }
    }

    private func health(_ client: HTTPClient) {
        let states = Dictionary(grouping: registry.sessions, by: { $0.displayState.rawValue })
            .mapValues { $0.count }
        let body: [String: Any] = [
            "ok": true,
            "pending": store.pending.count,
            "notch": settings.virtualNotch ? "virtual" : "real",
            "sessions": registry.sessions.count,
            "states": states,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        client.respond(.json(200, data))
    }

    private func permission(_ request: HTTPRequest, _ client: HTTPClient) {
        guard let payload = try? JSONDecoder().decode(HookPayload.self, from: request.body) else {
            client.respond(.text(400, "bad payload"))
            return
        }
        let id = store.enqueue(payload: payload) { body in
            if let body, !body.isEmpty {
                client.respond(.json(200, body))
            } else {
                client.respond(.empty(200)) // no opinion → Claude falls back
            }
        }
        // Wire peer-disconnect → drop the card (only if it's still pending).
        if let id {
            client.onDisconnect = { [weak store] in
                Task { @MainActor in store?.clientDropped(id: id) }
            }
        }
    }

    private func notify(_ request: HTTPRequest, _ client: HTTPClient) {
        if let payload = try? JSONDecoder().decode(HookPayload.self, from: request.body) {
            if payload.hookEventName == "Stop", let sid = payload.sessionId {
                store.sessionStopped(sessionId: sid)
            }
            onNotify?(payload)
        }
        client.respond(.empty(200))
    }
}
