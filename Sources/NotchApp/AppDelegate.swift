import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings = AppSettings.load()
    private var store: RequestStore!
    private var registry: SessionRegistry!
    private var autoAllow: AutoAllowStore!
    private var projectRules: ProjectRuleStore!
    private var router: Router!
    private var server: HTTPServer!
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var telegram: TelegramRelay?
    private let hotKeys = HotKeys()
    private let micMonitor = MicMonitor()
    /// Menu-toggleable; NOTCH_AUTOPAUSE=0 disables the feature at launch.
    private var autoPauseEnabled = ProcessInfo.processInfo.environment["NOTCH_AUTOPAUSE"] != "0"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        autoAllow = AutoAllowStore()
        projectRules = ProjectRuleStore()
        registry = SessionRegistry()
        store = RequestStore(settings: settings)
        store.autoAllow = autoAllow
        store.projectRules = projectRules

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

        // Auto-pause while the mic is in use (operator is on a call).
        micMonitor.onChange = { [weak self] inUse in
            guard let self else { return }
            self.store.autoPaused = self.autoPauseEnabled && inUse
        }
        micMonitor.start()

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
        // Port already bound (launchd instance + manual open is the common case):
        // if a healthy sibling is serving, this copy is redundant — exit 0 so
        // launchd doesn't restart-loop it. A foreign squatter gets a loud line.
        server.onFailure = { [weak self] error in
            self?.handleServerFailure(error)
        }
        do {
            try server.start()
        } catch {
            Log.app.error("server failed to start: \(String(describing: error))")
            handleServerFailure(error)
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

        let pause = NSMenuItem(
            title: store.paused ? "Resume approvals" : "Pause approvals (answer in terminal)",
            action: #selector(togglePause), keyEquivalent: "p")
        pause.target = self
        pause.state = store.paused ? .on : .off
        menu.addItem(pause)

        let auto = NSMenuItem(
            title: store.autoPaused ? "Auto-paused: on a call (mic in use)"
                                    : "Auto-pause during calls",
            action: #selector(toggleAutoPause), keyEquivalent: "")
        auto.target = self
        auto.state = autoPauseEnabled ? .on : .off
        menu.addItem(auto)
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

        // Project rules submenu: one row per rule (click to revoke) + Clear all.
        let rules2 = projectRules.allRules()
        let rulesItem = NSMenuItem(title: "Project rules (\(rules2.count))", action: nil, keyEquivalent: "")
        if rules2.isEmpty {
            rulesItem.isEnabled = false
        } else {
            let sub = NSMenu()
            sub.addItem(withTitle: "Click a rule to revoke it", action: nil, keyEquivalent: "")
            sub.addItem(.separator())
            for rule in rules2 {
                let project = (rule.cwd as NSString).lastPathComponent
                let item = NSMenuItem(title: "\(project) · \(rule.tool) · \(rule.pattern)",
                                      action: #selector(revokeRule(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = rule
                item.toolTip = rule.cwd
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clearAll = NSMenuItem(title: "Clear all project rules",
                                      action: #selector(clearProjectRules), keyEquivalent: "")
            clearAll.target = self
            sub.addItem(clearAll)
            rulesItem.submenu = sub
        }
        menu.addItem(rulesItem)

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

    @objc private func clearProjectRules() {
        projectRules.clearAll()
    }

    @objc private func revokeRule(_ sender: NSMenuItem) {
        guard let rule = sender.representedObject as? ProjectRuleStore.Rule else { return }
        projectRules.remove(rule)
    }

    @objc private func togglePause() {
        store.paused.toggle()
        refreshPauseAppearance()
    }

    @objc private func toggleAutoPause() {
        autoPauseEnabled.toggle()
        store.autoPaused = autoPauseEnabled && micMonitor.inUse
        refreshPauseAppearance()
    }

    private func refreshPauseAppearance() {
        statusItem?.button?.appearsDisabled = store.effectivePaused
    }

    @objc private func openDecisionLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: DecisionLog.path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// The listener could not bind. Probe the port: a healthy sibling instance →
    /// exit quietly (it wins); anything else → loud stderr + exit. Exit code 0
    /// keeps launchd (KeepAlive SuccessfulExit=false) from restart-looping us.
    private func handleServerFailure(_ error: Error) {
        let port = settings.port
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let healthy = data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"ok\":true") ?? false
            let msg = healthy
                ? "notch: another instance is already serving on 127.0.0.1:\(port) — exiting.\n"
                : "notch: cannot bind 127.0.0.1:\(port) (occupied by another process?): \(error). Exiting.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            Log.app.error("\(msg, privacy: .public)")
            DispatchQueue.main.async { exit(0) }
        }.resume()
    }
}
