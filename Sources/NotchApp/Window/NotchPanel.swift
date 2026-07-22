import AppKit

/// Borderless, non-activating panel that lives at the notch. Non-activating so
/// clicking Approve never steals focus from the editor/terminal. Floats above
/// full-screen apps via level + collectionBehavior.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar                     // menu-bar plane, where the notch is
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Allow the panel to receive clicks/keys when needed, without activating the app.
        becomesKeyOnlyIfNeeded = true
    }

    // Needed so SwiftUI controls inside can take keyboard focus if we ever want it,
    // while .nonactivatingPanel keeps the owning app from activating.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
