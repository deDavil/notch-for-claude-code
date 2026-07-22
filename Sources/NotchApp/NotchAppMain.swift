import AppKit

// LSUIElement accessory app: no SwiftUI App lifecycle, no Dock icon. Its only
// surfaces are a status item and a borderless notch panel, so we drive
// NSApplication directly. @MainActor keeps the delegate init on the main thread.
@main
enum NotchAppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
