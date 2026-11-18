// PythonSetup.swift — the Python environment the helpers run in
// (~/Library/Application Support/Waverly/venv: MediaPipe 1.2.3, aiohttp, numpy, at the
// exact versions tools/setup_macos.sh pins).
//
// EnvironmentInstaller runs the bundled tools/setup_macos.sh without any UI of
// its own (the setup wizard shows its phase, progress and log). The script needs
// `uv` or a Python 3.10+ interpreter. Waverly ships uv in Contents/Helpers/uv; uv
// then downloads its own Python 3.12 into Application Support, so a Mac with no
// Python works. Without the bundled uv (a developer build) this file looks for
// another uv or a python.org / Homebrew Python. A GUI app gets a minimal PATH, so
// the script gets a PATH that leads to what was found.

import AppKit

enum PythonEnvironment {
    static var marker: URL { HelperSupervisor.venv.appendingPathComponent(".hud-ready") }
    static var setupScript: URL { HelperSupervisor.resources.appendingPathComponent("tools/setup_macos.sh") }
    static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: HelperSupervisor.python.path) }
    /// The venv was built (or checked) for the package versions this copy of the app
    /// pins: the marker holds their fingerprint. After an update that changes the pins,
    /// the environment is checked again (and rebuilt if it doesn't match).
    static var isReady: Bool {
        guard hasPython, let data = FileManager.default.contents(atPath: marker.path) else { return false }
        guard let want = requirementsFingerprint else { return true }        // no pins to compare (a developer build)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == want
    }

    /// The fingerprint of the bundled setup script's pins (PythonRequirements).
    static let requirementsFingerprint: String? = {
        guard let text = try? String(contentsOf: setupScript, encoding: .utf8) else { return nil }
        return PythonRequirements.fingerprint(PythonRequirements.pins(inScript: text))
    }()

    /// Verify a venv the app did not just build (the script was run by hand, or an
    /// older Waverly built it for other pins): the script's --check imports what the
    /// helpers need and compares every package version. Calls back on the main thread.
    static func verify(_ done: @escaping (Bool) -> Void) {
        guard hasPython else { done(false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [setupScript.path, "--check"]
            var env = HelperSupervisor.baseEnvironment()
            env["GLOG_minloglevel"] = "2"
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var ok = false, said = ""
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                said = String(decoding: data.suffix(600), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if ok { markReady() } else if !said.isEmpty { AppLog.info("setup: the existing Python environment: \(said)") }
            DispatchQueue.main.async { done(ok) }
        }
    }

    static func markReady() {
        let stamp = requirementsFingerprint ?? "ok"
        FileManager.default.createFile(atPath: marker.path, contents: Data("\(stamp)\n".utf8))
    }

    /// What tools/setup_macos.sh will use: a `uv` binary, or a Python 3.10+.
    enum Tool { case uv(String, bundled: Bool), python(String) }

    /// The uv shipped inside the app (scripts/fetch_uv.sh + the build), if any.
    static var bundledUV: String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/uv").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    static func findTool() -> Tool? {
        if let uv = bundledUV { return .uv(uv, bundled: true) }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        where fm.isExecutableFile(atPath: p) { return .uv(p, bundled: false) }
        var dirs = ["/Library/Frameworks/Python.framework/Versions/Current/bin"]
        if let vs = try? fm.contentsOfDirectory(atPath: "/Library/Frameworks/Python.framework/Versions") {
            dirs += vs.filter { $0.hasPrefix("3.") }.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "/Library/Frameworks/Python.framework/Versions/\($0)/bin" }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]       // never /usr/bin: Apple's python3 is 3.9
        for name in ["python3.12", "python3.13", "python3.11", "python3.10", "python3.14", "python3"] {
            for d in dirs {
                let p = "\(d)/\(name)"
                if fm.isExecutableFile(atPath: p), pythonIsRecentEnough(p) { return .python(p) }
            }
        }
        return nil
    }

    private static func pythonIsRecentEnough(_ path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// A process and everything it started (the setup script runs pip, uv, python...).
enum ProcessTree {
    static func descendants(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let kids = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return kids + kids.flatMap { descendants(of: $0) }
    }

    static func terminate(_ pid: pid_t) {
        let all = [pid] + descendants(of: pid)
        for p in all { kill(p, SIGTERM) }
    }

    static func commandLine(_ pid: pid_t) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}


/// Installs the Python environment (no UI of its own: the setup wizard shows the
/// phase, progress and log). `start()` is idempotent and starts again after a
/// failure; an environment that already works is ready at once.
@MainActor final class EnvironmentInstaller: ObservableObject {
    static let shared = EnvironmentInstaller()

    enum Phase: Equatable { case idle, checking, needsPython, installing, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log = ""                 // the script's output (the last ~200 KB)
    @Published private(set) var progress: Double?        // rough 0...1 from the script's milestones

    nonisolated private static var pidFile: URL { HelperSupervisor.appSupport.appendingPathComponent("setup.pid") }
    private static var logFile: URL { AppLog.directory.appendingPathComponent("setup.log") }
    private static let logLimit = 200_000

    private var proc: Process?
    private var run = 0                                  // bumped by cancel(): late callbacks of an old run are ignored
    private var pending = ""
    private var flushScheduled = false
    private var partialLine = ""
    private var fileLog: FileHandle?
    private var creep: Timer?
    private var stage = (from: 0.0, to: 0.0, tau: 1.0, since: Date())

    private init() {}

    func start() {
        switch phase {
        case .checking, .installing, .ready: return
        case .idle, .needsPython, .failed: break
        }
        if PythonEnvironment.isReady {
            phase = .ready
            progress = 1
            return
        }
        run += 1
        let id = run
        if PythonEnvironment.hasPython {
            // a venv made outside the app (or by an older copy): use it if it works
            phase = .checking
            progress = nil
            PythonEnvironment.verify { [weak self] ok in
                guard let self, self.run == id else { return }
                if ok {
                    AppLog.info("setup: the existing Python environment works")
                    self.becomeReady()
                } else {
                    self.install(id)
                }
            }
        } else {
            install(id)
        }
    }

    /// Stops the script and everything it started (setup closed, or Waverly is quitting).
    func cancel() {
        run += 1
        stopCreep()
        if let p = proc {
            if p.isRunning {
                AppLog.info("setup: stopped")
                ProcessTree.terminate(p.processIdentifier)
            }
            // only a setup this copy started: another copy's pid file lets it be found if that copy dies
            try? FileManager.default.removeItem(at: Self.pidFile)
        }
        proc = nil
        closeFileLog()
        if phase != .ready {
            phase = .idle
            progress = nil
        }
    }

    func openPythonDownload() {
        NSWorkspace.shared.open(URL(string: "https://www.python.org/downloads/macos/")!)
    }

    // MARK: running the script

    private func install(_ id: Int) {
        let script = PythonEnvironment.setupScript
        guard FileManager.default.fileExists(atPath: script.path) else {
            AppLog.error("setup: \(script.path) is missing")
            phase = .failed("Waverly's setup files are missing. Download Waverly again and replace this copy.")
            return
        }
        phase = .installing
        progress = 0.01
        log = ""
        partialLine = ""
        // finding a Python runs a few short processes, and an orphaned setup may need stopping: off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let tool = PythonEnvironment.findTool()
            if tool != nil { Self.clearLeftovers() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.run == id else { return }
                guard let tool else {
                    AppLog.warning("setup: no bundled uv, other uv or Python 3.10+ found")
                    self.phase = .needsPython
                    self.progress = nil
                    return
                }
                self.launch(script, tool, id)
            }
        }
    }

    /// A setup left running by an earlier copy of Waverly (it crashed or was force-quit)
    /// must not keep writing into the folder about to be rebuilt; a venv left
    /// half-made by an earlier attempt, or one whose Python is gone (its interpreter in
    /// Application Support/Waverly/python was removed), is removed first.
    nonisolated private static func clearLeftovers() {
        let fm = FileManager.default
        if let txt = try? String(contentsOf: pidFile, encoding: .utf8),
           let old = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
           old > 1, kill(old, 0) == 0, ProcessTree.commandLine(old).contains("setup_macos.sh") {
            AppLog.warning("setup: stopping an earlier setup still running (pid \(old))")
            ProcessTree.terminate(old)
            Thread.sleep(forTimeInterval: 1)
        }
        let venv = HelperSupervisor.venv
        if fm.fileExists(atPath: venv.path)
            && (!fm.fileExists(atPath: PythonEnvironment.marker.path) || !PythonEnvironment.hasPython) {
            try? fm.removeItem(at: venv)
        }
    }

    private func launch(_ script: URL, _ tool: PythonEnvironment.Tool, _ id: Int) {
        let fm = FileManager.default
        openFileLog()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        // The script picks `uv` if it is on PATH, else python3.12 / python3: lead it to what we found.
        let shim = fm.temporaryDirectory.appendingPathComponent("waverly-setup-bin", isDirectory: true)
        try? fm.removeItem(at: shim)
        try? fm.createDirectory(at: shim, withIntermediateDirectories: true)
        switch tool {
        case .uv(let path, let bundled):
            try? fm.createSymbolicLink(atPath: shim.appendingPathComponent("uv").path, withDestinationPath: path)
            if bundled {
                // the app's own Python, never one that a Homebrew upgrade could pull away
                env["UV_PYTHON_PREFERENCE"] = "only-managed"
                append("Using Waverly's bundled uv\n")
            } else {
                append("Using uv at \(path)\n")
            }
        case .python(let path):
            // a wrapper, not a symlink: the venv must record the real interpreter, not this temporary path
            let wrapper = shim.appendingPathComponent("python3").path
            let q = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            fm.createFile(atPath: wrapper, contents: Data("#!/bin/sh\nexec \(q) \"$@\"\n".utf8),
                          attributes: [.posixPermissions: 0o755])
            append("Using Python at \(path)\n")
        }
        env["PATH"] = "\(shim.path):/usr/bin:/bin:/usr/sbin:/sbin"
        for k in ["PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX", "UV_PYTHON", "UV_INDEX_URL"] { env[k] = nil }
        env["UV_PYTHON_INSTALL_DIR"] = HelperSupervisor.appSupport.appendingPathComponent("python").path
        env["UV_CACHE_DIR"] = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Waverly/uv").path
        env["HUD_STATE"] = HelperSupervisor.appSupport.path   // the script builds the venv where the app looks for it
        env["UV_NO_PROGRESS"] = "1"
        env["NO_COLOR"] = "1"
        env["PIP_PROGRESS_BAR"] = "off"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PYTHONPYCACHEPREFIX"] = HelperSupervisor.pycache.path
        if let ca = HelperSupervisor.caBundle ?? (fm.isReadableFile(atPath: "/etc/ssl/cert.pem") ? "/etc/ssl/cert.pem" : nil) {
            env["SSL_CERT_FILE"] = ca
        }
        p.environment = env
        p.currentDirectoryURL = fm.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if d.isEmpty { fh.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { if self?.run == id { self?.append(s) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            // after the last output has been read
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.finished(code, id) }
        }
        do {
            try p.run()
            proc = p
            try? "\(p.processIdentifier)\n".write(to: Self.pidFile, atomically: true, encoding: .utf8)
            AppLog.info("setup: installing the Python environment (\(Self.describe(tool)))")
            setStage(0.02, to: 0.05, tau: 10)
            startCreep()
        } catch {
            append("Could not start the setup script: \(error.localizedDescription)\n")
            finished(-1, id)
        }
    }

    private func finished(_ code: Int32, _ id: Int) {
        guard run == id else { return }
        flush()
        proc = nil
        stopCreep()
        closeFileLog()
        try? FileManager.default.removeItem(at: Self.pidFile)
        if code == 0 && PythonEnvironment.hasPython {
            PythonEnvironment.markReady()
            AppLog.info("setup: Python environment ready")
            becomeReady()
        } else {
            AppLog.error("setup: failed with status \(code) (log: \(Self.logFile.path))")
            phase = .failed(failureMessage(code))
            progress = nil
        }
    }

    private func becomeReady() {
        phase = .ready
        progress = 1
    }

    private func failureMessage(_ code: Int32) -> String {
        let l = log.lowercased()
        if l.contains("no space left") {
            return "Your Mac is out of disk space. Free up about 1 GB, then try again."
        }
        let network = ["failed to download", "could not resolve", "connection", "network is unreachable", "timed out",
                       "dns error", "error sending request", "temporary failure in name resolution", "ssl"]
        if network.contains(where: l.contains) {
            return "Waverly couldn't download the hand-tracking engine. Check your internet connection, then try again."
        }
        return "The installer stopped with an error (status \(code)). The details below show what happened."
    }

    private static func describe(_ t: PythonEnvironment.Tool) -> String {
        switch t {
        case .uv(let p, let bundled): bundled ? "bundled uv" : "uv at \(p)"
        case .python(let p): "Python at \(p)"
        }
    }

    // MARK: output and progress

    private func append(_ s: String) {
        if let d = s.data(using: .utf8) { try? fileLog?.write(contentsOf: d) }
        pending += s
        scanMilestones(s)
        guard !flushScheduled else { return }
        flushScheduled = true
        // publish at most four times a second: pip can print hundreds of lines at once
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        var l = log + pending
        pending = ""
        if l.utf8.count > Self.logLimit {
            l = String(l.suffix(Self.logLimit))
            if let nl = l.firstIndex(of: "\n") { l = String(l[l.index(after: nl)...]) }
        }
        log = l
    }

    /// Recognised lines of tools/setup_macos.sh, uv and pip move the bar on; between
    /// them it creeps towards the next milestone so a long download still shows life.
    private func scanMilestones(_ s: String) {
        let text = partialLine + s
        var lines = text.components(separatedBy: "\n")
        partialLine = lines.removeLast()
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("==> Creating") { setStage(0.04, to: 0.14, tau: 25) }
            else if t.hasPrefix("Using CPython") || t.hasPrefix("Creating virtual environment") || t.hasPrefix("Python 3.") {
                setStage(0.10, to: 0.14, tau: 10)
            }
            else if t.hasPrefix("==> Downloading") { setStage(0.15, to: 0.82, tau: 110) }
            else if t.hasPrefix("Resolved ") || t.hasPrefix("Collecting ") { setStage(0.2, to: 0.82, tau: 100) }
            else if t.hasPrefix("Prepared ") || t.hasPrefix("Installing collected packages") { setStage(0.82, to: 0.9, tau: 15) }
            else if t.hasPrefix("Installed ") || t.hasPrefix("Successfully installed") { setStage(0.9, to: 0.92, tau: 5) }
            else if t.hasPrefix("==> Checking") { setStage(0.92, to: 0.99, tau: 12) }
            else if t.hasPrefix("==> Done") { setStage(1, to: 1, tau: 1) }
        }
    }

    private func setStage(_ from: Double, to: Double, tau: Double) {
        let now = progress ?? 0
        guard from >= now || to > stage.to else { return }       // never move backwards
        stage = (max(from, now), max(to, from), tau, Date())
        progress = stage.from
    }

    private func startCreep() {
        stopCreep()
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let me = EnvironmentInstaller.shared
                guard me.phase == .installing else { return }
                let s = me.stage
                let dt = Date().timeIntervalSince(s.since)
                let v = s.from + (s.to - s.from) * (1 - exp(-dt / s.tau))
                if v > (me.progress ?? 0) + 0.001 { me.progress = v }
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        creep = t
    }

    private func stopCreep() {
        creep?.invalidate()
        creep = nil
    }

    private func openFileLog() {
        closeFileLog()
        let fm = FileManager.default
        try? fm.createDirectory(at: AppLog.directory, withIntermediateDirectories: true)
        fm.createFile(atPath: Self.logFile.path, contents: nil)
        fileLog = try? FileHandle(forWritingTo: Self.logFile)
    }

    private func closeFileLog() {
        try? fileLog?.close()
        fileLog = nil
    }
}
