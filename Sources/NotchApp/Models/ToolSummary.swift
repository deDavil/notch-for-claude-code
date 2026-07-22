import Foundation

/// Decision-sufficient summary of a pending tool call: everything you need to
/// approve/deny from the notch or the phone without walking to the Mac.
struct ToolSummary {
    let title: String        // e.g. "Run command", "Edit main.swift"
    let icon: String         // SF Symbol
    let detail: String       // short one-liner (path, first line of command)
    var cwd: String?         // working directory (abbreviated with ~)
    var reason: String?      // Claude's stated reason (Bash description / transcript)
    var fullText: String?    // untruncated body for text calls (command, url, query)
    var diff: [DiffLine]?    // rendered change for Edit/Write/MultiEdit
    var ask: AskContent? = nil   // parsed AskUserQuestion (question + options)

    private static let maxDiffLines = 60

    static func make(from payload: HookPayload) -> ToolSummary {
        let tool = payload.toolName ?? "Tool"
        let input = payload.toolInput
        let cwd = abbreviate(payload.cwd)

        switch tool {
        case "AskUserQuestion":
            let ask = AskContent.parse(input)
            let title = ask?.first?.header.isEmpty == false ? (ask?.first?.header ?? "Question") : "Question"
            return ToolSummary(title: title, icon: "questionmark.bubble",
                               detail: ask?.first?.question ?? "", cwd: cwd,
                               reason: nil, fullText: nil, diff: nil, ask: ask)

        case "Bash":
            let cmd = input?["command"]?.stringValue ?? ""
            return ToolSummary(
                title: "Run command", icon: "terminal",
                detail: firstLine(cmd), cwd: cwd,
                reason: input?["description"]?.stringValue,
                fullText: cmd, diff: nil)

        case "Edit":
            let path = input?["file_path"]?.stringValue ?? ""
            let old = input?["old_string"]?.stringValue ?? ""
            let new = input?["new_string"]?.stringValue ?? ""
            return ToolSummary(
                title: "Edit \(basename(path))", icon: "pencil",
                detail: path, cwd: cwd,
                reason: TranscriptReader.lastAssistantText(path: payload.transcriptPath),
                fullText: nil, diff: cap(TextDiff.lines(old: old, new: new)))

        case "MultiEdit":
            let path = input?["file_path"]?.stringValue ?? ""
            var lines: [DiffLine] = []
            if case .array(let edits)? = input?["edits"] {
                for (i, edit) in edits.enumerated() {
                    let old = edit["old_string"]?.stringValue ?? ""
                    let new = edit["new_string"]?.stringValue ?? ""
                    if i > 0 { lines.append(DiffLine(kind: .context, text: "…")) }
                    lines.append(contentsOf: TextDiff.lines(old: old, new: new))
                }
            }
            let count = { () -> Int in if case .array(let e)? = input?["edits"] { return e.count }; return 0 }()
            return ToolSummary(
                title: "Edit \(basename(path)) · \(count) changes", icon: "pencil",
                detail: path, cwd: cwd,
                reason: TranscriptReader.lastAssistantText(path: payload.transcriptPath),
                fullText: nil, diff: cap(lines))

        case "Write":
            let path = input?["file_path"]?.stringValue ?? ""
            let content = input?["content"]?.stringValue ?? ""
            return ToolSummary(
                title: "Write \(basename(path))", icon: "square.and.pencil",
                detail: path, cwd: cwd,
                reason: TranscriptReader.lastAssistantText(path: payload.transcriptPath),
                fullText: nil, diff: cap(TextDiff.allAdded(content)))

        case "Read":
            let path = input?["file_path"]?.stringValue ?? ""
            return ToolSummary(title: "Read \(basename(path))", icon: "doc.text",
                               detail: path, cwd: cwd, reason: nil, fullText: path, diff: nil)

        case "WebFetch":
            let url = input?["url"]?.stringValue ?? ""
            return ToolSummary(title: "Fetch URL", icon: "globe",
                               detail: url, cwd: cwd,
                               reason: input?["prompt"]?.stringValue, fullText: url, diff: nil)

        case "WebSearch":
            let q = input?["query"]?.stringValue ?? ""
            return ToolSummary(title: "Web search", icon: "magnifyingglass",
                               detail: q, cwd: cwd, reason: nil, fullText: q, diff: nil)

        default:
            if tool.hasPrefix("mcp__") {
                let label = tool.split(separator: "_").filter { !$0.isEmpty }.dropFirst().joined(separator: " · ")
                return ToolSummary(title: "MCP: \(label)", icon: "puzzlepiece.extension",
                                   detail: compactInput(input), cwd: cwd, reason: nil,
                                   fullText: compactInput(input), diff: nil)
            }
            return ToolSummary(title: tool, icon: "wrench.and.screwdriver",
                               detail: compactInput(input), cwd: cwd, reason: nil,
                               fullText: compactInput(input), diff: nil)
        }
    }

    // MARK: - helpers

    private static func cap(_ lines: [DiffLine]) -> [DiffLine] {
        guard lines.count > maxDiffLines else { return lines }
        var out = Array(lines.prefix(maxDiffLines))
        out.append(DiffLine(kind: .context, text: "… (\(lines.count - maxDiffLines) more lines)"))
        return out
    }

    private static func firstLine(_ s: String) -> String {
        s.components(separatedBy: "\n").first ?? s
    }

    private static func basename(_ path: String) -> String {
        let b = (path as NSString).lastPathComponent
        return b.isEmpty ? path : b
    }

    private static func abbreviate(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func compactInput(_ input: JSONValue?) -> String {
        guard let input, let data = try? JSONEncoder().encode(input),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return String(s.prefix(500))
    }
}
