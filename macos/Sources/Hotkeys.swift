// Hotkeys.swift — the keyboard shortcut (Settings › Controls, default fn ⇧ H)
// opens Waverly from anywhere and closes it again; Esc also closes it.
//
// fn cannot be part of a Carbon RegisterEventHotKey shortcut, so this uses a
// Quartz event tap (CGEvent.tapCreate, .cgSessionEventTap, .defaultTap) on
// key-down events and checks the fn ("secondary fn") flag. A tap that can
// consume events needs the Accessibility permission (System Settings > Privacy &
// Security > Accessibility). Only the setup wizard and Settings ask for it; the
// app keeps working without it (menu bar, gestures, and the shortcut and Esc while a
// Waverly window has keyboard focus: AppDelegate's local key monitor). Until
// it is granted this checks every few seconds for five minutes, then twice a minute
// (and whenever Waverly becomes active); once the tap is installed it only looks in
// on it twice a minute.
//
// The shortcut is read from ConfigStore on every key press (a change applies at
// once). It matches only with exactly its modifiers and is then always consumed, so
// the focused app does not also get the key. Esc is consumed only while Waverly is
// visible. Key repeats are ignored (but still consumed). While the Settings
// recorder listens for a new shortcut, everything passes through to it.

import AppKit
import ApplicationServices
import Carbon.HIToolbox   // kVK_Escape

final class Hotkeys {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    var isHUDVisible: () -> Bool = { false }
    /// The current shortcut (ConfigStore.hotkey).
    var shortcut: () -> Shortcut = { .default }
    private(set) var installed = false

    /// Set while the Settings shortcut recorder is listening: the tap lets every key through.
    static var recording = false

    enum Action: Equatable {
        case pass                  // not ours: the focused app gets it
        case consume               // ours, nothing to do (a key repeat)
        case open, close           // ours: consume and act
    }

    /// What to do with a key-down (pure, so it can be tested with synthetic events).
    static func action(keyCode: Int, flags: CGEventFlags, isRepeat: Bool, shortcut: Shortcut,
                       visible: Bool, recording: Bool) -> Action {
        if recording { return .pass }
        if shortcut.matches(keyCode: keyCode, flags: flags) {
            return isRepeat ? .consume : (visible ? .close : .open)
        }
        if keyCode == kVK_Escape, visible {
            return isRepeat ? .consume : .close          // consume only while Waverly is up
        }
        return .pass
    }

    static func action(for event: CGEvent, shortcut: Shortcut, visible: Bool, recording: Bool = false) -> Action {
        action(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
               isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
               shortcut: shortcut, visible: visible, recording: recording)
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var waitingSince = Date()            // when the current wait for the permission began
    private var tapFailed = false                // "could not create the event tap" is logged once

    func start() {
        guard timer == nil else { return }
        if AXIsProcessTrusted() {
            install()
        } else {
            AppLog.info("hotkeys: waiting for the Accessibility permission (\(shortcut().display))")
        }
        schedule(waitAgain: true)
    }

    /// Look now (the app became active, or the permission was just granted).
    func checkNow() {
        guard timer != nil else { return }
        check()
        if tap == nil && timer?.timeInterval != 3 { schedule(waitAgain: true) }   // quick checks again for a while
    }

    /// Every 3 s for the first five minutes of waiting for the permission, then
    /// every 30 s (checkNow covers the usual moments: the app becomes active, or
    /// Settings / the setup wizard sees the switch flip); every 30 s once the tap
    /// runs (macOS turning the tap off is also reported to the tap itself).
    private func schedule(waitAgain: Bool) {
        timer?.invalidate()
        if waitAgain { waitingSince = Date() }
        let quick = tap == nil && Date().timeIntervalSince(waitingSince) < 300
        let interval: TimeInterval = quick ? 3 : 30
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = interval / 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let had = tap != nil
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                if AXIsProcessTrusted() { CGEvent.tapEnable(tap: tap, enable: true) } else { uninstall() }
            } else if !AXIsProcessTrusted() {
                uninstall()
            }
        } else if AXIsProcessTrusted() {
            install()
        }
        if had != (tap != nil) {
            schedule(waitAgain: true)
        } else if tap == nil, timer?.timeInterval == 3, Date().timeIntervalSince(waitingSince) >= 300 {
            schedule(waitAgain: false)                     // still not allowed: look less often
        }
    }

    private func install() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: Hotkeys.callback, userInfo: me) else {
            if !tapFailed { AppLog.warning("hotkeys: could not create the event tap") }
            tapFailed = true
            return
        }
        tapFailed = false
        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        installed = true
        AppLog.info("hotkeys: \(shortcut().display) and Esc active")
    }

    private func uninstall() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CFMachPortInvalidate(t) }
        source = nil
        tap = nil
        installed = false
        AppLog.warning("hotkeys: Accessibility permission was removed; waiting for it again")
    }

    fileprivate func reenable() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
    }

    /// Runs on the main thread (the tap's run loop source is on the main run loop).
    private static let callback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<Hotkeys>.fromOpaque(info).takeUnretainedValue()
        // macOS disables a tap that is slow or interrupted; turn it straight back on
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            me.reenable()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        switch action(for: event, shortcut: me.shortcut(), visible: me.isHUDVisible(), recording: recording) {
        case .pass: return Unmanaged.passUnretained(event)
        case .consume: return nil
        case .open:
            DispatchQueue.main.async { me.onOpen?() }
            return nil
        case .close:
            DispatchQueue.main.async { me.onClose?() }
            return nil
        }
    }
}
