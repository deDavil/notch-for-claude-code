import SwiftUI

/// Expanded permission card. Two shapes:
///  - AskUserQuestion → the question rendered plainly with its options as
///    tappable buttons (answering flows back via `.answer`).
///  - any other tool → tool + full context (cwd, reason, diff / full command) +
///    Allow / Session / Deny.
/// The body scrolls within a bounded height so long content doesn't grow the panel.
struct RequestCardView: View {
    let request: PendingRequest
    let queuedBehind: Int
    let onDecision: (Decision, DecisionSource) -> Void

    private var s: ToolSummary { request.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let ask = s.ask {
                askBody(ask)
            } else {
                standardBody
            }
        }
        .padding(14)
        .frame(width: RequestCardView.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.93)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: s.icon).foregroundStyle(.orange)
            Text(request.sessionLabel)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let diff = s.diff {
                Text(TextDiff.stat(diff))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if queuedBehind > 0 {
                Text("+\(queuedBehind)")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
        }
    }

    // MARK: AskUserQuestion

    @ViewBuilder private func askBody(_ ask: AskContent) -> some View {
        if let cwd = s.cwd {
            Label(cwd, systemImage: "folder").font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if ask.isSimple, let q = ask.first {
            Text(q.question).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(q.options) { opt in
                        Button {
                            onDecision(.answer([q.question: opt.label]), .notch)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.label).font(.system(size: 13, weight: .semibold))
                                if !opt.description.isEmpty {
                                    Text(opt.description).font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
            denyOnly
        } else {
            // Multi-question / multi-select: list everything, answer in terminal.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(ask.questions) { q in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(q.question).font(.system(size: 13, weight: .semibold))
                            ForEach(q.options) { opt in
                                Text("• \(opt.label)").font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            Text("Multi-part question — answer in the terminal.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            allowSessionDeny
        }
    }

    // MARK: standard tool

    @ViewBuilder private var standardBody: some View {
        Text(s.title).font(.system(size: 13, weight: .semibold))
        if let cwd = s.cwd {
            Label(cwd, systemImage: "folder").font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if let reason = s.reason, !reason.isEmpty {
            Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).italic().lineLimit(3)
        }
        toolBody
        allowSessionDeny
    }

    @ViewBuilder private var toolBody: some View {
        if let diff = s.diff, !diff.isEmpty {
            ScrollView { diffView(diff) }.frame(maxHeight: 240)
        } else if let full = s.fullText, !full.isEmpty {
            ScrollView {
                Text(full).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180).padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        }
    }

    private func diffView(_ diff: [DiffLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff) { line in
                HStack(alignment: .top, spacing: 4) {
                    Text(prefix(line.kind)).foregroundStyle(color(line.kind).opacity(0.8))
                    Text(line.text.isEmpty ? " " : line.text)
                        .foregroundStyle(color(line.kind)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 0.5)
                .background(bg(line.kind))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
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

    // MARK: button rows

    private var allowSessionDeny: some View {
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

    private var denyOnly: some View {
        Button { onDecision(.deny(reason: "Dismissed via notch overlay"), .notch) } label: {
            Label("Dismiss", systemImage: "xmark").frame(maxWidth: .infinity)
        }
        .tint(.red).buttonStyle(.borderedProminent).controlSize(.small)
        .keyboardShortcut("n", modifiers: [])
    }

    static let cardWidth: CGFloat = 440
}
