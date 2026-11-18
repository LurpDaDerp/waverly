// HelperSupervisor.swift — runs the two Python helpers (hud-core, hud-engine)
// from the app's Python environment, restarts them if they exit, and checks
// hud-core's /health. This replaces the Linux systemd units + hud-watchdog.
//
// Paths:
//   python   ~/Library/Application Support/Waverly/venv/bin/python   (EnvironmentInstaller, tools/setup_macos.sh)
//   code     Waverly.app/Contents/Resources/hud/python                (PYTHONPATH)
//   ui       Waverly.app/Contents/Resources/hud/ui                    (HUD_UI)
//   models   Waverly.app/Contents/Resources/hud/models                (HUD_MODELS)
//   config   ~/Library/Application Support/Waverly/config.json       (HUD_CONFIG; written only by ConfigStore)
//   state    ~/Library/Application Support/Waverly                   (HUD_STATE: cache, Google tokens, frame ring)
//   logs     ~/Library/Logs/Waverly                                  (HUD_LOG_DIR: rotating 2 MB x 3 per helper)
//
// Helpers are supervised by process handle (never by name). Their PIDs are kept
// in HUD_STATE/helpers.pid so copies orphaned by a crash of the app are cleaned
// up the next time it starts. They also get the app's PID (HUD_PARENT_PID) so they
// can stop by themselves when the app is gone (a crash or Force Quit skips the
// app's own cleanup).
//
// A helper that exits within seconds of every launch (a broken environment, the
// port taken by another app) is crash-looping: onCrashLoop tells the app, which
// tells the user; onRecovered once it stays up.

import Foundation

final class HelperSupervisor {
    struct Helper { let name: String; let module: String }
    static let helpers = [Helper(name: "core", module: "hud.core"), Helper(name: "engine", module: "hud.engine")]

    let port: Int
    var onPageStale: (() -> Void)?
    /// When the overlay became visible (nil while hidden). Set by the app.
    var overlayShownAt: () -> Date? = { nil }
    /// Called with every /health answer (main thread).
    var onHealth: (([String: Any]) -> Void)?
    /// A helper keeps exiting soon after it starts: its name and why, if known (main thread).
    var onCrashLoop: ((_ name: String, _ why: String) -> Void)?
    /// A helper that was crash-looping has stayed up (main thread).
    var onRecovered: ((_ name: String) -> Void)?

