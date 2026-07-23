import AppKit
import SwiftUI
import Combine

/// Hosting view that responds to the FIRST click even when the panel isn't the
/// key window. Without this, macOS swallows the first click on a non-activating
/// panel just to focus it, so option rows/buttons feel dead until a second click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch panel: hosts the SwiftUI content, positions it at the notch,
/// and animates between the collapsed pill and the expanded card as the store's
/// pending queue changes. Recomputes geometry on display changes.
@MainActor
final class PanelController {
    private let store: RequestStore
    private let registry: SessionRegistry
    private let settings: AppSettings
    private let panel = NotchPanel()
    private let hostingView: FirstMouseHostingView<RootView>
    private var geometry: NotchGeometry
    private var cancellables: Set<AnyCancellable> = []

    init(store: RequestStore, registry: SessionRegistry, settings: AppSettings) {
        self.store = store
        self.registry = registry
        self.settings = settings
        self.geometry = NotchGeometry.current(forceVirtual: settings.virtualNotch)
        let corner: CGFloat = geometry.mode == .virtual ? 10 : 8
        self.hostingView = FirstMouseHostingView(
            rootView: RootView(store: store, registry: registry, collapsedCornerRadius: corner))
        panel.contentView = hostingView
    }

    func show() {
        refreshPresentation(animated: false)
        panel.orderFrontRegardless()

        // Re-present whenever the queue or a toast changes.
        store.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPresentation(animated: true) }
            .store(in: &cancellables)
        store.$toast
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPresentation(animated: true) }
            .store(in: &cancellables)
        registry.$cockpitOpen
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPresentation(animated: true) }
            .store(in: &cancellables)
        registry.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPresentation(animated: true) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.recomputeGeometry()
            }
            .store(in: &cancellables)
    }

    /// Decide the panel size from current state: a card if something is pending,
    /// else a toast pill if one is showing, else the collapsed notch.
    private func refreshPresentation(animated: Bool) {
        let expanded = !store.pending.isEmpty
            || (registry.cockpitOpen && !registry.sessions.isEmpty)
            || store.toast != nil
        if expanded {
            let size = measuredCardSize()
            setFrame(geometry.expandedFrame(cardSize: size), animated: animated)
        } else {
            setFrame(geometry.collapsedFrame, animated: animated)
        }
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
        refreshPresentation(animated: false)
        Log.ui.info("geometry: mode=\(self.geometry.mode == .real ? "real" : "virtual", privacy: .public) notch=\(String(describing: self.geometry.notchRect), privacy: .public)")
    }
}
