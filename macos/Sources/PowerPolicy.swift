// PowerPolicy.swift — when watching the camera is not worth the battery.
//
// CameraGate owns one and pauses the camera (pause reason "display") while the
// display is asleep and the Mac runs on battery or in Low Power Mode: nobody is
// looking at the screen, and the camera, Vision and the engine together cost far
// more than a background app should. The camera starts again the moment the
// display wakes (any key, the trackpad, opening the lid). On power adapter the
// camera keeps watching while the display sleeps, so a wake gesture can still
// turn the display on. (Screen lock, system sleep and a switched-out user session
// pause the camera too; AppDelegate reports those.)
//
// Self-contained: it observes NSWorkspace, the IOKit power-source notification and
// Low Power Mode itself. Create it on the main thread; `onChange` runs there.

import AppKit
import IOKit.ps

final class PowerPolicy {
    private(set) var displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private(set) var onBattery = false
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Called on the main thread whenever one of the above changes.
    var onChange: ((PowerPolicy) -> Void)?

    var shouldPauseCamera: Bool { displayAsleep && (onBattery || lowPowerMode) }

    /// For the log, e.g. "battery, display asleep, Low Power Mode".
    var summary: String {
        var parts = [onBattery ? "battery" : "power adapter"]
        if displayAsleep { parts.append("display asleep") }
        if lowPowerMode { parts.append("Low Power Mode") }
        return parts.joined(separator: ", ")
    }

    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    init() {
        onBattery = Self.readOnBattery()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.update { $0.displayAsleep = true }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.update { $0.displayAsleep = false }
        })
        // posted on an arbitrary thread
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.update { $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let policy = Unmanaged<PowerPolicy>.fromOpaque(ctx).takeUnretainedValue()
            policy.update { $0.onBattery = PowerPolicy.readOnBattery() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)   // also while a menu is open
            powerSource = source
        }
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        if let s = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
    }

    private func update(_ change: (PowerPolicy) -> Void) {
        let before = (displayAsleep, onBattery, lowPowerMode)
        change(self)
        if before != (displayAsleep, onBattery, lowPowerMode) { onChange?(self) }
    }

    static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
