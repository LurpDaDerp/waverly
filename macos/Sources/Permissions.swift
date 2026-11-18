// Permissions.swift — the three permissions Waverly asks for, in one place for the
// setup wizard and Settings: Camera (hand gestures), Accessibility (fn ⇧ H and
// Esc from any app) and Location (local weather). Each one is optional.
//
// macOS doesn't announce most permission changes, so `refresh()` re-reads them;
// the permission views call it while they are on screen. It also re-reads the macOS
// Video Effects that are on for Waverly (CameraGate.swift), shown under Camera.

import AppKit
import ApplicationServices
import AVFoundation
import CoreLocation

enum PermissionState { case granted, denied, notDetermined }
enum PermissionKind { case camera, accessibility, location }

@MainActor final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var camera: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined   // macOS can't report "denied"
    @Published private(set) var location: PermissionState = .notDetermined
    @Published private(set) var videoEffects = VideoEffects()

    private var accessibilityPoll: Timer?
    private var accessibilityPollUntil = Date.distantPast

    private init() { refresh() }

    func refresh() {
        let c = Self.cameraState()
        if c != camera { camera = c }
        let a: PermissionState = AXIsProcessTrusted() ? .granted : .notDetermined
        if a != accessibility { accessibility = a }
        let l = LocationService.shared.authorization
        if l != location { location = l }
        let v = VideoEffects.current()
        if v != videoEffects { videoEffects = v }
    }

    /// Asks for `kind`: the system prompt when it hasn't been asked yet, else the
    /// right pane of System Settings.
    func request(_ kind: PermissionKind) {
        refresh()
        switch kind {
        case .camera:
            switch camera {
            case .granted: return
            case .denied: openSystemSettings(.camera)
            case .notDetermined:
                NSApp.activate(ignoringOtherApps: true)
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        AppLog.info("camera access \(granted ? "allowed" : "not allowed")")
                        Permissions.shared.refresh()
                    }
                }
            }
        case .accessibility:
            guard accessibility != .granted else { return }
            // Adds Waverly to the list in System Settings (switched off) and shows the
            // system's explanation; the pane is where the switch is.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if AXIsProcessTrustedWithOptions(opts) { refresh(); return }
            openSystemSettings(.accessibility)
            pollAccessibility()
        case .location:
            switch location {
            case .granted: LocationService.shared.refresh()
            case .denied: openSystemSettings(.location)
            case .notDetermined: LocationService.shared.requestAuthorization()
            }
        }
    }

    func openSystemSettings(_ kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .camera: anchor = "Privacy_Camera"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .location: anchor = "Privacy_LocationServices"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
        if kind == .accessibility { pollAccessibility() }
    }

    /// The Accessibility switch is flipped in System Settings: watch for it once a
    /// second for up to two minutes (the hotkeys start as soon as it is on).
    private func pollAccessibility() {
        accessibilityPollUntil = Date().addingTimeInterval(120)
        guard accessibilityPoll == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let me = Permissions.shared
                me.refresh()
                if me.accessibility == .granted || Date() > me.accessibilityPollUntil {
                    me.accessibilityPoll?.invalidate()
                    me.accessibilityPoll = nil
                    if me.accessibility == .granted { AppLog.info("Accessibility permission granted") }
                }
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        accessibilityPoll = t
    }

    private static func cameraState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
