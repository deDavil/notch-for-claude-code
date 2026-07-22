import Foundation

/// Best-effort extraction of "why Claude wants this" from the session transcript.
/// The PermissionRequest payload has no tool_use_id, so we take the most recent
/// assistant text block in the transcript — i.e. what Claude said right before
/// asking. Fail-silent: any error → nil (the card just omits the reason).
enum TranscriptReader {
    /// Read the tail of the transcript jsonl and return the last assistant text.
    static func lastAssistantText(path: String?, maxBytes: Int = 512 * 1024) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Tail-read: seek to the last `maxBytes` so huge transcripts stay cheap.
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Drop a partial first line if we seeked into the middle of the file.
        var lines = text.components(separatedBy: "\n")
        if start > 0 { lines = Array(lines.dropFirst()) }

        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
            else { continue }
            guard (obj["type"] as? String) == "assistant" else { continue }
            if let msg = obj["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                // Prefer the last text block; skip thinking/tool_use blocks.
                for block in content.reversed() where (block["type"] as? String) == "text" {
                    if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !t.isEmpty {
                        return String(t.prefix(400))
                    }
                }
            }
        }
        return nil
    }
}