    private var procs: [String: Process] = [:]
    private var launchedAt: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]
    private var tails: [String: OutputTail] = [:]
    private var crashLoops: [String: CrashLoopCounter] = [:]
    private var portBusy = false                         // the last core launch found the port taken
    private var stopping = false
    private var started = false
    private var healthTimer: Timer?
    private var coreFailures = 0
    private var engineNotAlive = 0
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    // MARK: paths

    static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Waverly", isDirectory: true)
    }
    static var venv: URL { appSupport.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var resources: URL { Bundle.main.resourceURL!.appendingPathComponent("hud", isDirectory: true) }
    static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    static var logs: URL { AppLog.directory }
    static var pycache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Waverly/pycache", isDirectory: true)
    }
    private static var pidFile: URL { appSupport.appendingPathComponent("helpers.pid") }

    /// A CA bundle for the helpers' HTTPS requests. The python.org Python has no
    /// certificates of its own until "Install Certificates.command" is run, so
    /// without this every fetch fails with CERTIFICATE_VERIFY_FAILED.
    static var caBundle: String? {
        if let lib = try? FileManager.default.contentsOfDirectory(atPath: venv.appendingPathComponent("lib").path) {
            for d in lib.sorted().reversed() where d.hasPrefix("python") {
                let p = venv.appendingPathComponent("lib/\(d)/site-packages/certifi/cacert.pem").path
                if FileManager.default.isReadableFile(atPath: p) { return p }
            }
        }
        return FileManager.default.isReadableFile(atPath: "/etc/ssl/cert.pem") ? "/etc/ssl/cert.pem" : nil
    }

    /// Environment shared by the helpers and the environment check.
    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__"] { env[k] = nil }
        env["PYTHONPATH"] = resources.appendingPathComponent("python").path
        env["HUD_ROOT"] = resources.path
        env["HUD_UI"] = resources.appendingPathComponent("ui").path
        env["HUD_MODELS"] = resources.appendingPathComponent("models").path
        env["HUD_CONFIG"] = configFile.path
        env["HUD_STATE"] = appSupport.path
        env["HUD_LOG_DIR"] = logs.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONPYCACHEPREFIX"] = pycache.path            // never write __pycache__ into the signed app bundle
        if env["SSL_CERT_FILE"] == nil, let ca = caBundle { env["SSL_CERT_FILE"] = ca }
        return env
    }

    init(port: Int) { self.port = port }

    // MARK: lifecycle

    /// Create the state and log folders. config.json is created by ConfigStore. The state
    /// folder (settings, Google sign-in, cache, frame ring) is the user's alone: 0700.
    static func prepareState() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appSupport.path)   // made by an older build
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func start() {
        guard !started else { return }
        started = true
        Self.prepareState()
        killOrphans()
        for h in Self.helpers { launch(h) }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkHealth() }
    }

    /// Stop both helpers (SIGTERM, then SIGKILL after a grace period). Blocks up to ~2 s.
    func stop() {
        stopping = true
        healthTimer?.invalidate()
        let running = procs.values.filter { $0.isRunning }
        for p in running { p.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while running.contains(where: { $0.isRunning }) && Date() < deadline { usleep(20_000) }
        for p in running where p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? FileManager.default.removeItem(at: Self.pidFile)
        if !running.isEmpty { AppLog.info("helpers stopped") }
    }

    var pids: [String: Int32] { procs.filter { $0.value.isRunning }.mapValues { $0.processIdentifier } }

    private func launch(_ h: Helper) {
        guard !stopping else { return }
        if h.name == "core" {
            // (helpers.pid has already been used to stop a copy left over from an earlier run)
            let busy = !LocalPort.isFree(port)
            if busy && !portBusy { AppLog.warning("port \(port) is in use by another app: core can't start until it is free") }
            portBusy = busy
        }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-m", h.module]
        var env = Self.baseEnvironment()
        env["HUD_PARENT_PID"] = String(getpid())             // the helpers stop when the app is gone
        p.environment = env
        p.currentDirectoryURL = Self.appSupport
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice             // helpers log to HUD_LOG_DIR themselves
        let tail = OutputTail()
        p.standardError = tail.pipe                          // keep the last lines for crash reports
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus, reason = proc.terminationReason
            DispatchQueue.main.async { self?.exited(h, proc, status: status, reason: reason) }
        }
        do {
            try p.run()
            procs[h.name] = p
            tails[h.name] = tail
            launchedAt[h.name] = Date()
            writePidFile()
            AppLog.info("started \(h.name) (pid \(p.processIdentifier))")
        } catch {
            AppLog.error("could not start \(h.name): \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.launch(h) }
        }
    }

    private func exited(_ h: Helper, _ proc: Process, status: Int32, reason: Process.TerminationReason) {
        guard procs[h.name] === proc else { return }
        procs[h.name] = nil
        let t = tails.removeValue(forKey: h.name)
        t?.close()
        let tail = t?.text() ?? ""
        guard !stopping else { return }
        let how = reason == .uncaughtSignal ? "signal \(status)" : "status \(status)"
        AppLog.warning("\(h.name) exited (\(how))" + (tail.isEmpty ? "" : "; last output:\n\(tail)"))
        let uptime = Date().timeIntervalSince(launchedAt[h.name] ?? .distantPast)
        if crashLoops[h.name, default: CrashLoopCounter()].exited(after: uptime) {
            let why = h.name == "core" && portBusy ? "Port \(port) is in use by another app." : Self.lastLine(tail)
            AppLog.error("\(h.name) keeps stopping right after it starts" + (why.isEmpty ? "" : ": \(why)"))
            onCrashLoop?(h.name, why)
        }
        let wait = min(30, max(2, (backoff[h.name] ?? 1) * 2))   // 2, 4, 8, 16, 30 s
        backoff[h.name] = wait
        AppLog.info("restarting \(h.name) in \(Int(wait)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.procs[h.name] == nil else { return }
            self.launch(h)
        }
    }

    /// The last line of a helper's output that says something (a Python error's last line).
    private static func lastLine(_ tail: String) -> String {
        let lines = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return String((lines.last ?? "").prefix(300))
    }

    /// A helper has been up for a while: it is no longer crash-looping.
    private func stayedUp(_ name: String) {
        guard crashLoops[name]?.isLooping == true else { crashLoops[name]?.reset(); return }
        crashLoops[name]?.reset()
        AppLog.info("\(name) is running again")
        onRecovered?(name)
    }

    /// Ask a helper to exit; its termination handler starts it again.
    func restart(_ name: String) {
        guard let p = procs[name], p.isRunning else { return }
        AppLog.warning("restarting \(name)")
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if p.isRunning && p.processIdentifier == pid { kill(pid, SIGKILL) }   // hung: force it
        }
    }

    // MARK: health (same checks as the Linux hud-watchdog)

    private func checkHealth() {
        guard !stopping, let url = URL(string: "http://127.0.0.1:\(port)/health") else { return }
        http.dataTask(with: url) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self, !self.stopping else { return }
                guard err == nil, let data,
                      let h = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], h["ok"] as? Bool == true else {
                    self.coreFailures += 1
                    if self.coreFailures >= 6 {                  // unresponsive for 60 s
                        self.coreFailures = 0
                        self.restart("core")
                    }
                    return
                }
                self.coreFailures = 0
                if Date().timeIntervalSince(self.launchedAt["core"] ?? .distantPast) > 30 {
                    self.backoff["core"] = 1                     // healthy for a while: reset the restart backoff
                    self.stayedUp("core")
                }
                self.onHealth?(h)
                self.checkEngine(h)
                self.checkPage(h)
            }
        }.resume()
    }

    private func checkEngine(_ h: [String: Any]) {
        let sinceLaunch = Date().timeIntervalSince(launchedAt["engine"] ?? .distantPast)
        if let age = (h["vision_age"] as? NSNumber)?.doubleValue, age > 60 {
            if sinceLaunch > 30 { restart("engine") }            // give a fresh engine time to connect
            return
        }
        // engine connected and reporting: its worker thread must be alive too
        if let v = h["vision"] as? [String: Any], v["alive"] as? Bool == false, sinceLaunch > 60 {
            engineNotAlive += 1
            if engineNotAlive >= 3 { engineNotAlive = 0; restart("engine") }
        } else {
            engineNotAlive = 0
            // healthy (reporting right now, and up for a while): reset the restart backoff
            if procs["engine"]?.isRunning == true, sinceLaunch > 30,
               let age = (h["vision_age"] as? NSNumber)?.doubleValue, age < 5 {
                backoff["engine"] = 1
                stayedUp("engine")
            }
        }
    }

    /// A visible page must keep sending heartbeats. A hidden page is throttled by
    /// WebKit, so its heartbeat may be stale: only judge a page that has been on
    /// screen long enough to have sent one.
    private func checkPage(_ h: [String: Any]) {
        guard let shown = overlayShownAt(), Date().timeIntervalSince(shown) > 15,
              let age = (h["ui_age"] as? NSNumber)?.doubleValue, age > 60 else { return }
        AppLog.warning("page heartbeat is \(Int(age)) s old while the overlay is visible")
        onPageStale?()
    }

    // MARK: orphans

    private func writePidFile() {
        let d = pids.mapValues { Int($0) }
        if let data = try? JSONSerialization.data(withJSONObject: d) { try? data.write(to: Self.pidFile, options: .atomic) }
    }

    /// Helpers left running by an earlier copy of the app that crashed or was
    /// force-quit would hold the port and the frame socket: stop them first.
    private func killOrphans() {
        guard let data = try? Data(contentsOf: Self.pidFile),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Int] else { return }
        try? FileManager.default.removeItem(at: Self.pidFile)
        for (name, pid) in d {
            let p = pid_t(pid)
            guard p > 1, kill(p, 0) == 0, let cmd = Self.commandLine(p),
                  cmd.contains("hud.\(name)"), cmd.lowercased().contains("python") else { continue }
            AppLog.warning("stopping \(name) left over from an earlier run (pid \(p))")
            kill(p, SIGTERM)
            for _ in 0..<50 where kill(p, 0) == 0 { usleep(40_000) }
            if kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    private static func commandLine(_ pid: pid_t) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

/// Collects a process's output and keeps only the last few kilobytes, so a
/// crash can be reported without letting the output grow without bound.
final class OutputTail {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int

    init(limit: Int = 6000) {
        self.limit = limit
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            // at EOF (or once nobody wants the output) stop, or the handler fires forever
            guard !chunk.isEmpty, let self else { fh.readabilityHandler = nil; return }
            self.lock.lock()
            self.buffer.append(chunk)
            if self.buffer.count > 2 * self.limit { self.buffer = self.buffer.suffix(self.limit) }
            self.lock.unlock()
        }
    }

    /// Stop reading (the process has exited).
    func close() { pipe.fileHandleForReading.readabilityHandler = nil }

    deinit { pipe.fileHandleForReading.readabilityHandler = nil }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        let s = String(decoding: buffer.suffix(limit), as: UTF8.self)
        // drop MediaPipe / TensorFlow chatter so the report shows the Python error
        return s.split(separator: "\n").filter { line in
            !(line.hasPrefix("INFO: ") || line.hasPrefix("WARNING: [") || line.hasPrefix("I0000") || line.hasPrefix("W0000"))
        }.suffix(25).joined(separator: "\n")
    }
}
