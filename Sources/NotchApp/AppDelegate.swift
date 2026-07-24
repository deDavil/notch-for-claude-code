import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings = AppSettings.load()
    private var store: RequestStore!
    private var registry: SessionRegistry!
    private var autoAllow: AutoAllowStore!
    private var router: Router!
    private var server: HTTPServer!
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var telegram: TelegramRelay?
    private let hotKeys = HotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        autoAllow = AutoAllowStore()
        registry = SessionRegistry()
        store = RequestStore(settings: settings)
        store.autoAllow = autoAllow

        // Hotkeys resolve the front request (registered only while pending).
        hotKeys.onAction = { [weak self] action in
            guard let self, let front = self.store.frontRequest else { return }
            switch action {
            case .approve: self.store.resolve(id: front.id, decision: .allow, source: .hotkey)
            case .deny: self.store.resolve(id: front.id, decision: .deny(reason: "Denied via notch overlay"), source: .hotkey)
            case .dismiss: self.store.resolve(id: front.id, decision: .noOpinion, source: .hotkey)
            }
        }

        // Telegram mirror (first-answer-wins). Nil when unconfigured → Mac-only.
        telegram = TelegramRelay(config: TelegramConfig.load())
        telegram?.onRemoteDecision = { [weak self] id, decision in
            self?.store.resolve(id: id, decision: decision, source: .telegram) ?? false
        }
        telegram?.start()

        // Presenter selection:
        //  - NOTCH_AUTO      → headless auto-resolve (smoke tests / CI)
        //  - NOTCH_DIALOG=1  → osascript dialog (no-notch fallback / debugging)
        //  - default         → the notch panel (PanelController reacts to the queue)
        let useDialog = ProcessInfo.processInfo.environment["NOTCH_DIALOG"] == "1"
        store.onEnqueue = { [weak self] request in
            guard let self else { return }
            self.registry.incPending(request.payload)
            self.telegram?.announce(request)
            self.hotKeys.enable()
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
        store.onResolve = { [weak self] request, decision, source in
            guard let self else { return }
            self.registry.decPending(request.payload)
            self.telegram?.settle(request, decision: decision, source: source)
            if self.store.pending.isEmpty { self.hotKeys.disable() }
            self.refreshStatus()
        }
        // Audit every terminal outcome (incl. auto-allow + client drops).
        store.onOutcome = { request, decision, source in
            DecisionLog.append(request: request, decision: decision, source: source)
        }

        panelController = PanelController(store: store, registry: registry, settings: settings)
        panelController.show()

        router = Router(store: store, registry: registry, settings: settings)
        router.onNotify = { [weak self] payload in
            guard let self else { return }
            Log.app.info("notify: \(payload.notificationType ?? payload.hookEventName ?? "?", privacy: .public)")
            self.registry.noteEvent(payload)
            // Only surface a toast when no card is up (a pending decision wins the notch).
            if self.store.pending.isEmpty {
                self.store.showToast(Toast.from(payload))
            }
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
        menu.delegate = self // rebuilds dynamic rows on open
        statusItem.menu = menu
        refreshStatus()
    }

    /// Rebuild the menu each time it opens so counts/status are live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Notch — Claude Code companion", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let pending = store.pending.count
        menu.addItem(withTitle: pending == 0 ? "No pending requests" : "\(pending) pending",
                     action: nil, keyEquivalent: "")
        let notch = settings.virtualNotch ? "virtual" : "real"
        menu.addItem(withTitle: "Notch: \(notch) · port \(settings.port)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Telegram: \(telegram == nil ? "off" : "on")", action: nil, keyEquivalent: "")

        let rules = autoAllow.count
        let clear = NSMenuItem(title: "Clear session rules (\(rules))",
                               action: #selector(clearRules), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = rules > 0
        menu.addItem(clear)

        let log = NSMenuItem(title: "Open decision log",
                             action: #selector(openDecisionLog), keyEquivalent: "")
        log.target = self
        log.isEnabled = FileManager.default.fileExists(atPath: DecisionLog.path)
        menu.addItem(log)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let n = store.pending.count
        button.title = n > 0 ? " \(n)" : ""
    }

    @objc private func clearRules() {
        autoAllow.clearAll()
    }

    @objc private func openDecisionLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: DecisionLog.path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
