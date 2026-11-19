// CameraGate.swift — owns the camera and decides, as cheaply as possible, when
// the Python engine needs to see frames. Built for battery life: the engine only
// gets frames while a hand might be in view or the HUD is open.
//
// Modes
//   .idle    HUD closed, nothing happening. The camera runs at its slowest rate in
//            its native YUV format (no colour conversion) and HandGate looks at 5
//            frames a second (every frame for a moment after a partial hand):
//            darkness -> motion -> (on motion, nobody typing) Apple Vision hand pose
//            -> a clear hand. Nothing goes to the engine.
//   .active  HandGate saw a clear hand (held 0.75 s), the engine asked for frames
//            (camera-want), or the overlay is visible. 640x480 @ 30 fps; every frame
//            goes to the engine through the frame ring (converted to BGRA there).
//   .paused  Screen locked, Mac asleep, another user's session active, the display
//            asleep on battery (PowerPolicy), or the user paused the camera from the
//            menu. Capture session stopped (light off).
//
// Leaving .active (to idle or paused) clears the frame ring, so no camera frame stays in
// its file; shutdown() (the app quits) also deletes the ring.
//
// While the overlay is hidden and a key was pressed a moment ago, no gesture is
// coming (the hands are on the keyboard): Vision does not run, and an active camera
// drops back to idle until HandGate sees a hand again.
// When the engine shows no interest in a hand HandGate confirmed (it sat still in
// view), HandGate ignores that spot for a while, so a chin resting on a hand does
// not keep starting MediaPipe.
//
// Once a minute a "power:" line goes to the log (frames, Vision runs, active
// seconds, the app's CPU time, the macOS video effects that are on), so real-world
// drain can be followed in the logs.
// All state below the "queue-confined" mark lives on `queue`.
//
// macOS Video Effects (Reactions with their gesture detection, Portrait, Studio
// Light, Background) are set per app by the user. When on, they run inside this
// process on every camera frame, idle mode included, and cost more than the gate
// itself. No API turns them off: they are logged (and changes followed), and the
// permission views show a note that opens the system's Video Effects menu.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

protocol CameraGateDelegate: AnyObject {
    func cameraGate(_ gate: CameraGate, didChangeMode mode: CameraGate.Mode)
}

