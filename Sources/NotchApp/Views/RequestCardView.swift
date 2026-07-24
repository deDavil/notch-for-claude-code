import SwiftUI

/// Expanded permission card. Two shapes:
///  - AskUserQuestion → an answer form: every question's options are selectable
///    (single or multi), each also takes a free-text answer, and Send submits
///    them all at once (flows back via `.answer`).
///  - any other tool → tool + full context (cwd, reason, diff / full command) +
///    Allow / Session / Deny.
struct RequestCardView: View {
    let request: PendingRequest
    let queuedBehind: Int
    let onDecision: (Decision, DecisionSource) -> Void

    // AskUserQuestion form state (keyed by question id). Reset per request via .id().
    @State private var selections: [UUID: Set<String>] = [:]
    @State private var otherText: [UUID: String] = [:]

    private var s: ToolSummary { request.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let ask = s.ask {
                askForm(ask)
            } else if let plan = s.plan {
                planBody(plan)
            } else {
                standardBody
            }
        }
        .padding(14)
        .frame(width: RequestCardView.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.93)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: s.icon).foregroundStyle(.orange)
            Text(request.sessionLabel)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            if let diff = s.diff {
                Text(TextDiff.stat(diff)).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if queuedBehind > 0 {
                Text("+\(queuedBehind)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.secondary.opacity(0.15)))
            }
            // Close without giving Claude any input → it falls back to the terminal.
            Button { onDecision(.noOpinion, .notch) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close — answer in the terminal instead")
        }
    }

    // MARK: - AskUserQuestion answer form

    @ViewBuilder private func askForm(_ ask: AskContent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ask.questions) { q in
                    questionBlock(q)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 340)

        HStack(spacing: 8) {
            Button { onDecision(.deny(reason: "Dismissed via notch overlay"), .notch) } label: {
                Label("Dismiss", systemImage: "xmark").frame(maxWidth: .infinity)
            }.tint(.red).keyboardShortcut("n", modifiers: [])
            Button { submitAnswers(ask) } label: {
                Label("Send", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
            }.tint(.green).keyboardShortcut(.defaultAction).disabled(!allAnswered(ask))
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }

    @ViewBuilder private func questionBlock(_ q: AskContent.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(q.question).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if q.multiSelect {
                    Text("multi").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.secondary.opacity(0.15)))
                }
            }
            ForEach(q.options) { opt in
                optionRow(q, opt)
            }
            otherField(q)
        }
    }

    private func optionRow(_ q: AskContent.Question, _ opt: AskContent.Option) -> some View {
        let on = isSelected(q, opt)
        return Button {
            toggle(q, opt)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                     : (q.multiSelect ? "square" : "circle"))
                    .foregroundStyle(on ? .green : .secondary)
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(opt.label).font(.system(size: 12, weight: .semibold))
                    if !opt.description.isEmpty {
                        Text(opt.description).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? .green.opacity(0.12) : .white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? .green.opacity(0.4) : .white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func otherField(_ q: AskContent.Question) -> some View {
        TextField("Type your own answer…", text: bindingOther(q), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...4)
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                (otherText[q.id]?.isEmpty == false) ? .green.opacity(0.4) : .white.opacity(0.08), lineWidth: 1))
    }

    // MARK: form logic

    private func bindingOther(_ q: AskContent.Question) -> Binding<String> {
        Binding(get: { otherText[q.id] ?? "" },
                set: { v in otherText[q.id] = v; if !v.isEmpty { selections[q.id] = [] } })
    }

    private func isSelected(_ q: AskContent.Question, _ opt: AskContent.Option) -> Bool {
        (otherText[q.id]?.isEmpty ?? true) && (selections[q.id]?.contains(opt.label) ?? false)
    }

    private func toggle(_ q: AskContent.Question, _ opt: AskContent.Option) {
        otherText[q.id] = ""
        var sel = selections[q.id] ?? []
        if q.multiSelect {
            if sel.contains(opt.label) { sel.remove(opt.label) } else { sel.insert(opt.label) }
        } else {
            sel = [opt.label]
        }
        selections[q.id] = sel
    }

    private func answer(for q: AskContent.Question) -> String {
        let other = (otherText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !other.isEmpty { return other }
        let sel = selections[q.id] ?? []
        return q.options.filter { sel.contains($0.label) }.map { $0.label }.joined(separator: ", ")
    }

    private func allAnswered(_ ask: AskContent) -> Bool {
        ask.questions.allSatisfy { !answer(for: $0).isEmpty }
    }

    private func submitAnswers(_ ask: AskContent) {
        var answers: [String: String] = [:]
        for q in ask.questions { answers[q.question] = answer(for: q) }
        onDecision(.answer(answers), .notch)
    }

    // MARK: - ExitPlanMode

    @ViewBuilder private func planBody(_ plan: String) -> some View {
        Text(s.title).font(.system(size: 13, weight: .semibold))
        if let cwd = s.cwd {
            Label(cwd, systemImage: "folder").font(.system(size: 10))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        PlanView(markdown: plan)
        HStack(spacing: 8) {
            Button { onDecision(.deny(reason: "Plan rejected — keep planning"), .notch) } label: {
                Label("Reject", systemImage: "xmark").frame(maxWidth: .infinity)
            }.tint(.red).keyboardShortcut("n", modifiers: [])
            Button { onDecision(.allow, .notch) } label: {
                Label("Approve & build", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.tint(.green).keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }

    // MARK: - standard tool

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
                .padding(.horizontal, 4).padding(.vertical, 0.5).background(bg(line.kind))
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

    private var allowSessionDeny: some View {
        HStack(spacing: 8) {
            Button { onDecision(.deny(reason: "Denied via notch overlay"), .notch) } label: {
                Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
            }.tint(.red).keyboardShortcut("n", modifiers: [])
            Button { onDecision(.allowForSession, .notch) } label: {
                Text("Session").frame(maxWidth: .infinity)
            }.keyboardShortcut("s", modifiers: [])
            .help("Allow this for the rest of this session")
            Button { onDecision(.allowForProject, .notch) } label: {
                Label("Always", systemImage: "pin").frame(maxWidth: .infinity)
            }.keyboardShortcut("p", modifiers: [])
            .help("Always allow this in this project (persists)")
            Button { onDecision(.allow, .notch) } label: {
                Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
            }.tint(.green).keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
    }

    static let cardWidth: CGFloat = 440
}
