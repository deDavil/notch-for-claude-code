import Foundation

/// Runtime configuration. Port + shared token come from env / files so the hook
/// scripts and the app agree without a build step.
struct AppSettings {
    let port: UInt16
    let token: String?
    let virtualNotch: Bool
    /// App-side answer timeout: safely inside curl --max-time 590 / hook timeout 600.
    let answerTimeout: TimeInterval
    /// Headless smoke-test hook: NOTCH_AUTO=allow|deny|noop auto-resolves without
    /// presenting UI. nil in normal operation.
    let autoDecision: String?

    static func load() -> AppSettings {
        let env = ProcessInfo.processInfo.environment

        let port = env["NOTCH_PORT"].flatMap { UInt16($0) } ?? 8790

        // Token: env wins, else ~/.config/notch-cc/token (matches hook scripts).
        var token = env["NOTCH_TOKEN"]
        if token == nil {
            let path = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".config/notch-cc/token")
            if let s = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                token = trimmed.isEmpty ? nil : trimmed
            }
        }

        let virtual = env["NOTCH_VIRTUAL"] == "1"
        let auto = env["NOTCH_AUTO"]

        return AppSettings(port: port, token: token, virtualNotch: virtual,
                           answerTimeout: 585, autoDecision: auto)
    }
}
