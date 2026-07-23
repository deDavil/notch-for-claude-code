import SwiftUI

/// The resting state: a black shape that blends into the notch, with a small
/// status dot. On a virtual notch (dev) it's a top-center pill.
struct CollapsedView: View {
    var pendingCount: Int
    var aggregate: SessionState? = nil
    var cornerRadius: CGFloat = 10

    private var dotColor: Color {
        if pendingCount > 0 { return .orange }
        if let aggregate { return StateColor.of(aggregate) }
        return .green.opacity(0.5)
    }

    var body: some View {
        ZStack {
            // Rounded-bottom black shape (top edge flush with the physical notch/screen top).
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius, topTrailingRadius: 0)
                .fill(Color.black)

            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .padding(.bottom, 2)
        }
    }
}
