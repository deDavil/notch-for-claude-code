import Foundation

/// One line of a rendered diff.
struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable { case context, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String

    static func == (a: DiffLine, b: DiffLine) -> Bool { a.kind == b.kind && a.text == b.text }
}

/// Lightweight line diff: trims the common prefix/suffix and shows the changed
/// middle as removed-then-added, with a couple of context lines. Not a full LCS —
/// just enough to judge an edit at a glance. Long diffs are capped by the caller.
enum TextDiff {
    static func lines(old: String, new: String, context: Int = 2) -> [DiffLine] {
        let o = old.components(separatedBy: "\n")
        let n = new.components(separatedBy: "\n")

        // common prefix
        var start = 0
        while start < o.count && start < n.count && o[start] == n[start] { start += 1 }
        // common suffix (not crossing `start`)
        var oEnd = o.count
        var nEnd = n.count
        while oEnd > start && nEnd > start && o[oEnd - 1] == n[nEnd - 1] { oEnd -= 1; nEnd -= 1 }

        var result: [DiffLine] = []
        let ctxStart = max(0, start - context)
        for i in ctxStart..<start { result.append(DiffLine(kind: .context, text: o[i])) }
        for i in start..<oEnd { result.append(DiffLine(kind: .removed, text: o[i])) }
        for i in start..<nEnd { result.append(DiffLine(kind: .added, text: n[i])) }
        let ctxEnd = min(o.count, oEnd + context)
        for i in oEnd..<ctxEnd { result.append(DiffLine(kind: .context, text: o[i])) }
        return result
    }

    /// Treat every line of `text` as added (for Write, which has no prior state).
    static func allAdded(_ text: String) -> [DiffLine] {
        text.components(separatedBy: "\n").map { DiffLine(kind: .added, text: $0) }
    }

    /// A compact +N/-M summary line for headers/Telegram.
    static func stat(_ lines: [DiffLine]) -> String {
        let added = lines.filter { $0.kind == .added }.count
        let removed = lines.filter { $0.kind == .removed }.count
        return "+\(added) −\(removed)"
    }
}