final class CameraGate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum Mode: String { case idle, active, paused }

    static let idleFPS = 5
    static let activeFPS = 30
    static let gateHold: TimeInterval = 0.75           // keep active this long after HandGate's hand; the engine asks
                                                       // for more within ~0.1 s if MediaPipe sees a hand doing something
    static let typingQuiet: TimeInterval = 0.6         // a key pressed this recently: the hands are on the keyboard
    static let width = 640, height = 480
    static let statsPeriod: TimeInterval = 60

    weak var delegate: CameraGateDelegate?
    /// Main-thread mirror of the current mode.
    private(set) var mode: Mode = .paused
    /// Main-thread mirror: true when the user paused the camera from the menu.
    private(set) var userPaused = false

    /// Inputs from the rest of the app (set on the main thread).
    var engineWantsActive = false {
        didSet { let v = engineWantsActive; queue.async { self.setEngineWants(v) } }
    }
    var overlayVisible = false {
        didSet {
            let v = overlayVisible
            queue.async {
                self.qOverlayVisible = v
                if v {
                    self.gateHandUsed = true
                    // The engine wants frames all the while the HUD is open: a request that
                    // typing made stale before it opened is current again.
                    self.engineWantsStale = false
                }
                self.reevaluate()
            }
        }
    }

    private let ring: FrameRingWriter
    private let queue = DispatchQueue(label: "hud.camera", qos: .userInitiated)
    private let testVideo: TestVideoSource?
    /// -HUDTestVideo was given but the file can't be played: stay paused, never use the real camera.
    private let testVideoMissing: Bool
    private let power = PowerPolicy()                  // main thread

    // ---- queue-confined
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private var configured = false
    private var qMode: Mode = .paused
    private var qEngineWants = false
    private var engineWantsStale = false               // typing ended an activation: wait for a fresh request
    private var qOverlayVisible = false
    private var pauseReasons: Set<String> = ["startup"]     // removed once the camera is configured
    private var activeUntil: TimeInterval = 0
    private let gate = HandGate()
    private var lastIdleFrame: TimeInterval = 0
    // the activation HandGate started: did the engine (or the overlay) take it up?
    private var gateHand: HandGate.Hand?
    private var gateHandUsed = false
    // once-a-minute power log
    private var frames = 0, written = 0, typingSkips = 0, activations = 0
    private var activeSeconds: TimeInterval = 0, modeSince = CameraGate.now()
    private var statT = CameraGate.now(), statCPU: TimeInterval = 0
    private var statsTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var cameraStarted = false                  // start() chose the real camera
    private var effectsObserver: VideoEffects.Observer?
    private var effects = VideoEffects()
    /// Developer: log every stage-1 decision in idle mode (-HUDVerboseGate YES).
    private let verbose = UserDefaults.standard.bool(forKey: "HUDVerboseGate")

    init(ring: FrameRingWriter, testVideo: TestVideoSource? = nil) {
        self.ring = ring
        self.testVideo = testVideo
        testVideoMissing = testVideo == nil && TestVideoSource.isRequested()
        super.init()
        power.onChange = { [weak self] p in
            let pause = p.shouldPauseCamera, summary = p.summary
            self?.queue.async {
                guard let self else { return }
                AppLog.info("camera: power state: \(summary)")
                if pause { self.pauseReasons.insert("display") } else { self.pauseReasons.remove("display") }
                self.reevaluate()
            }
        }
        if power.shouldPauseCamera { pauseReasons.insert("display") }   // (nothing runs on `queue` yet)
    }

    static func now() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// This process's CPU time (user + system, all threads), in seconds.
    static func processCPUTime() -> TimeInterval {
        var ru = rusage()
        guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
        return TimeInterval(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec)
            + TimeInterval(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6
    }

    /// Seconds since the last key press in this login session (needs no permission).
    static func secondsSinceKeyDown() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    // MARK: setup

    func start() {
        queue.async {                                   // before the first real frame (see HandGate.warmUp)
            let t0 = CameraGate.now()
            self.gate.warmUp()
            AppLog.info(String(format: "camera: Vision hand detector ready in %.0f ms", (CameraGate.now() - t0) * 1000))
            self.startStats()
        }
        if testVideoMissing {
            AppLog.error("camera: the test video given with -HUDTestVideo can't be played; the camera stays off")
            queue.async { self.pauseReasons.insert("test-video-missing"); self.pauseReasons.remove("startup"); self.reevaluate() }
            return
        }
        if let tv = testVideo {
            AppLog.info("camera: using test video \(tv.url.path)")
            tv.onFrame = { [weak self] pb in self?.handleFrame(pb) }
            queue.async { self.configured = true; self.pauseReasons.remove("startup"); self.reevaluate() }
            return
        }
        observeDevices()
        queue.async { self.cameraStarted = true }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.queue.async { self.configureAndStart() }
                } else {
                    AppLog.warning("camera access was not granted; gestures are off (keyboard and menu still work)")
                    self.queue.async { self.pauseReasons.insert("denied"); self.reevaluate() }
                }
            }
        default:
            AppLog.warning("camera access is denied in System Settings > Privacy & Security > Camera; gestures are off")
            queue.async { self.pauseReasons.insert("denied"); self.reevaluate() }
        }
    }

    /// Camera access may have changed in System Settings (Waverly became active, or the
    /// permission views saw it): start the camera once it is allowed, stop it when it
    /// was taken away.
    func permissionChanged() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        queue.async {
            guard self.cameraStarted else { return }    // start() asks first; a test video needs no access
            switch status {
            case .authorized:
                guard self.pauseReasons.contains("denied") else { return }
                AppLog.info("camera access allowed: starting the camera")
                self.pauseReasons.remove("denied")
                self.configureAndStart()
            case .denied, .restricted:
                guard !self.pauseReasons.contains("denied") else { return }
                AppLog.warning("camera access was turned off in System Settings; gestures are off")
                self.pauseReasons.insert("denied")
                self.reevaluate()
            default:
                break
            }
        }
    }

    private func configureAndStart() {
        if configure() {
            pauseReasons.remove("nocamera")
        } else {
            pauseReasons.insert("nocamera")
            AppLog.warning("no usable camera found; waiting for one to be connected")
        }
        pauseReasons.remove("startup")
        reevaluate()
    }

    /// (Re)build the capture session around the default video device.
    private func configure() -> Bool {
        // Center Stage pans and crops the view (a gesture near the edge would vanish)
        // and keeps a face tracker running: this app always takes the plain view.
        if AVCaptureDevice.centerStageControlMode != .app { AVCaptureDevice.centerStageControlMode = .app }
        if AVCaptureDevice.isCenterStageEnabled { AVCaptureDevice.isCenterStageEnabled = false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        configured = false
        device = nil
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return false }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        // The camera's own biplanar YUV: no colour conversion for the frames the idle
        // gate looks at (it reads the luma plane; Vision takes YUV as it is). Only the
        // frames that go to the engine are converted, by FrameRingWriter.
        let native = CMFormatDescriptionGetMediaSubType(dev.activeFormat.formatDescription)
        let format = native == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format,
                             kCVPixelBufferWidthKey as String: Self.width,
                             kCVPixelBufferHeightKey as String: Self.height]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { session.removeInput(input); return false }
        session.addOutput(out)
        // The engine mirrors frames itself: deliver the camera's raw, unmirrored view.
        if let c = out.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
        device = dev
        configured = true
        let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
        AppLog.info("camera: \(dev.localizedName) (\(dims.width)x\(dims.height) \(Self.fourCC(native)), frames as \(Self.fourCC(format)))")
        logEffects(dev)
        return true
    }

    /// The video effects macOS applies for this app, and whether this camera runs them.
    private func logEffects(_ dev: AVCaptureDevice) {
        effects = VideoEffects.current()
        AppLog.info("camera: video effects for Waverly: \(effects.summary)"
                    + " (this camera: reactions \(dev.canPerformReactionEffects ? "possible" : "off"),"
                    + " portrait \(dev.isPortraitEffectActive ? "active" : "off"), studio light \(dev.isStudioLightActive ? "active" : "off"))"
                    + (effects.costly ? "; they run on every frame and cost battery (Video Effects in Control Center)" : ""))
        if effectsObserver == nil {
            effectsObserver = VideoEffects.Observer { [weak self] in self?.queue.async { self?.effectsChanged() } }
        }
    }

    private func effectsChanged() {
        let now = VideoEffects.current()
        guard now != effects else { return }
        effects = now
        AppLog.info("camera: video effects for Waverly now: \(now.summary)")
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }

    private func observeDevices() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let err = n.userInfo?[AVCaptureSessionErrorKey] as? NSError
            AppLog.warning("camera session error: \(err?.localizedDescription ?? "unknown")")
            self?.queue.asyncAfter(deadline: .now() + 1.5) { self?.restartSession() }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] n in
            guard let self, let dev = n.object as? AVCaptureDevice else { return }
            self.queue.async {
                guard dev.uniqueID == self.device?.uniqueID else { return }
                AppLog.warning("camera disconnected: \(dev.localizedName)")
                self.reconfigure()
            }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized, !self.pauseReasons.contains("startup") else { return }
                if !self.configured || self.pauseReasons.contains("nocamera") { self.reconfigure() }
            }
        })
    }

    private func reconfigure() {
        if session.isRunning { session.stopRunning() }
        let had = qMode
        if had == .active { endActivation(declined: false) }
        setMode(.paused)                     // the session is stopped now; reevaluate() restarts it
        if configure() { pauseReasons.remove("nocamera") } else { pauseReasons.insert("nocamera") }
        reevaluate()
        if qMode == .paused && had != .paused {
            AppLog.info("camera: \(had.rawValue) -> paused (\(pauseReasons.sorted().joined(separator: ", ")))")
            publish(.paused)
        }
    }

    private func restartSession() {
        guard testVideo == nil, qMode != .paused, configured else { return }
        if !session.isRunning {
            session.startRunning()
            applyFPS(qMode == .active ? Self.activeFPS : Self.idleFPS)
        }
    }

    // MARK: mode control

    func pause(reason: String) {
        DispatchQueue.main.async { if reason == "user" { self.userPaused = true } }
        queue.async { self.pauseReasons.insert(reason); self.reevaluate() }
    }

    /// The app is quitting: stop the camera, clear the frame ring and delete its files.
    /// Blocks until done (on the camera queue, so no frame is being written meanwhile).
    func shutdown() {
        queue.sync {
            pauseReasons.insert("quit")
            reevaluate()
            ring.removeFiles()
        }
    }

    func resume(reason: String) {
        DispatchQueue.main.async { if reason == "user" { self.userPaused = false } }
        queue.async { self.pauseReasons.remove(reason); self.reevaluate() }
    }

    private func setEngineWants(_ v: Bool) {
        if v && !qEngineWants { engineWantsStale = false }    // a fresh request: the engine saw a hand
        qEngineWants = v
        if v && qMode == .active { gateHandUsed = true }
        reevaluate()
    }

    private func typing() -> Bool {
        // (the person in a test video is not at this keyboard)
        testVideo == nil && !qOverlayVisible && Self.secondsSinceKeyDown() < Self.typingQuiet
    }

    /// The mode the inputs call for, and why (for the log).
    private func desired(_ now: TimeInterval) -> (Mode, String) {
        if !pauseReasons.isEmpty || !configured { return (.paused, pauseReasons.sorted().joined(separator: ", ")) }
        if qOverlayVisible { return (.active, "overlay") }
        let wants = qEngineWants && !engineWantsStale
        guard wants || now < activeUntil else { return (.idle, "") }
        if typing() {
            // No gesture comes from hands on the keyboard: idle until HandGate sees a
            // hand again (the engine's standing request is stale from now on).
            activeUntil = 0
            if qEngineWants { engineWantsStale = true }
            return (.idle, "typing")
        }
        return (.active, wants ? "engine" : "hand")
    }

    private func reevaluate() {
        let (want, why) = desired(Self.now())
        guard want != qMode else { return }
        let old = qMode
        if old == .active { endActivation(declined: want == .idle && why.isEmpty) }
        setMode(want)
        switch want {
        case .paused:
            if let tv = testVideo { tv.stop() } else if session.isRunning { session.stopRunning() }
        case .idle, .active:
            let fps = want == .active ? Self.activeFPS : Self.idleFPS
            if let tv = testVideo {
                tv.start(fps: fps, queue: queue)
            } else {
                if !session.isRunning { session.startRunning() }
                applyFPS(fps)
            }
            if want == .idle { gate.reset() }
        }
        AppLog.info("camera: \(old.rawValue) -> \(want.rawValue)" + (why.isEmpty ? "" : " (\(why))"))
        publish(want)
    }

    /// Leaving active mode. `declined`: the hold simply ran out. If HandGate started
    /// this activation and nobody took it up (the engine never asked for frames, the
    /// overlay never showed), that hand is resting where it is.
    private func endActivation(declined: Bool) {
        if declined, let hand = gateHand, !gateHandUsed {
            gate.decline(hand, now: Self.now())
            AppLog.info(String(format: "camera: the engine did not want the hand at (%.2f, %.2f); ignoring it while it rests there",
                               hand.center.x, 1 - hand.center.y))
        }
        gateHand = nil
        gateHandUsed = false
    }

    private func setMode(_ m: Mode) {
        let t = Self.now()
        if qMode == .active && m != .active { ring.clear() }  // the engine is done with these frames
        if qMode == .active { activeSeconds += t - modeSince }
        if m == .active && qMode != .active { activations += 1 }
        modeSince = t
        qMode = m
    }

    private func publish(_ m: Mode) {
        DispatchQueue.main.async {
            self.mode = m
            self.delegate?.cameraGate(self, didChangeMode: m)
        }
    }

    /// Fix the device's frame rate (the camera itself runs slower in idle mode, which
    /// saves sensor and ISP power, not just CPU). Only durations the active format
    /// supports are used: AVFoundation throws an uncatchable exception otherwise. Many
    /// Mac cameras cannot go below 15 fps; idle mode then takes every third frame.
    private func applyFPS(_ fps: Int) {
        guard let dev = device else { return }
        let ranges = dev.activeFormat.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return }
        let want = CMTime(value: 1, timescale: CMTimeScale(fps))
        var duration: CMTime?
        for r in ranges where CMTimeCompare(want, r.minFrameDuration) >= 0 && CMTimeCompare(want, r.maxFrameDuration) <= 0 {
            duration = want
            break
        }
        if duration == nil {                                 // the closest rate the format offers, exactly as it reports it
            let bounds = ranges.flatMap { [$0.minFrameDuration, $0.maxFrameDuration] }
            duration = bounds.min { abs($0.seconds - want.seconds) < abs($1.seconds - want.seconds) }
        }
        guard let d = duration, d.isValid, d.seconds > 0 else { return }
        do { try dev.lockForConfiguration() } catch { return }
        defer { dev.unlockForConfiguration() }
        dev.activeVideoMinFrameDuration = d
        dev.activeVideoMaxFrameDuration = d
        if d != want { AppLog.info(String(format: "camera: runs at %.1f fps for a requested %d fps", 1 / d.seconds, fps)) }
    }

    // MARK: frames (on `queue`)

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        handleFrame(pb)
    }

    private func handleFrame(_ pb: CVPixelBuffer) {
        autoreleasepool { process(pb) }                  // Vision's temporaries go at once, not at some later drain
    }

    private func process(_ pb: CVPixelBuffer) {
        frames += 1
        let ts = DispatchTime.now().uptimeNanoseconds
        let t = Self.now()
        switch qMode {
        case .active:
            if ring.write(pb, timestampNs: ts) { written += 1 }
            reevaluate()                                         // hold over, typing, ...
        case .idle:
            // 5 frames a second (most cameras cannot run that slowly); every frame while
            // the gate watches closely
            guard gate.watching(at: t) || t - lastIdleFrame >= 1.0 / Double(Self.idleFPS) - 0.02 else { break }
            lastIdleFrame = t
            let verdict = gate.evaluate(pb, now: t, typing: typing())
            if verbose { AppLog.info("gate: \(verdict)") }
            switch verdict {
            case .typing:
                typingSkips += 1
            case .hand(let hand):
                AppLog.info(String(format: "camera: hand in view (%d of 21 joints, size %.2f)", hand.joints, hand.size))
                activeUntil = t + Self.gateHold
                engineWantsStale = false                         // the engine is about to look again
                reevaluate()                                     // -> .active (30 fps)
                if qMode == .active {
                    gateHand = hand
                    gateHandUsed = qEngineWants
                    if ring.write(pb, timestampNs: ts) { written += 1 }   // and forward this very frame
                }
            default:
                break
            }
        case .paused:
            break
        }
    }

    // MARK: power log

    private func startStats() {
        guard statsTimer == nil else { return }
        statT = Self.now()
        statCPU = Self.processCPUTime()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.statsPeriod, repeating: Self.statsPeriod, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        statsTimer = timer
    }

    /// One line a minute: what the camera did and what the app's process cost.
    private func logStats() {
        let t = Self.now(), cpu = Self.processCPUTime()
        let span = max(t - statT, 1e-3)
        var active = activeSeconds
        if qMode == .active { active += t - modeSince }
        var line = String(format: "power: camera %@, %.1f fps in, %.1f fps to engine, active %.0f s (%d times), "
                                + "Vision %d runs (%d face checks, %d hands, %d rejected, %d skipped while typing), "
                                + "app CPU %.2f s (%.1f%%), video effects: %@",
                          qMode.rawValue, Double(frames) / span, Double(written) / span, active, activations,
                          gate.visionRuns, gate.faceRuns, gate.hands, gate.rejections, typingSkips,
                          cpu - statCPU, 100 * (cpu - statCPU) / span, effects.summary)
        if qMode == .paused { line += " [paused: \(pauseReasons.sorted().joined(separator: ", "))]" }
        AppLog.info(line)
        frames = 0; written = 0; typingSkips = 0; activations = 0
        activeSeconds = 0; modeSince = t
        gate.visionRuns = 0; gate.faceRuns = 0; gate.hands = 0; gate.rejections = 0
        statT = t; statCPU = cpu
    }

    /// Snapshot for diagnostics (debug control / menu).
    func status(_ reply: @escaping ([String: Any]) -> Void) {
        let powerSummary = power.summary                 // main thread, like the caller
        queue.async {
            let d: [String: Any] = ["mode": self.qMode.rawValue, "pause": self.pauseReasons.sorted(),
                                    "engineWants": self.qEngineWants, "overlay": self.qOverlayVisible,
                                    "visionRuns": self.gate.visionRuns, "ringSeq": self.ring.seq,
                                    "power": powerSummary,
                                    "device": self.device?.localizedName ?? (self.testVideo != nil ? "test video" : "none")]
            DispatchQueue.main.async { reply(d) }
        }
    }
}

