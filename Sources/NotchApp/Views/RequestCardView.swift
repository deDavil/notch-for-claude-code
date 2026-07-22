import SwiftUI

/// The expanded permission card: session + tool summary + Approve / Deny /
/// Allow-for-session. Buttons resolve through the store (first-wins arbiter).
struct RequestCardView: View {
    let request: PendingRequest
    let queuedBehind: Int
    let onDecision: (Decision, DecisionSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: request.summary.icon)
                    .foregroundStyle(.orange)
                Text(request.sessionLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if queuedBehind > 0 {
                    Text("+\(queuedBehind) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }

            Text(request.summary.title)
                .font(.system(size: 13, weight: .semibold))
            if !request.summary.detail.isEmpty {
                Text(request.summary.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    onDecision(.deny(reason: "Denied via notch overlay"), .notch)
                } label: {
                    Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .tint(.red)
                .keyboardShortcut("n", modifiers: [])

                Button {
                    onDecision(.allowForSession, .notch)
                } label: {
                    Text("Session").frame(maxWidth: .infinity)
                }
                .keyboardShortcut("s", modifiers: [])

                Button {
                    onDecision(.allow, .notch)
                } label: {
                    Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: RequestCardView.cardWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    static let cardWidth: CGFloat = 340
}
