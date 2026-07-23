import SwiftUI

/// Renders an ExitPlanMode markdown plan readably — headers, bullets, numbered
/// items, and inline emphasis — instead of a raw JSON blob. Not a full markdown
/// engine; block-level structure by line plus SwiftUI inline markdown per line.
struct PlanView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(for: line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 320)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.04)))
    }

    private var lines: [String] { markdown.components(separatedBy: "\n") }

    @ViewBuilder private func row(for raw: String) -> some View {
        let line = raw
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(.system(size: 12, weight: .semibold))
                .padding(.top, 2)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(.system(size: 13, weight: .bold))
                .padding(.top, 3)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(.system(size: 15, weight: .bold))
                .padding(.top, 3)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            bullet("•", String(trimmed.dropFirst(2)), indent: leadingSpaces(line))
        } else if let (num, rest) = numbered(trimmed) {
            bullet(num, rest, indent: leadingSpaces(line))
        } else if trimmed == "```" || trimmed.hasPrefix("```") {
            EmptyView() // hide code-fence markers
        } else if trimmed.isEmpty {
            Spacer().frame(height: 3)
        } else {
            Text(inline(line)).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ marker: String, _ text: String, indent: Int) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(inline(text)).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(indent, 8)) * 1.5)
    }

    private func numbered(_ s: String) -> (String, String)? {
        guard let dot = s.firstIndex(of: "."), s.startIndex < dot,
              s[s.startIndex..<dot].allSatisfy(\.isNumber) else { return nil }
        let after = s.index(after: dot)
        guard after < s.endIndex, s[after] == " " else { return nil }
        return (String(s[s.startIndex...dot]), String(s[s.index(after: after)...]))
    }

    private func leadingSpaces(_ s: String) -> Int {
        s.prefix { $0 == " " }.count
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
    }
}
