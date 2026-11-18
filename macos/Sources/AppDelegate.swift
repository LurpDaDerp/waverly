// AppDelegate.swift — wires the macOS app together.
//
//   CameraGate ──frames──▶ (frame ring) ──▶ hud-engine ──ws /vision──▶ hud-core ◀──ws /ws── page (WKWebView)
//        ▲                                                                  │  ▲
//        └──── camera-want / overlay requests ◀──── CoreLink (ws /ws) ◀──────┘  └── force, overlay-ready / -hidden, camera
//
// The engine owns the overlay's state (asleep → waking → awake → sleeping), exactly
// as on Linux. The app carries out its requests (show / hide the overlay, run
// the camera at the right rate, wake the display) and reports keyboard input.
// It also keeps the overlay in step with the engine if a helper dies, so an
// invisible overlay can never be left covering the screen.
//
// First launch: the setup wizard (OnboardingWindow.swift) asks for a name,
// permissions and preferences while the Python environment installs. The helpers,
// camera and hotkeys start only once setup is done and the environment is ready.

import AppKit
import Combine
import IOKit.pwr_mgt
import ServiceManagement
import WebKit

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, CameraGateDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)        // menu bar app, no Dock icon (also LSUIElement in Info.plist)
        withExtendedLifetime(delegate) { app.run() }
    }

    private let defaults = UserDefaults.standard
    private var port = ConfigStore.defaultPort
    private var supervisor: HelperSupervisor?
    private var overlay: OverlayController?
    private var link: CoreLink?
    private var ring: FrameRingWriter?
    private var camera: CameraGate?
    private let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var settingsItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var troubleItem: NSMenuItem!
    private var wizard: OnboardingWindowController?
    private var debug: DebugControl?
    private var signalSources: [DispatchSourceSignal] = []
    private var escMonitor: Any?
    private var servicesStarted = false
    private var forceQuit = false                  // a signal: quit without asking
    private var duplicateInstance = false          // another copy is running: this one quits and cleans up nothing
    private var helperTrouble: [String: String] = [:]   // crash-looping helpers, and why
    private var troubleAlertShown = false
    private var locationTimer: Timer?
    private var watchers: Set<AnyCancellable> = []
    private var installWatch: AnyCancellable?

    // overlay / engine bookkeeping
    private var overlayRequest = 0                 // newest show/hide request; a delayed show checks it
    private var engineState = "unknown"            // from the engine's vstat (every 2 s)
    private var engineSeen = Date.distantPast
    private var asleepWhileVisible = 0
    private var awakeWhileHidden = 0
    private var closeFailsafe: DispatchWorkItem?

    static var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: launch

    /// Logs a startup step that took long (diagnostics for slow launches).
    private var stepStart = Date()
    private func step(_ name: String) {
        let d = Date().timeIntervalSince(stepStart)
        if d > 0.5 { AppLog.warning(String(format: "startup: %@ took %.1f s", name, d)) }
        stepStart = Date()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        stepStart = Date()
        if let other = otherInstance() {
            AppLog.warning("Waverly is already running (pid \(other.processIdentifier)); this copy quits")
            forceQuit = true
            duplicateInstance = true
            NSApp.terminate(nil)
            return
        }
        installSignalHandlers()
        AppLog.info("Waverly \(Self.version) starting (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
        HelperSupervisor.prepareState()
        HudFont.register()
        HudWindow.installMainMenu()                // ⌘C / ⌘V / ⌘A / ⌘W in the app's own windows
        let config = ConfigStore.shared            // creates config.json on first launch (before the helpers read it)
        port = config.httpPort
        config.onSaved = { [weak self] in self?.link?.send(["t": "config-changed"]) }   // hud-core re-reads it at once
        LoginItemSetting.applyPending()
        step("state folders")

        // The frame ring exists before the engine starts, so it never maps a stale file.
        let support = HelperSupervisor.appSupport
        do {
            ring = try FrameRingWriter(fileURL: support.appendingPathComponent("frames.shm"),
                                       socketPath: support.appendingPathComponent("frames.sock").path)
        } catch {
            AppLog.error("could not create the frame ring: \(error.localizedDescription)")
        }
        step("frame ring")

        let supervisor = HelperSupervisor(port: port)
        supervisor.overlayShownAt = { [weak self] in self?.overlay?.shownAt }
        supervisor.onPageStale = { [weak self] in
            // a hidden page is throttled by WebKit, so only a visible page can be "stale"
            if self?.overlay?.isVisible == true { self?.overlay?.reload() }
        }
        supervisor.onCrashLoop = { [weak self] name, why in self?.helperKeepsStopping(name, why) }
        supervisor.onRecovered = { [weak self] name in
            self?.helperTrouble[name] = nil
            self?.refreshMenu()
        }
        self.supervisor = supervisor
        ring?.onRecreated = { [weak self] in DispatchQueue.main.async { self?.supervisor?.restart("engine") } }

        if let ring {
            camera = CameraGate(ring: ring, testVideo: TestVideoSource())
            camera?.delegate = self
        }
        step("camera")

        hotkeys.isHUDVisible = { [weak self] in self?.overlay?.isVisible ?? false }
        hotkeys.shortcut = { ConfigStore.shared.hotkey }           // read on every key press: changes apply at once
        hotkeys.onOpen = { [weak self] in self?.requestOpen("keyboard shortcut") }
        hotkeys.onClose = { [weak self] in self?.requestClose("keyboard") }
        // The shortcut and Esc while one of Waverly's own windows (the overlay, Settings) has
        // keyboard focus, even without the Accessibility permission. With it, the event tap
        // takes the shortcut first and this never sees it.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = Int(e.keyCode), flags = e.cgEvent?.flags ?? [], isRepeat = e.isARepeat
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, !Hotkeys.recording else { return false }
                let visible = self.overlay?.isVisible == true
                if ConfigStore.shared.hotkey.matches(keyCode: code, flags: flags) {
                    if !isRepeat {
                        if visible { self.requestClose("keyboard") } else { self.requestOpen("keyboard shortcut") }
                    }
                    return true
                }
                if code == 53, !isRepeat, visible { self.requestClose("Esc") }
                return false                                  // (53 = Esc) Esc also reaches the page
            }
            return consumed ? nil : e
        }

        buildMenu()
        step("menu bar item")
        observeSystem()
        GoogleAuth.shared.onFinish = { [weak self] ok in self?.googleFinished(ok) }
        debug = DebugControl { [weak self] cmd, reply in
            if let self { self.debugCommand(cmd, reply) } else { reply([:]) }
        }
        if config.onboarded { LocationService.shared.refresh() }
        proceed()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let installing = EnvironmentInstaller.shared.phase == .installing
        guard installing, !forceQuit, !systemIsQuittingUs() else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit Waverly?"
        a.informativeText = "Setup is still downloading. It starts again the next time you open Waverly."
        a.addButton(withTitle: "Continue Setup")
        a.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        EnvironmentInstaller.shared.cancel()
        return .terminateNow
    }

    /// Waverly was opened again while it runs (Finder, Spotlight, Launchpad): its menu
    /// bar item may be hidden behind the notch, so show the window it would open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let wizard { wizard.present() } else { openSettings() }
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        // a second copy that found Waverly running: the setup, helpers and frame ring are the other copy's
        guard !duplicateInstance else { return }
        AppLog.info("Waverly quitting")
        EnvironmentInstaller.shared.cancel()
        GoogleAuth.shared.cancel()
        // no camera frame may outlive the app: stop the camera, zero the frame ring and
        // delete it (the next launch makes a new one), then stop the helpers
        if let camera { camera.shutdown() } else { ring?.removeFiles() }
        supervisor?.stop()
    }

    /// Logout, restart and shutdown send a quit event with a reason: never hold those up.
    private func systemIsQuittingUs() -> Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    private func otherInstance() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first { $0.processIdentifier != me }
    }

    /// `kill`, logout and Ctrl-C quit through NSApp.terminate, so the helpers are stopped too.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                AppLog.info("received signal \(sig): quitting")
                self?.forceQuit = true
                NSApp.terminate(nil)
            }
            s.resume()
            signalSources.append(s)
        }
    }

    // MARK: setup → helpers, camera, hotkeys

    /// Setup wizard, or the environment, or straight to work.
    private func proceed() {
        guard ConfigStore.shared.onboarded else {
            AppLog.info("first launch: showing the setup wizard")
            showWizard(environmentOnly: false)
            return
        }
        if defaults.bool(forKey: "HUDNoHelpers") {          // developer: helpers are run by hand
            startServices(helpers: false)
            return
        }
        let installer = EnvironmentInstaller.shared
        installer.start()                                    // ready at once, or checks an existing venv
        switch installer.phase {
        case .ready:
            startServices(helpers: true)
        case .checking:
            installWatch = installer.$phase.dropFirst().sink { [weak self] phase in
                guard let self, phase != .checking else { return }
                self.installWatch = nil
                // after the published value has been stored
                DispatchQueue.main.async {
                    if phase == .ready { self.startServices(helpers: true) } else { self.showWizard(environmentOnly: true) }
                }
            }
        default:
            AppLog.info("Python environment missing: showing setup")
            showWizard(environmentOnly: true)
        }
    }

    private func showWizard(environmentOnly: Bool) {
        if let wizard { wizard.present(); return }
        let w = OnboardingWindowController(environmentOnly: environmentOnly) { [weak self] in
            guard let self else { return }
            self.wizard = nil
            AppLog.info("setup finished: starting")
            LocationService.shared.refresh()
            self.proceed()
        }
        wizard = w
        w.present()
    }

    private func startServices(helpers: Bool) {
        guard !servicesStarted else { return }
        servicesStarted = true
        if helpers { supervisor?.start() }

        let overlay = OverlayController(port: port, query: defaults.string(forKey: "HUDPageQuery") ?? "mac=1")
        self.overlay = overlay
        if defaults.bool(forKey: "HUDShowOnLaunch") {
            var once = false
            overlay.onPageLoaded = { [weak self] in
                guard let self, !once else { return }
                once = true
                self.overlay?.show {}
            }
        }
        let link = CoreLink(port: port)
        link.onMessage = { [weak self] in self?.handle($0) }
        link.onConnected = { [weak self] in
            guard let self else { return }
            self.link?.send(["t": "camera", "mode": (self.camera?.mode ?? .paused).rawValue])
        }
        self.link = link
        link.start()

        camera?.start()
        hotkeys.start()
        refreshMenu()
    }

    // MARK: requests from the engine (via hud-core)

    private func handle(_ d: [String: Any]) {
        switch d["t"] as? String {
        case "overlay":
            if d["prepare"] as? Bool == true {
                DisplayWaker.wakeIfAsleep()                   // a wake gesture started: wake the screen early
            } else if d["show"] as? Bool == true {
                showOverlay()
            } else if d["show"] as? Bool == false {
                hideOverlay(confirm: true)
            }
        case "camera-want":
            camera?.engineWantsActive = d["active"] as? Bool ?? false
        case "vstat":
            engineStatus(d)
        default:
            break                                             // data, scroll, head, wake, sleep, state: for the page
        }
    }

    private func showOverlay() {
        guard let overlay else { return }
        overlayRequest += 1
        let req = overlayRequest
        closeFailsafe?.cancel()
        camera?.overlayVisible = true                         // full frame rate from now on
        DisplayWaker.wakeIfAsleep { [weak self] in            // like Linux waits for the monitor
            guard let self, req == self.overlayRequest else { return }
            self.asleepWhileVisible = 0
            overlay.show {
                guard req == self.overlayRequest else { return }
                self.link?.send(["t": "overlay-ready"])
            }
            AppLog.info("overlay shown")
        }
    }

    private func hideOverlay(confirm: Bool) {
        guard let overlay else { return }
        overlayRequest += 1
        closeFailsafe?.cancel()
        let was = overlay.isVisible
        overlay.hide {
            self.camera?.overlayVisible = false
            if confirm { self.link?.send(["t": "overlay-hidden"]) }
        }
        if was { AppLog.info("overlay hidden") }
    }

    /// Keep the overlay in step with the engine, whatever happened to a helper.
    private func engineStatus(_ d: [String: Any]) {
        guard let overlay else { return }
        engineState = d["state"] as? String ?? "unknown"
        engineSeen = Date()
        if overlay.isVisible && engineState == "asleep" {
            asleepWhileVisible += 1
            if asleepWhileVisible >= 2 {                      // ~2-4 s: e.g. the engine restarted while open
                AppLog.warning("overlay visible but the engine is asleep; hiding it")
                hideOverlay(confirm: false)
            }
        } else {
            asleepWhileVisible = 0
        }
        if !overlay.isVisible && engineState == "awake" {
            awakeWhileHidden += 1
            if awakeWhileHidden == 3 {                        // the engine thinks the overlay is on screen: close it
                AppLog.warning("engine awake but the overlay is hidden; asking it to close")
                link?.send(["t": "force", "awake": false])
            }
        } else {
            awakeWhileHidden = 0
        }
    }

    // MARK: keyboard / menu

    private func requestOpen(_ why: String) {
        guard servicesStarted else { return }
        AppLog.info("open requested (\(why))")
        link?.send(["t": "force", "awake": true])
    }

    private func requestClose(_ why: String, attempt: Int = 1) {
        guard servicesStarted else { return }
        if attempt == 1 { AppLog.info("close requested (\(why))") }
        link?.send(["t": "force", "awake": false])
        guard overlay?.isVisible == true else { return }
        // Failsafe: the normal close takes as long as the close animation (Settings: at most
        // 1.5 s), and at most ~3.6 s if the page does not answer (the engine waits up to
        // 3.5 s for it). If the overlay is still up after 5 s, the engine is gone or ignored
        // us: ask again while it is alive, else hide the overlay ourselves.
        closeFailsafe?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.overlay?.isVisible == true else { return }
            let alive = Date().timeIntervalSince(self.engineSeen) < 5
            if alive && attempt < 3 && (self.engineState == "awake" || self.engineState == "waking") {
                self.requestClose(why, attempt: attempt + 1)
            } else {
                AppLog.warning("Waverly still open 5 s after \(why); hiding the overlay")
                self.hideOverlay(confirm: true)
            }
        }
        closeFailsafe = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    /// Called on the main queue.
    nonisolated func cameraGate(_ gate: CameraGate, didChangeMode mode: CameraGate.Mode) {
        MainActor.assumeIsolated {
            link?.send(["t": "camera", "mode": mode.rawValue])
            pauseItem?.state = gate.userPaused ? .on : .off
        }
    }

    // MARK: system events: never run the camera while locked, asleep or switched out

    private func observeSystem() {
        /// Observers on the main queue: run `body` on the main actor.
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (AppDelegate) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        observe(dnc, .init("com.apple.screenIsLocked")) { me in
            AppLog.info("screen locked")
            me.camera?.pause(reason: "locked")
            if me.overlay?.isVisible == true { me.requestClose("screen lock") }
        }
        observe(dnc, .init("com.apple.screenIsUnlocked")) { me in
            AppLog.info("screen unlocked")
            me.camera?.resume(reason: "locked")
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { me in
            AppLog.info("system going to sleep")
            me.camera?.pause(reason: "sleep")
        }
        observe(ws, NSWorkspace.didWakeNotification) { me in
            AppLog.info("system woke")
            me.camera?.resume(reason: "sleep")
            // after the network is back
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated {
                    if ConfigStore.shared.onboarded { LocationService.shared.refresh() }
                }
            }
        }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { me in
            AppLog.info("user session inactive (fast user switching)")
            me.camera?.pause(reason: "session")
            if me.overlay?.isVisible == true { me.requestClose("user switch") }
        }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { me in
            me.camera?.resume(reason: "session")
        }
        // the Accessibility or Camera switch may have been flipped while Waverly was in the background
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { me in
            me.hotkeys.checkNow()
            me.camera?.permissionChanged()
        }
        Permissions.shared.$accessibility.removeDuplicates().sink { [weak self] s in
            if s == .granted { DispatchQueue.main.async { MainActor.assumeIsolated { self?.hotkeys.checkNow() } } }
        }.store(in: &watchers)
        // camera access allowed (or taken away) in System Settings: start (or stop) the camera
        Permissions.shared.$camera.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.camera?.permissionChanged() } }
        }.store(in: &watchers)
        // the weather follows a travelling Mac
        let t = Timer(timeInterval: 3 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                if ConfigStore.shared.onboarded { LocationService.shared.refresh() }
            }
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        locationTimer = t
    }

    // MARK: menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            // the hand from the app icon (MenuBarIcon.png + @2x, drawn by scripts/make_icons.sh)
            let img = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)
            img?.isTemplate = true
            img?.size = NSSize(width: 18, height: 18)
            img?.accessibilityDescription = "Waverly"
            b.image = img
            b.toolTip = "Waverly"
        }
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false
        troubleItem = m.addItem(withTitle: "Waverly's background service keeps stopping", action: nil, keyEquivalent: "")
        troubleItem.isEnabled = false
        troubleItem.isHidden = true
        showItem = m.addItem(withTitle: Self.showTitle, action: #selector(showHUD), keyEquivalent: "")
        showItem.target = self
        hideItem = m.addItem(withTitle: "Hide Waverly  (Esc)", action: #selector(hideHUD), keyEquivalent: "")
        hideItem.target = self
        m.addItem(.separator())
        pauseItem = m.addItem(withTitle: "Pause camera", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        m.addItem(withTitle: "Connect Google Calendar…", action: #selector(connectGoogle), keyEquivalent: "").target = self
        settingsItem = m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        m.addItem(withTitle: "Open logs", action: #selector(openLogs), keyEquivalent: "").target = self
        loginItem = m.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Waverly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = m
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    /// "Show Waverly  (fn ⇧ H)", with the shortcut chosen in Settings.
    private static var showTitle: String { "Show Waverly  (\(ConfigStore.shared.hotkey.display))" }

    private func refreshMenu() {
        let running = servicesStarted && helperTrouble["core"] == nil   // without hud-core nothing can open
        troubleItem?.isHidden = helperTrouble.isEmpty
        showItem?.title = Self.showTitle
        showItem?.isEnabled = running
        hideItem?.isEnabled = running
        pauseItem?.isEnabled = running && camera != nil
        pauseItem?.state = camera?.userPaused == true ? .on : .off
        settingsItem?.isEnabled = ConfigStore.shared.onboarded
        let s = SMAppService.mainApp.status
        let pending = defaults.bool(forKey: "HUDLoginItemPending")   // LoginItemSetting: deferred until installed
        loginItem?.state = s == .enabled || pending ? .on : (s == .requiresApproval ? .mixed : .off)
    }

    /// A helper crash-loops: say so in the menu, and once per run in an alert.
    private func helperKeepsStopping(_ name: String, _ why: String) {
        helperTrouble[name] = why
        refreshMenu()
        guard !troubleAlertShown else { return }
        troubleAlertShown = true
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "Waverly's background service keeps stopping"
            a.informativeText = (name == "core" ? "Waverly can't open until it runs." : "Hand gestures are off until it runs.")
                + (why.isEmpty ? "" : "\n\n\(why)") + "\n\nWaverly keeps trying. The logs show what happened."
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Open Logs")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertSecondButtonReturn { self.openLogs() }
        }
    }

    @objc private func showHUD() { requestOpen("menu") }
    @objc private func hideHUD() { requestClose("menu") }

    @objc private func togglePause() {
        guard let camera else { return }
        if camera.userPaused { camera.resume(reason: "user") } else { camera.pause(reason: "user") }
        DispatchQueue.main.async { self.refreshMenu() }
    }

    @objc private func openSettings() {
        guard ConfigStore.shared.onboarded else { wizard?.present(); return }
        SettingsWindowController.shared.show(tab: nil)
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AppLog.directory)
    }

    @objc private func toggleLogin() {
        let on = LoginItem.isEnabled || SMAppService.mainApp.status == .requiresApproval
            || defaults.bool(forKey: "HUDLoginItemPending")   // LoginItemSetting: deferred until installed
        LoginItemSetting.set(!on)
        refreshMenu()
    }

    /// Signs in to Google in the browser; when already connected (or there's no
    /// client to sign in with) opens Settings › Google instead.
    @objc private func connectGoogle() {
        guard ConfigStore.shared.onboarded else { wizard?.present(); return }   // the wizard has a Google page
        let g = GoogleAuth.shared
        if case .connected = g.state {
            SettingsWindowController.shared.show(tab: .google)
        } else if g.hasBuiltInClient || g.customClientID != nil {
            g.connect()
        } else {
            SettingsWindowController.shared.show(tab: .google)
        }
    }

    /// A sign-in that failed while none of Waverly's windows was showing it: show why.
    private func googleFinished(_ ok: Bool) {
        guard !ok, case .failed = GoogleAuth.shared.state, ConfigStore.shared.onboarded,
              !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        SettingsWindowController.shared.show(tab: .google)
    }

    // MARK: developer control (DebugControl.swift; off unless -HUDDebugSocket is given)

    private func debugCommand(_ line: String, _ reply: @escaping (Any) -> Void) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch parts.first ?? "" {
        case "status":
            var d: [String: Any] = [
                "version": Self.version, "onboarded": ConfigStore.shared.onboarded, "servicesStarted": servicesStarted,
                "overlayVisible": overlay?.isVisible ?? false, "pageLoaded": overlay?.pageLoaded ?? false,
                "linkConnected": link?.isConnected ?? false, "engineState": engineState, "hotkeys": hotkeys.installed,
                "accessibility": AXIsProcessTrusted(), "helpers": supervisor?.pids.mapValues { Int($0) } ?? [:],
                "appActive": NSApp.isActive, "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                "loginItem": "\(SMAppService.mainApp.status.rawValue)", "envReady": PythonEnvironment.isReady,
                "wizardShown": wizard?.window?.isVisible ?? false,
                "settingsShown": SettingsWindowController.shared.window?.isVisible ?? false,
                "windows": NSApp.windows.filter(\.isVisible).map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title },
            ]
            if let overlay {
                d["panelFrame"] = NSStringFromRect(overlay.panel.frame)
                d["panelLevel"] = overlay.panel.level.rawValue
                d["isKey"] = overlay.panel.isKeyWindow
            }
            if let camera {
                camera.status { c in d["camera"] = c; reply(d) }
            } else {
                reply(d)
            }
        case "config":                                        // config.json as saved (after pending writes)
            ConfigStore.shared.flush()
            let data = FileManager.default.contents(atPath: HelperSupervisor.configFile.path) ?? Data()
            reply((try? JSONSerialization.jsonObject(with: data)) ?? ["error": "unreadable"])
        case "onboard-skip":                                  // finish the wizard without clicking: "onboard-skip [name]"
            let c = ConfigStore.shared
            c.name = arg
            c.onboarded = true
            c.flush()
            if let w = wizard {
                wizard = nil
                w.window?.delegate = nil
                w.close()
            }
            proceed()
            reply(["ok": true, "envReady": PythonEnvironment.isReady])
        case "wizard":                                        // "wizard" or "wizard env" (environment page only)
            showWizard(environmentOnly: arg == "env")
            reply(["ok": true])
        case "set":                                           // "set <key> <value>": a ConfigStore setting (see setConfig)
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { reply(["ok": false, "error": "usage: set <key> <value>"]); return }
            if let error = setConfig(kv[0], kv[1]) { reply(["ok": false, "error": error]); return }
            ConfigStore.shared.flush()
            reply(["ok": true, "hotkey": ConfigStore.shared.hotkey.json, "menu": Self.showTitle,
                   "open_animation_s": ConfigStore.shared.openAnimation, "close_animation_s": ConfigStore.shared.closeAnimation,
                   "open_animation": ConfigStore.shared.openAnimationType.rawValue,
                   "close_animation": ConfigStore.shared.closeAnimationType.rawValue])
        case "hotkey-test":                                   // "hotkey-test <key code> [mods] [visible] [repeat]": the tap's decision
            let w = arg.split(separator: " ").map(String.init)
            guard let code = w.first.flatMap({ Int($0) }),
                  let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true) else {
                reply(["ok": false, "error": "usage: hotkey-test <key code> [fn,shift,…] [visible] [repeat]"]); return
            }
            var flags = CGEventFlags()
            for m in (w.count > 1 ? w[1] : "").split(separator: ",") {
                if let mod = Shortcut.Modifier(rawValue: String(m)) { flags.insert(mod.cgFlag) }
            }
            e.flags = flags
            if w.contains("repeat") { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            let a = Hotkeys.action(for: e, shortcut: ConfigStore.shared.hotkey, visible: w.contains("visible"))
            reply(["ok": true, "action": "\(a)", "shortcut": ConfigStore.shared.hotkey.display])
        case "settings":                                      // "settings [general|appearance|controls|lists|labels|google|permissions]"
            guard ConfigStore.shared.onboarded else { reply(["ok": false, "error": "not onboarded"]); return }
            SettingsWindowController.shared.show(tab: SettingsTab(rawValue: arg))
            reply(["ok": true])
        case "installer":
            let i = EnvironmentInstaller.shared
            reply(["phase": "\(i.phase)", "progress": i.progress ?? -1, "logTail": String(i.log.suffix(2000))])
        case "install":                                       // EnvironmentInstaller.start()
            EnvironmentInstaller.shared.start()
            reply(["ok": true, "phase": "\(EnvironmentInstaller.shared.phase)"])
        case "permissions":
            let p = Permissions.shared
            p.refresh()
            reply(["camera": "\(p.camera)", "accessibility": "\(p.accessibility)", "location": "\(p.location)"])
        case "location":                                      // "location" or "location refresh"
            let l = LocationService.shared, c = ConfigStore.shared
            if arg == "refresh" { l.refresh() }
            reply(["authorization": "\(l.authorization)", "locating": l.isLocating, "auto": c.locationAuto,
                   "place": c.place, "lat": c.lat.map { $0 as Any } ?? NSNull(), "lon": c.lon.map { $0 as Any } ?? NSNull()])
        case "place":                                         // "place <city>": the city search
            Task { @MainActor in
                let found = await LocationService.shared.search(arg)
                reply(found.map { ["name": $0.name, "detail": $0.detail, "lat": $0.lat, "lon": $0.lon] })
            }
        case "google":
            let g = GoogleAuth.shared
            reply(["state": "\(g.state)", "builtInClient": g.hasBuiltInClient, "customClient": g.customClientID.map { $0 as Any } ?? NSNull()])
        case "js":
            guard let overlay else { reply(["ok": false, "error": "services not started"]); return }
            let code = arg.isEmpty ? "return null" : arg
            overlay.webView.callAsyncJavaScript(code, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): reply(["ok": true, "value": JSONSerialization.isValidJSONObject(["v": v]) ? v : "\(v)"])
                case .failure(let e): reply(["ok": false, "error": "\(e)"])
                }
            }
        case "snapshot":
            guard let overlay else { reply(["ok": false, "error": "services not started"]); return }
            DebugControl.snapshot(overlay.webView, to: arg.isEmpty ? "/tmp/waverly.png" : arg, reply)
        case "window-snapshot":                               // "window-snapshot <title> <path.png>": one of our windows
            // the path is the last word (titles may have spaces)
            let cut = arg.range(of: " ", options: .backwards)
            let bits = cut.map { [String(arg[..<$0.lowerBound]), String(arg[$0.upperBound...])] } ?? []
            guard bits.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.title == bits[0] }) else {
                reply(["ok": false, "error": "usage: window-snapshot <title> <path>; visible: \(NSApp.windows.filter(\.isVisible).map(\.title))"])
                return
            }
            DebugControl.snapshot(window: w, to: bits[1], reply)
        case "menu":                                          // run a status-menu item, e.g. "menu Pause camera"
            if !arg.isEmpty, let m = statusItem.menu, let i = m.items.firstIndex(where: { !$0.isSeparatorItem && $0.title == arg }) {
                refreshMenu()
                guard m.items[i].isEnabled else { reply(["ok": false, "error": "disabled"]); return }
                m.performActionForItem(at: i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.refreshMenu()
                    reply(["ok": true, "items": m.items.filter { !$0.isSeparatorItem }.map { "\($0.title)=\($0.state.rawValue)\($0.isEnabled ? "" : " (disabled)")" }])
                }
            } else {
                refreshMenu()
                reply(["ok": false, "items": statusItem.menu?.items.filter { !$0.isSeparatorItem }
                    .map { "\($0.title)\($0.isEnabled ? "" : " (disabled)")" } ?? []])
            }
        case "show":
            guard let overlay else { reply(["ok": false, "error": "services not started"]); return }
            overlay.show { reply(["ok": true]) }
        case "hide":
            guard let overlay else { reply(["ok": false, "error": "services not started"]); return }
            overlay.hide { reply(["ok": true]) }
        case "quit":
            reply(["ok": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.forceQuit = true; NSApp.terminate(nil) }
        default:
            reply(["ok": false, "error": "unknown command"])
        }
    }
}