/// macOS Video Effects for this app (Control Center › Video Effects, set per app by the
/// user; Info.plist only sets the gestures' first default). Reading them is cheap.
struct VideoEffects: Equatable {
    var gestures = false, reactions = false, portrait = false, studioLight = false, background = false

    static func current() -> VideoEffects {
        var e = VideoEffects()
        e.gestures = AVCaptureDevice.reactionEffectGesturesEnabled
        e.reactions = AVCaptureDevice.reactionEffectsEnabled
        e.portrait = AVCaptureDevice.isPortraitEffectEnabled
        e.studioLight = AVCaptureDevice.isStudioLightEnabled
        if #available(macOS 15.0, *) { e.background = AVCaptureDevice.isBackgroundReplacementEnabled }
        return e
    }

    /// Effects that look at every frame. Reactions count even with their gestures off:
    /// sampled on a MacBook Air (macOS 26.5) with only Reactions on, the system's hand-gesture
    /// and face/body detectors still ran on every idle frame, ~20x Waverly's own hand check.
    var costly: Bool { reactions || gestures || portrait || studioLight || background }

    /// The costly effects that are on, as the Video Effects menu names them.
    var costlyNames: [String] {
        [("Reactions", reactions || gestures), ("Portrait", portrait), ("Studio Light", studioLight), ("Background", background)]
            .filter(\.1).map(\.0)
    }

    /// For the log: "none", or the effects that are on.
    var summary: String {
        let on = [("reaction gestures", gestures), ("reactions", reactions), ("portrait", portrait),
                  ("studio light", studioLight), ("background", background)].filter(\.1).map(\.0)
        return on.isEmpty ? "none" : on.joined(separator: ", ")
    }

    /// The system's Video Effects menu, where the user can turn them off for Waverly.
    static func showSystemMenu() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    /// Calls `changed` (on any thread) when the user changes one of them.
    final class Observer: NSObject {
        private let changed: () -> Void
        private var keys = ["reactionEffectGesturesEnabled", "reactionEffectsEnabled", "portraitEffectEnabled", "studioLightEnabled"]

        init(_ changed: @escaping () -> Void) {
            self.changed = changed
            super.init()
            if #available(macOS 15.0, *) { keys.append("backgroundReplacementEnabled") }
            // class properties: key-value observed on the class object
            for k in keys { (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: k, options: [], context: nil) }
        }

        deinit {
            for k in keys { (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: k) }
        }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            changed()
        }
    }
}
