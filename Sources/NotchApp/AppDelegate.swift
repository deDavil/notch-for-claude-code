import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = AppSettings.load()
    private var store: RequestStore!
    private var router: Router!
    private var server: HTTPServer!
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let autoAllow = AutoAllowStore()
        store = RequestStore(settings: settings)
        store.autoAllow = autoAllow

        // Presenter selection:
        //  - NOTCH_AUTO      → headless auto-resolve (smoke tests / CI)
        //  - NOTCH_DIALOG=1  → osascript dialog (no-notch fallback / debugging)
        //  - default         → the notch panel (PanelController reacts to the queue)
        let useDialog = ProcessInfo.processInfo.environment["NOTCH_DIALOG"] == "1"
        store.onEnqueue = { [weak self] request in
            guard let self else { return }
            if let auto = self.settings.autoDecision {
                let decision: Decision
                switch auto {
                case "allow": decision = .allow
                case "deny": decision = .deny(reason: "Denied via notch (auto)")
                default: decision = .noOpinion
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.store.resolve(id: request.id, decision: decision, source: .notch)
                }
                return
            }
            if useDialog {
                OSAScriptPrompt.present(request) { decision in
                    Task { @MainActor in
                        self.store.resolve(id: request.id, decision: decision, source: .notch)
                    }
                }
            }
            // else: the notch panel (bound to store.pending) shows it.
            self.refreshStatus()
        }
        store.onResolve = { [weak self] _, _ in
            self?.refreshStatus()
        }

        panelController = PanelController(store: store, settings: settings)
        panelController.show()

        router = Router(store: store, settings: settings)
        router.onNotify = { payload in
            Log.app.info("notify: \(payload.notificationType ?? payload.hookEventName ?? "?", privacy: .public)")
        }

        server = HTTPServer(port: settings.port) { [weak self] req, client in
            self?.router.handle(req, client)
        }
        do {
            try server.start()
        } catch {
            Log.app.error("server failed to start: \(String(describing: error))")
        }

        setupStatusItem()
        Log.app.info("notch app ready on port \(self.settings.port)")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Notch")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Notch — Claude Code companion", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Port: \(settings.port)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        refreshStatus()
    }

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let n = store.pending.count
        button.title = n > 0 ? " \(n)" : ""
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
