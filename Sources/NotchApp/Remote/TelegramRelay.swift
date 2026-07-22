import Foundation

/// Mirrors each pending permission request to Telegram and feeds taps back into
/// the store as decisions. The Mac store stays the single arbiter: taps call
/// `onRemoteDecision`, which returns whether this decision *won* the race
/// (store.resolve is idempotent). On settle — from any device — the message is
/// edited to the outcome and its keyboard removed; late taps get "Already
/// handled". Disabled cleanly when no config is present.
@MainActor
final class TelegramRelay {
    private final class Record {
        var messageId: Int?
        var baseText: String
        var settledText: String?
        var question: AskContent.Question?   // for mapping option taps → answers
        init(baseText: String) { self.baseText = baseText }
    }

    private let config: TelegramConfig
    private let api: TelegramAPI
    private var records: [UUID: Record] = [:]
    private var pollTask: Task<Void, Never>?
    private var offset = 0

    /// Set by AppDelegate: resolve in the store, returning whether it won.
    var onRemoteDecision: ((UUID, Decision) -> Bool)?

    var isEnabled: Bool { true }

    init?(config: TelegramConfig?) {
        guard let config else { return nil }
        self.config = config
        self.api = TelegramAPI(token: config.token)
    }

    func start() {
        Log.telegram.info("relay enabled for chat \(self.config.chatId, privacy: .public)")
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    func stop() { pollTask?.cancel() }

    // MARK: - Announce / settle (called from the store's hooks)

    func announce(_ request: PendingRequest) {
        let base = Self.messageText(for: request)
        let record = Record(baseText: base)
        records[request.id] = record

        let idStr = request.id.uuidString
        var rows: [[TelegramAPI.InlineButton]] = []

        if let ask = request.summary.ask, ask.isSimple, let q = ask.first {
            // One button per answer option, then Deny.
            record.question = q
            for (i, opt) in q.options.enumerated() {
                rows.append([TelegramAPI.InlineButton(
                    text: "\(i + 1). \(opt.label)", callbackData: "req:\(idStr):opt:\(i)")])
            }
            rows.append([TelegramAPI.InlineButton(text: "⛔️ Dismiss", callbackData: "req:\(idStr):deny")])
        } else if request.summary.ask != nil {
            // Multi-part / multi-select question: answer on the Mac notch; phone can only dismiss.
            rows.append([TelegramAPI.InlineButton(text: "⛔️ Dismiss", callbackData: "req:\(idStr):deny")])
        } else {
            rows.append([
                TelegramAPI.InlineButton(text: "✅ Approve", callbackData: "req:\(idStr):allow"),
                TelegramAPI.InlineButton(text: "♻️ Session", callbackData: "req:\(idStr):session"),
                TelegramAPI.InlineButton(text: "⛔️ Deny", callbackData: "req:\(idStr):deny"),
            ])
        }

        Task { [weak self] in
            guard let self else { return }
            let mid = await self.api.sendMessage(chatId: self.config.chatId, text: base, rows: rows)
            self.attachMessageId(mid, to: request.id)
        }
    }

    func settle(_ request: PendingRequest, decision: Decision?, source: DecisionSource) {
        let verdict = Self.verdictLine(decision: decision, source: source)
        guard let record = records[request.id] else { return }
        let text = record.baseText + "\n\n" + verdict
        record.settledText = text
        if let mid = record.messageId {
            Task { [weak self] in
                guard let self else { return }
                await self.api.editMessageText(chatId: self.config.chatId, messageId: mid, text: text)
            }
        }
        // else: announce() will apply settledText once the message id arrives.
    }

    private func attachMessageId(_ mid: Int?, to id: UUID) {
        guard let record = records[id] else { return }
        record.messageId = mid
        if let mid, let settled = record.settledText {
            Task { [weak self] in
                guard let self else { return }
                await self.api.editMessageText(chatId: self.config.chatId, messageId: mid, text: settled)
            }
        }
    }

    // MARK: - Long-poll

    private func pollLoop() async {
        while !Task.isCancelled {
            let updates = await api.getUpdates(offset: offset, timeout: 25)
            for update in updates {
                if let updateId = update["update_id"] as? Int {
                    offset = max(offset, updateId + 1)
                }
                if let cb = update["callback_query"] as? [String: Any] {
                    await handleCallback(cb)
                }
            }
            if updates.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
    }

    private func handleCallback(_ cb: [String: Any]) async {
        let cbId = cb["id"] as? String ?? ""
        let from = cb["from"] as? [String: Any]
        let fromId = (from?["id"] as? Int64) ?? Int64(from?["id"] as? Int ?? 0)

        // Only the configured operator may decide.
        if let op = config.operatorId, fromId != op {
            await api.answerCallbackQuery(id: cbId, text: "Not authorized")
            return
        }

        guard let data = cb["data"] as? String else { return }
        let parts = data.split(separator: ":")
        guard parts.count >= 3, parts[0] == "req",
              let id = UUID(uuidString: String(parts[1])) else { return }

        let decision: Decision
        switch parts[2] {
        case "allow": decision = .allow
        case "session": decision = .allowForSession
        case "deny": decision = .deny(reason: "Denied from iPhone")
        case "opt":
            // Answer an AskUserQuestion: map the option index → its label.
            guard parts.count == 4, let idx = Int(parts[3]),
                  let q = records[id]?.question, idx < q.options.count else { return }
            decision = .answer([q.question: q.options[idx].label])
        default: return
        }

        let won = onRemoteDecision?(id, decision) ?? false
        await api.answerCallbackQuery(id: cbId, text: won ? "Sent to Claude" : "Already handled")
    }

    // MARK: - Text

    private static func messageText(for request: PendingRequest) -> String {
        let s = request.summary

        // AskUserQuestion → a real question with numbered options.
        if let ask = s.ask {
            var lines = ["❓ <b>\(esc(request.sessionLabel))</b> asks:"]
            for q in ask.questions {
                lines.append("\n<b>\(esc(q.question))</b>")
                for (i, opt) in q.options.enumerated() {
                    var line = "\(i + 1). <b>\(esc(opt.label))</b>"
                    if !opt.description.isEmpty { line += " — \(esc(opt.description))" }
                    lines.append(line)
                }
            }
            if !ask.isSimple { lines.append("\n<i>Multi-part question — answer on the Mac notch.</i>") }
            return lines.joined(separator: "\n")
        }

        var lines = ["🔐 <b>\(esc(request.sessionLabel))</b> · \(esc(s.title))"]
        if let cwd = s.cwd { lines.append("📁 <code>\(esc(cwd))</code>") }
        if let reason = s.reason, !reason.isEmpty {
            lines.append("💬 <i>\(esc(String(reason.prefix(300))))</i>")
        }
        if let diff = s.diff, !diff.isEmpty {
            lines.append("<pre>\(esc(renderDiff(diff)))</pre>")
        } else if let full = s.fullText, !full.isEmpty {
            lines.append("<pre>\(esc(String(full.prefix(1500))))</pre>")
        }
        return lines.joined(separator: "\n")
    }

    /// Plain-text diff for a Telegram <pre> block, bounded to keep the message
    /// under Telegram's 4096-char limit.
    private static func renderDiff(_ diff: [DiffLine]) -> String {
        let rendered = diff.map { line -> String in
            let p: String
            switch line.kind {
            case .added: p = "+"
            case .removed: p = "-"
            case .context: p = " "
            }
            return "\(p) \(line.text)"
        }.joined(separator: "\n")
        return String(rendered.prefix(3000))
    }

    private static func verdictLine(decision: Decision?, source: DecisionSource) -> String {
        if source == .clientDropped { return "↩︎ Session ended before you answered" }
        guard let decision else { return "⏱ No answer" }
        let from = fromLabel(source)
        switch decision {
        case .allow: return "✅ Approved\(from)"
        case .allowForSession: return "✅ Approved · whole session\(from)"
        case .answer(let answers):
            let picked = answers.values.joined(separator: ", ")
            return "✅ Answered: <b>\(esc(picked))</b>\(from)"
        case .deny: return "⛔️ Denied\(from)"
        case .noOpinion: return "⏱ Timed out — answer in terminal"
        }
    }

    private static func fromLabel(_ source: DecisionSource) -> String {
        switch source {
        case .notch: return " · from Mac"
        case .hotkey: return " · from Mac (hotkey)"
        case .telegram: return " · from iPhone"
        case .autoAllow: return " · auto (session rule)"
        case .timeout, .clientDropped: return ""
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
