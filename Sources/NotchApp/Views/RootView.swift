import SwiftUI

/// Top-level content of the notch panel. Renders the collapsed pill when idle,
/// or the front request card when something is pending. The panel frame is
/// resized to match by PanelController.
struct RootView: View {
    @ObservedObject var store: RequestStore
    var collapsedCornerRadius: CGFloat

    var body: some View {
        Group {
            if let front = store.frontRequest {
                RequestCardView(
                    request: front,
                    queuedBehind: max(0, store.pending.count - 1),
                    onDecision: { decision, source in
                        store.resolve(id: front.id, decision: decision, source: source)
                    })
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                CollapsedView(pendingCount: store.pending.count,
                              cornerRadius: collapsedCornerRadius)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.pending.count)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