extension AppDelegate {
    /// The debug "set" command: changes a setting as the Settings window would.
    /// Returns an error message, or nil.
    fileprivate func setConfig(_ key: String, _ value: String) -> String? {
        let c = ConfigStore.shared
        func flag() -> Bool? { value == "true" ? true : value == "false" ? false : nil }
        switch key {
        case "theme": guard let v = Theme(rawValue: value) else { return "adaptive | light | dark" }; c.theme = v
        case "weather_detail": guard let v = WeatherDetail(rawValue: value) else { return "low | medium | high" }; c.weatherDetail = v
        case "parallax": guard let v = flag() else { return "true | false" }; c.parallax = v
        case "weather_animation": guard let v = flag() else { return "true | false" }; c.weatherAnimation = v
        case "open_animation_s", "close_animation_s":         // seconds; 0 or "instant" = no animation
            let len = key == "open_animation_s" ? AnimationLength.open : AnimationLength.close
            guard let v = value == "instant" ? 0 : Double(value), v.isFinite else {
                return "instant | 0 | \(len.range.lowerBound)…\(len.range.upperBound) (seconds)"
            }
            if key == "open_animation_s" { c.openAnimation = len.validated(v) } else { c.closeAnimation = len.validated(v) }
        case "open_animation", "close_animation":
            guard let v = AnimationType(rawValue: value) else { return "fade | zoom | shatter | slide | swirl" }
            if key == "open_animation" { c.openAnimationType = v } else { c.closeAnimationType = v }
        case "gesture_open_wave": guard let v = flag() else { return "true | false" }; c.gestureOpenWave = v
        case "gesture_open_fist": guard let v = flag() else { return "true | false" }; c.gestureOpenFist = v
        case "gesture_close_fist": guard let v = flag() else { return "true | false" }; c.gestureCloseFist = v
        case "auto_close_away": guard let v = flag() else { return "true | false" }; c.autoCloseAway = v
        case "auto_close_dark": guard let v = flag() else { return "true | false" }; c.autoCloseDark = v
        case "scroll_speed_vertical", "scroll_speed_horizontal":
            guard let v = Double(value), v.isFinite else { return "0.5…2 (times the standard speed)" }
            if key == "scroll_speed_vertical" { c.scrollSpeedVertical = ScrollSpeed.validated(v) }
            else { c.scrollSpeedHorizontal = ScrollSpeed.validated(v) }
        case "scroll_reverse_vertical": guard let v = flag() else { return "true | false" }; c.scrollReverseVertical = v
        case "scroll_reverse_horizontal": guard let v = flag() else { return "true | false" }; c.scrollReverseHorizontal = v
        case "hotkey":                                        // "set hotkey <key code> <mod,mod>" or "set hotkey default"
            if value == "default" { c.hotkey = .default; return nil }
            let w = value.split(separator: " ")
            guard w.count == 2, let code = Int(w[0]), Shortcut.keyName(code) != nil else { return "<key code> <fn,shift,…>" }
            var mods = Set<Shortcut.Modifier>()
            for m in w[1].split(separator: ",") {
                guard let mod = Shortcut.Modifier(rawValue: String(m)) else { return "unknown modifier \(m)" }
                mods.insert(mod)
            }
            let s = Shortcut(keyCode: code, modifiers: mods)
            if case .rejected(let why) = s.verdict() { return why }
            c.hotkey = s
        default: return "unknown key \(key)"
        }
        return nil
    }
}

