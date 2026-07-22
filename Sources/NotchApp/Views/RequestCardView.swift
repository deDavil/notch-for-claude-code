import SwiftUI

/// Expanded permission card: session + tool + full context (cwd, Claude's
/// reason, and either a rendered diff or the full command) + decision buttons.
/// The body scrolls within a bounded height so long diffs don't grow the panel.
struct RequestCardView: View {
    let request: PendingRequest
    let queuedBehind: Int
    let onDecision: (Decision, DecisionSource) -> Void

    private var s: ToolSummary { request.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(s.title).font(.system(size: 13, weight: .semibold))
            if let cwd = s.cwd {
                Label(cwd, systemImage: "folder")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let reason = s.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .italic().lineLimit(3)
            }
            bodyView
            buttons
        }
        .padding(12)
        .frame(width: RequestCardView.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: s.icon).foregroundStyle(.orange)
            Text(request.sessionLabel)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let diff = s.diff { Text(TextDiff.stat(diff)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary) }
            if queuedBehind > 0 {
                Text("+\(queuedBehind)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
        }
    }

    @ViewBuilder private var bodyView: some View {
        if let diff = s.diff, !diff.isEmpty {
            ScrollView { diffView(diff) }.frame(maxHeight: 220)
        } else if let full = s.fullText, !full.isEmpty {
            ScrollView {
                Text(full)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        }
    }

    private func diffView(_ diff: [DiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff) { line in
                HStack(alignment: .top, spacing: 4) {
                    Text(prefix(line.kind)).foregroundStyle(color(line.kind).opacity(0.8))
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(color(line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 0.5)
                .background(bg(line.kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func prefix(_ k: DiffLine.Kind) -> String {
        switch k { case .added: return "+"; case .removed: return "-"; case .context: return " " }
    }
    private func color(_ k: DiffLine.Kind) -> Color {
        switch k { case .added: return .green; case .removed: return .red; case .context: return .secondary }
    }
    private func bg(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return .green.opacity(0.12)
        case .removed: return .red.opacity(0.12)
        case .context: return .clear
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button { onDecision(.deny(reason: "Denied via notch overlay"), .notch) } label: {
                Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
            }.tint(.red).keyboardShortcut("n", modifiers: [])
            Button { onDecision(.allowForSession, .notch) } label: {
                Text("Session").frame(maxWidth: .infinity)
            }.keyboardShortcut("s", modifiers: [])
            Button { onDecision(.allow, .notch) } label: {
                Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.tint(.green).keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }

    static let cardWidth: CGFloat = 380
}
