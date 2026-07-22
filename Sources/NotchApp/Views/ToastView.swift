import SwiftUI

/// Compact passive-notification pill shown under the notch, auto-dismissed.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.icon)
                .foregroundStyle(.secondary)
            Text(toast.text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(
            Capsule().fill(.black.opacity(0.9))
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
    }
}
