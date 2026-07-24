import CoreAudio
import Foundation

/// Watches whether ANY app is using the default input device (microphone) via
/// CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere — a public,
/// observable signal that needs no TCC permission. Mic in use ≈ the operator is
/// on a call or recording ≈ the notch should keep quiet (auto-pause).
///
/// Also re-arms itself when the default input device changes (AirPods connect,
/// etc.). All failures degrade to "not in use" — the feature silently disables
/// rather than ever breaking the approval path.
final class MicMonitor {
    /// Fired on the main queue whenever mic-in-use changes.
    var onChange: ((Bool) -> Void)?

    private(set) var inUse = false
    private var deviceID = kAudioObjectUnknown
    private let queue = DispatchQueue.main

    private lazy var runningListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.refresh()
    }
    private lazy var defaultDeviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.rearm()
    }

    func start() {
        // Watch for the default input device changing…
        var addr = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, defaultDeviceListener)
        // …and arm on the current one.
        rearm()
    }

    private func rearm() {
        // Detach from the previous device.
        if deviceID != kAudioObjectUnknown {
            var running = Self.runningSomewhereAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &running, queue, runningListener)
        }
        deviceID = Self.currentDefaultInputDevice()
        if deviceID != kAudioObjectUnknown {
            var running = Self.runningSomewhereAddress
            AudioObjectAddPropertyListenerBlock(deviceID, &running, queue, runningListener)
        }
        refresh()
    }

    private func refresh() {
        let now = Self.isRunningSomewhere(deviceID)
        guard now != inUse else { return }
        inUse = now
        Log.app.info("mic in use: \(now)")
        onChange?(now)
    }

    // MARK: - CoreAudio plumbing

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static var runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func currentDefaultInputDevice() -> AudioObjectID {
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr ? device : kAudioObjectUnknown
    }

    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = runningSomewhereAddress
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return status == noErr && running != 0
    }
}
