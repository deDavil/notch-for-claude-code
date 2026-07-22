import AppKit
import SwiftUI
import Combine

/// Owns the notch panel: hosts the SwiftUI content, positions it at the notch,
/// and animates between the collapsed pill and the expanded card as the store's
/// pending queue changes. Recomputes geometry on display changes.
@MainActor
final class PanelController {
    private let store: RequestStore
    private let settings: AppSettings
    private let panel = NotchPanel()
    private let hostingView: NSHostingView<RootView>
    private var geometry: NotchGeometry
    private var cancellables: Set<AnyCancellable> = []

    init(store: RequestStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        self.geometry = NotchGeometry.current(forceVirtual: settings.virtualNotch)
        let corner: CGFloat = geometry.mode == .virtual ? 10 : 8
        self.hostingView = NSHostingView(
            rootView: RootView(store: store, collapsedCornerRadius: corner))
        panel.contentView = hostingView
    }

    func show() {
        applyCollapsed(animated: false)
        panel.orderFrontRegardless()

        // React to queue changes: expand when work arrives, collapse when clear.
        store.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                self?.updateForPending(count: pending.count)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeGeometry()
            }
            .store(in: &cancellables)
    }

    private func updateForPending(count: Int) {
        if count > 0 {
            applyExpanded(animated: true)
        } else {
            applyCollapsed(animated: true)
        }
    }

    private func applyCollapsed(animated: Bool) {
        setFrame(geometry.collapsedFrame, animated: animated)
    }

    private func applyExpanded(animated: Bool) {
        let size = measuredCardSize()
        setFrame(geometry.expandedFrame(cardSize: size), animated: animated)
    }

    /// Lay out the SwiftUI content at the card width and read back its fitting
    /// height so the panel frame hugs the card (no dead click zones).
    private func measuredCardSize() -> NSSize {
        let width = RequestCardView.cardWidth
        hostingView.setFrameSize(NSSize(width: width, height: 400))
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let height = fitting.height > 0 ? fitting.height : 160
        return NSSize(width: width, height: height)
    }

    private func setFrame(_ frame: NSRect, animated: Bool) {
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func recomputeGeometry() {
        geometry = NotchGeometry.current(forceVirtual: settings.virtualNotch)
        updateForPending(count: store.pending.count)
        Log.ui.info("geometry: mode=\(self.geometry.mode == .real ? "real" : "virtual", privacy: .public) notch=\(String(describing: self.geometry.notchRect), privacy: .public)")
    }
}
