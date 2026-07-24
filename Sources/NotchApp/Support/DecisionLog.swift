import Foundation

/// Append-only audit trail of every decision the app makes on the operator's
/// behalf: one JSON object per line at ~/.config/klavs-notch/decisions.jsonl
/// (override: NOTCH_DECISION_LOG). Fail-silent — logging must never affect the
/// approval path.
enum DecisionLog {
    static var path: String {
        if let p = ProcessInfo.processInfo.environment["NOTCH_DECISION_LOG"], !p.isEmpty {
            return p
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/klavs-notch/decisions.jsonl")
    }

    /// Pure record builder (unit-testable): the JSONL line for one outcome.
    static func record(request: PendingRequest, decision: Decision?,
                       source: DecisionSource, now: Date = Date()) -> [String: Any] {
        var rec: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: now),
            "session": request.sessionLabel,
            "session_id": request.sessionId,
            "tool": request.payload.toolName ?? "?",
            "title": request.summary.title,
            "detail": String(request.summary.detail.prefix(200)),
            "source": source.rawValue,
            "latency_s": Int(now.timeIntervalSince(request.receivedAt).rounded()),
        ]
        if let cwd = request.payload.cwd { rec["cwd"] = cwd }
        switch decision {
        case .allow: rec["decision"] = "allow"
        case .allowForSession: rec["decision"] = "allow_for_session"
        case .allowForProject: rec["decision"] = "allow_for_project"
        case .deny(let reason): rec["decision"] = "deny"; rec["reason"] = reason
        case .answer(let answers):
            rec["decision"] = "answer"
            rec["answers"] = answers
        case .noOpinion: rec["decision"] = "no_opinion"
        case nil: rec["decision"] = "dropped"
        }
        return rec
    }

    /// Serialize + append. Any failure is swallowed (audit is best-effort).
    static func append(request: PendingRequest, decision: Decision?, source: DecisionSource) {
        let rec = record(request: request, decision: decision, source: source)
        guard var data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) else { return }
        data.append(0x0A) // newline
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url) // first line
        }
    }
}