/// Launch at login (SMAppService). LoginItemSetting (UIComponents.swift) decides
/// when it may be registered (not from the disk image); this does it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        let s = SMAppService.mainApp
        do {
            if on {
                if s.status != .enabled { try s.register() }
            } else if s.status == .enabled || s.status == .requiresApproval {
                try s.unregister()
            }
        } catch {
            AppLog.warning("launch at login: \(error.localizedDescription)")
        }
        // the user switched it off in System Settings before: only they can switch it back on
        if on && s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        AppLog.info("launch at login: \(s.status == .enabled ? "on" : s.status == .requiresApproval ? "needs approval" : "off")")
    }
}

/// The macOS version of Linux's "wait for the monitor before the fade-in".
enum DisplayWaker {
    private static var assertion: IOPMAssertionID = 0

    /// If the display sleeps, declare user activity (which wakes it) and call
    /// `then` once it reports awake plus a 250 ms settle (≤ 8 s); otherwise now.
    static func wakeIfAsleep(then: (() -> Void)? = nil) {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { then?(); return }
        AppLog.info("display asleep: waking it")
        IOPMAssertionDeclareUserActivity("Waverly gesture" as CFString, kIOPMUserActiveLocal, &assertion)
        let start = Date()
        func poll() {
            if CGDisplayIsAsleep(CGMainDisplayID()) == 0 || Date().timeIntervalSince(start) > 8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { then?() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }
}
