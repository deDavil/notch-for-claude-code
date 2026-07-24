import SwiftUI

/// Top-level content of the notch panel. Priority: a pending request card wins;
/// then the user-opened cockpit; then a transient toast; else the collapsed pill
/// (which is clickable to open the cockpit). The panel frame is resized to match
/// by PanelController.
struct RootView: View {
    @ObservedObject var store: RequestStore
    @ObservedObject var registry: SessionRegistry
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
                .id(front.id)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if registry.cockpitOpen {
                CockpitView(registry: registry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if let toast = store.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                CollapsedView(pendingCount: store.pending.count,
                              aggregate: registry.aggregate,
                              paused: store.paused,
                              cornerRadius: collapsedCornerRadius)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if !registry.sessions.isEmpty { registry.cockpitOpen = true }
                    }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.pending.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.toast)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: registry.cockpitOpen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
