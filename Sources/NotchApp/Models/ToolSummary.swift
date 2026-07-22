import Foundation

/// Renders a pending tool call into a short title + detail for the card and
/// Telegram message. Keeps per-tool knowledge in one place.
struct ToolSummary {
    let title: String       // e.g. "Bash", "Edit main.swift"
    let detail: String      // e.g. the command, the file path, the URL
    let icon: String        // SF Symbol name

    static func make(from payload: HookPayload) -> ToolSummary {
        let tool = payload.toolName ?? "Tool"
        let input = payload.toolInput

        switch tool {
        case "Bash":
            let cmd = input?["command"]?.stringValue ?? ""
            return ToolSummary(title: "Run command", detail: cmd, icon: "terminal")
        case "Edit", "MultiEdit":
            let path = input?["file_path"]?.stringValue ?? ""
            return ToolSummary(title: "Edit \(basename(path))", detail: path, icon: "pencil")
        case "Write":
            let path = input?["file_path"]?.stringValue ?? ""
            return ToolSummary(title: "Write \(basename(path))", detail: path, icon: "square.and.pencil")
        case "Read":
            let path = input?["file_path"]?.stringValue ?? ""
            return ToolSummary(title: "Read \(basename(path))", detail: path, icon: "doc.text")
        case "WebFetch":
            let url = input?["url"]?.stringValue ?? ""
            return ToolSummary(title: "Fetch URL", detail: url, icon: "globe")
        case "WebSearch":
            let q = input?["query"]?.stringValue ?? ""
            return ToolSummary(title: "Web search", detail: q, icon: "magnifyingglass")
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_").filter { !$0.isEmpty }
                let label = parts.dropFirst().joined(separator: " · ")
                return ToolSummary(title: "MCP: \(label)", detail: compactInput(input), icon: "puzzlepiece.extension")
            }
            return ToolSummary(title: tool, detail: compactInput(input), icon: "wrench.and.screwdriver")
        }
    }

    private static func basename(_ path: String) -> String {
        let b = (path as NSString).lastPathComponent
        return b.isEmpty ? path : b
    }

    private static func compactInput(_ input: JSONValue?) -> String {
        guard let input else { return "" }
        let enc = JSONEncoder()
        guard let data = try? enc.encode(input), let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(300))
    }
}
