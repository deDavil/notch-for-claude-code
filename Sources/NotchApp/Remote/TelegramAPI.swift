import Foundation

/// Thin async Telegram Bot API client (URLSession, no deps). Only the methods
/// the relay needs. All calls are best-effort; failures are logged, not thrown
/// to callers, so a flaky network never blocks the Mac-side arbiter.
struct TelegramAPI {
    let token: String
    /// Overridable for tests via NOTCH_TELEGRAM_BASE (e.g. http://127.0.0.1:PORT).
    private var base: String {
        let root = ProcessInfo.processInfo.environment["NOTCH_TELEGRAM_BASE"]
            ?? "https://api.telegram.org"
        return "\(root)/bot\(token)"
    }
    private let session = URLSession(configuration: .ephemeral)

    struct InlineButton { let text: String; let callbackData: String }

    /// Send a message with an optional inline keyboard (one array per row).
    /// Returns the created message_id, or nil on failure.
    func sendMessage(chatId: Int64, text: String, rows: [[InlineButton]]) async -> Int? {
        var body: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true,
        ]
        let nonEmpty = rows.filter { !$0.isEmpty }
        if !nonEmpty.isEmpty {
            body["reply_markup"] = ["inline_keyboard": nonEmpty.map { row in
                row.map { ["text": $0.text, "callback_data": $0.callbackData] }
            }]
        }
        let json = await post("sendMessage", body)
        return (json?["result"] as? [String: Any])?["message_id"] as? Int
    }

    /// Replace a message's text and drop its keyboard (used on settle).
    func editMessageText(chatId: Int64, messageId: Int, text: String) async {
        _ = await post("editMessageText", [
            "chat_id": chatId,
            "message_id": messageId,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": true,
        ])
    }

    /// Acknowledge a callback query (removes the client's spinner; optional toast).
    func answerCallbackQuery(id: String, text: String?) async {
        var body: [String: Any] = ["callback_query_id": id]
        if let text { body["text"] = text }
        _ = await post("answerCallbackQuery", body)
    }

    /// Long-poll for updates since `offset`. `timeout` is server-side seconds.
    /// Long-poll for updates. Returns nil on FAILURE (transport error or a
    /// non-ok response such as 401 invalid-token / 409 conflict) so the caller
    /// can back off instead of hot-looping; [] means a genuine empty poll.
    func getUpdates(offset: Int, timeout: Int) async -> [[String: Any]]? {
        let body: [String: Any] = [
            "offset": offset,
            "timeout": timeout,
            "allowed_updates": ["callback_query"],
        ]
        let json = await post("getUpdates", body, requestTimeout: TimeInterval(timeout + 10))
        guard let json, (json["ok"] as? Bool) == true else { return nil }
        return (json["result"] as? [[String: Any]]) ?? []
    }

    // MARK: -

    private func post(_ method: String, _ body: [String: Any],
                      requestTimeout: TimeInterval = 15) async -> [String: Any]? {
        guard let url = URL(string: "\(base)/\(method)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = requestTimeout
        do {
            let (respData, _) = try await session.data(for: req)
            return try? JSONSerialization.jsonObject(with: respData) as? [String: Any]
        } catch {
            Log.telegram.error("\(method, privacy: .public) failed: \(String(describing: error))")
            return nil
        }
    }
}
