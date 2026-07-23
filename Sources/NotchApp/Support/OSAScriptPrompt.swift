import Foundation

/// Skeleton presenter: shows a decision as a native `display dialog` and reports
/// the chosen verdict. Replaced by the notch UI in later phases, but kept as a
/// no-notch debugging fallback (NOTCH_DIALOG=1).
enum OSAScriptPrompt {
    static func present(_ request: PendingRequest, completion: @escaping (Decision) -> Void) {
        let s = request.summary
        let title = "Claude Code — \(request.sessionLabel)"
        let body: String
        if let plan = s.plan {
            body = String(plan.prefix(600))
        } else if let diff = s.diff, !diff.isEmpty {
            body = diff.prefix(20).map { ($0.kind == .added ? "+ " : $0.kind == .removed ? "- " : "  ") + $0.text }.joined(separator: "\n")
        } else {
            body = String((s.fullText ?? s.detail).prefix(400))
        }
        let reason = s.reason.map { "\($0)\n\n" } ?? ""
        let message = "\(s.title)\n\(reason)\(body)"

        let script = """
        display dialog \(quote(message)) \
        buttons {"Deny", "Allow (session)", "Allow"} \
        default button "Allow" with title \(quote(title))
        """

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()

            var decision: Decision = .noOpinion
            do {
                try proc.run()
                proc.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if out.contains("button returned:Allow (session)") {
                    decision = .allowForSession
                } else if out.contains("button returned:Allow") {
                    decision = .allow
                } else if out.contains("button returned:Deny") {
                    decision = .deny(reason: "Denied via notch overlay")
                } else {
                    decision = .noOpinion // dismissed/cancelled
                }
            } catch {
                Log.ui.error("osascript failed: \(String(describing: error))")
            }
            completion(decision)
        }
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
