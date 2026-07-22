import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey — no Accessibility (TCC) prompt,
/// unlike NSEvent global monitors. Registered only while a request is pending so
/// the chords never shadow other apps at rest.
///
///   ⌃⌥Y approve · ⌃⌥N deny · ⌃⌥U dismiss (answer in terminal)
@MainActor
final class HotKeys {
    enum Action: UInt32 { case approve = 1, deny = 2, dismiss = 3 }

    var onAction: ((Action) -> Void)?

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var installed = false
    private var active = false

    private let signature: OSType = 0x4E4F5443 // 'NOTC'

    func enable() {
        guard !active else { return }
        active = true
        installHandlerIfNeeded()

        let ctrlOpt = UInt32(controlKey | optionKey)
        register(keyCode: UInt32(kVK_ANSI_Y), modifiers: ctrlOpt, action: .approve)
        register(keyCode: UInt32(kVK_ANSI_N), modifiers: ctrlOpt, action: .deny)
        register(keyCode: UInt32(kVK_ANSI_U), modifiers: ctrlOpt, action: .dismiss)
    }

    func disable() {
        guard active else { return }
        active = false
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    // MARK: -

    private func register(keyCode: UInt32, modifiers: UInt32, action: Action) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs.append(ref) }
        else { Log.ui.error("RegisterEventHotKey failed: \(status)") }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if err == noErr, let action = HotKeys.Action(rawValue: hkID.id) {
                let mgr = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onAction?(action) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handler)
    }
}
