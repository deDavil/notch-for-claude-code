import AppKit
import SwiftUI

/// Colour for a session state, shared by the pill dot and cockpit rows.
enum StateColor {
    static func of(_ s: SessionState) -> Color {
        switch s {
        case .waitingApproval: return .orange
        case .waitingInput: return .yellow
        case .working: return .green
        case .idle: return .secondary
        }
    }
}

/// The expanded cockpit: a live list of every session with its state and how
/// long since it last did anything.
struct CockpitView: View {
    @ObservedObject var registry: SessionRegistry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Text("\(registry.sessions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { registry.cockpitOpen = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            if registry.sessions.isEmpty {
                Text("No active sessions").font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(registry.ordered) { s in row(s) }
                    }
                }.frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: RequestCardView.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.93)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func row(_ s: SessionInfo) -> some View {
        Button {
            jump(to: s)
        } label: {
            HStack(spacing: 9) {
                Circle().fill(StateColor.of(s.displayState)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle(s))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if s.pending > 0 {
                    Text("\(s.pending)").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                }
                if s.hostPid != nil {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(s.hostPid != nil ? "Jump to \(s.hostApp ?? "session")" : "Hosting app unknown")
    }

    private func subtitle(_ s: SessionInfo) -> String {
        var parts = ["\(s.displayState.label) · \(Self.relative(s.lastActivity))"]
        if let app = s.hostApp { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    /// Activate the GUI app hosting this session (from the hook's ancestry walk).
    private func jump(to s: SessionInfo) {
        guard let pid = s.hostPid,
              let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
        registry.cockpitOpen = false
    }

    private static func relative(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
