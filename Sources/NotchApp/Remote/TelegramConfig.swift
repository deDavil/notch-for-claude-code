import Foundation

/// Config for the Telegram mirror. Absent file → relay disabled (Mac-only path
/// still works). Uses a DEDICATED bot token (do not reuse the runtime's bot —
/// Telegram allows one getUpdates consumer per token).
///
///   ~/.config/klavs-notch/telegram.json  (chmod 600)
///   { "token": "123:ABC", "chat_id": 12345, "operator_id": 12345 }
///
/// `operator_id` is optional; when set, only callbacks from that user id are
/// honored (defends against another chat member tapping the buttons).
struct TelegramConfig {
    let token: String
    let chatId: Int64
    let operatorId: Int64?

    static func load() -> TelegramConfig? {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/klavs-notch/telegram.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        struct Raw: Decodable { let token: String; let chat_id: Int64; let operator_id: Int64? }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data),
              !raw.token.isEmpty else {
            Log.telegram.error("telegram.json present but invalid")
            return nil
        }
        return TelegramConfig(token: raw.token, chatId: raw.chat_id, operatorId: raw.operator_id)
    }
}
