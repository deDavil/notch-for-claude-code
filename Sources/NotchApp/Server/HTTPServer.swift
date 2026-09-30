import Foundation
import Network

/// A parked HTTP connection: the router can respond immediately or hold it open
/// (long-poll) and respond later. Detects peer disconnect while parked so the
/// store can drop the corresponding card.
final class HTTPClient {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var responded = false
    private var closedFired = false
    var onDisconnect: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Send a response and close. Idempotent — later calls no-op.
    func respond(_ response: HTTPResponse) {
        queue.async { [weak self] in
            guard let self, !self.responded else { return }
            self.responded = true
            let data = response.serialized()
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }

    /// One-shot (all calls on the serial queue): fire onDisconnect at most once,
    /// and only if we never sent a response.
    fileprivate func markPeerClosed() {
        guard !responded, !closedFired else { return }
        closedFired = true
        onDisconnect?()
    }
}

/// Minimal loopback HTTP/1.1 server on 127.0.0.1. One request per connection.
final class HTTPServer {
    typealias Router = (HTTPRequest, HTTPClient) -> Void

    private let port: UInt16
    private let router: Router
    private let queue = DispatchQueue(label: "io.github.dedavil.notch.http")
    private var listener: NWListener?

    /// Fired (once, on the main queue) if the listener fails — e.g. the port is
    /// already bound. The app decides whether to exit.
    var onFailure: ((Error) -> Void)?

    init(port: UInt16, router: @escaping Router) {
        self.port = port
        self.router = router
    }

    func start() throws {
        let params = NWParameters.tcp
        // Bind to loopback only — never exposed off-box.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                           port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Log.server.info("listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let e):
                Log.server.error("listener failed: \(String(describing: e))")
                DispatchQueue.main.async { self?.onFailure?(e) }
            default: break
            }
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let parser = HTTPRequestParser()
        let client = HTTPClient(connection: conn, queue: queue)
        conn.stateUpdateHandler = { state in
            switch state {
            case .cancelled, .failed:
                client.markPeerClosed()
            default:
                break
            }
        }
        conn.start(queue: queue)
        readLoop(conn: conn, parser: parser, client: client, routed: false)
    }

    /// Reads until the request is parsed and routed, then KEEPS an outstanding
    /// receive so a peer close (graceful FIN from a Ctrl-C'd session's killed
    /// curl) is detected promptly and drops the parked card — rather than
    /// lingering until the answer timeout. Post-route bytes are ignored.
    private func readLoop(conn: NWConnection, parser: HTTPRequestParser,
                          client: HTTPClient, routed: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var didRoute = routed
            if !didRoute, let data, !data.isEmpty {
                do {
                    if try parser.feed(data), let request = parser.request {
                        self.router(request, client)
                        didRoute = true // keep watching for close, don't return
                    }
                } catch {
                    client.respond(.text(400, "bad request"))
                    return
                }
            }
            if isComplete || error != nil {
                client.markPeerClosed()
                conn.cancel()
                return
            }
            self.readLoop(conn: conn, parser: parser, client: client, routed: didRoute)
        }
    }
}
