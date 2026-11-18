// GoogleAuth.swift — signs in to Google natively (OAuth 2.0 for installed apps):
//
//   1. a one-shot HTTP server on 127.0.0.1 (ephemeral port) is the redirect target
//   2. the default browser opens Google's consent page (PKCE S256 + a random state)
//   3. Google redirects to http://127.0.0.1:<port>/?code=…&state=…; the server checks
//      the state, exchanges the code for a refresh token, and answers the browser
//      with a small "Connected" (or error) page in the Waverly look
//   4. the account's e-mail comes from calendars/primary ("id")
//   5. HUD_STATE/google_client.json + google_token.json are written (chmod 600);
//      hud-core notices them and starts fetching
//
// Scopes: calendar.readonly + tasks (tasks to mark a task completed when it's checked
// off on the HUD; Waverly changes nothing else). Google lets the user untick either:
// a sign-in with only one of them still connects and shows what it allows. Sign-ins
// from before checking off hold tasks.readonly instead: they keep reading tasks, and
// Settings › Google offers to sign in again (tasksAccess). The client is Waverly's built-in one
// (Info.plist HUGoogleClientID / HUGoogleClientSecret, filled in at build time
// from macos/Config/Secrets.xcconfig) or the user's own from a Google Cloud
// "client_secret_….json" (Settings › Google › Advanced). google_client.json always
// holds the client the saved token was issued to, so the pair hud-core uses
// matches. Tokens are never logged.

import AppKit
import CryptoKit
import Foundation
import Network

@MainActor final class GoogleAuth: ObservableObject {
    static let shared = GoogleAuth()

    enum State: Equatable { case disconnected, connecting, connected(account: String?), failed(String) }

    struct Client: Equatable {
        let id: String
        let secret: String
        let source: String          // "builtin" | "custom"
    }

    struct Endpoints {
        var authorize = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var token = URL(string: "https://oauth2.googleapis.com/token")!
        var revoke = URL(string: "https://oauth2.googleapis.com/revoke")!
        var primaryCalendar = URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary")!
    }

    enum ClientFileError: LocalizedError {
        case unreadable, notAClient
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't a JSON file."
            case .notAClient: "It has no OAuth client ID."
            }
        }
    }

    static let scopes = ["https://www.googleapis.com/auth/calendar.readonly",
                         "https://www.googleapis.com/auth/tasks"]
    static let tasksReadOnly = "https://www.googleapis.com/auth/tasks.readonly"
    /// What a saved sign-in may hold: the scopes asked for, and tasks.readonly from older sign-ins.
    static let knownScopes = scopes + [tasksReadOnly]

    /// What the saved sign-in allows with tasks: check them off, only read them, or nothing.
    enum TasksAccess: Equatable { case full, readOnly, none }
    var timeout: TimeInterval = 300                       // seconds a sign-in may take

    @Published private(set) var state: State = .disconnected { didSet { tasksAccess = savedTasksAccess() } }
    @Published private(set) var customClientID: String?
    @Published private(set) var tasksAccess: TasksAccess = .none

    var hasBuiltInClient: Bool { builtIn != nil }

    // Overridable for tests (scratch harness with a fake Google).
    var endpoints = Endpoints()
    var openBrowser: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Called when a sign-in started by `connect()` ends (true = connected).
    var onFinish: ((Bool) -> Void)?

    private let stateDir: URL
    private let builtIn: Client?
    private var flow: Flow?
    private let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private var clientFile: URL { stateDir.appendingPathComponent("google_client.json") }
    private var tokenFile: URL { stateDir.appendingPathComponent("google_token.json") }
    private var customFile: URL { stateDir.appendingPathComponent("google_custom_client.json") }

    convenience init() {
        self.init(stateDir: HelperSupervisor.appSupport, builtIn: Self.infoPlistClient())
    }

    init(stateDir: URL, builtIn: Client?) {
        self.stateDir = stateDir
        self.builtIn = builtIn
        if let c = Self.readJSON(customFile), let id = c["client_id"] as? String, !id.isEmpty { customClientID = id }
        state = savedState()
        tasksAccess = savedTasksAccess()
        refreshBuiltInSecret()
    }

    // MARK: API

    /// Starts a sign-in in the browser. Also reconnects when already connected (a
    /// new token replaces the old one only once Google says yes). While a sign-in
    /// is open, shows Google's page again.
    func connect() {
        if let flow, state == .connecting {
            if let url = flow.authURL { _ = openBrowser(url) }
            return
        }
        guard let client = activeClient else {
            state = .failed("Choose a Google client file first (Settings › Google › Advanced).")
            return
        }
        let f = Flow(client: client)
        flow = f
        state = .connecting
        AppLog.info("Google: starting sign-in (\(client.source) client)")
        f.server.onRequest = { [weak self, weak f] req, respond in
            MainActor.assumeIsolated {
                guard let self, let f, self.flow === f else { respond(Self.page(ok: false, "This sign-in has ended. Go back to Waverly and try again.", status: 410)); return }
                self.handle(req, respond, f)
            }
        }
        f.server.start { [weak self, weak f] port in
            MainActor.assumeIsolated {
                guard let self, let f, self.flow === f else { return }
                guard let port else {
                    self.finish(f, .failure("Waverly couldn't start the sign-in. Try again."))
                    return
                }
                f.redirect = "http://127.0.0.1:\(port)"
                let url = self.authorizationURL(f)
                f.authURL = url
                if !self.openBrowser(url) {
                    self.finish(f, .failure("Waverly couldn't open your web browser."))
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak f] in
            guard let self, let f, self.flow === f else { return }
            AppLog.warning("Google: sign-in timed out")
            self.finish(f, .failure("The sign-in timed out. Try again when you're ready."))
        }
        f.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + self.timeout, execute: timeout)
    }

    /// Stops a sign-in in progress.
    func cancel() {
        guard let f = flow else { return }
        AppLog.info("Google: sign-in cancelled")
        f.close()
        flow = nil
        state = savedState()
        onFinish?(false)
    }

    /// Forgets the sign-in: revokes the token at Google and deletes it.
    func disconnect() {
        if let f = flow { f.close(); flow = nil }
        let token = Self.readJSON(tokenFile)?["refresh_token"] as? String
        try? FileManager.default.removeItem(at: tokenFile)
        state = .disconnected
        AppLog.info("Google: disconnected")
        guard let token else { return }
        var req = URLRequest(url: endpoints.revoke)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(["token": token])
        http.dataTask(with: req) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || code != 200 {
                // the token is gone from this Mac either way; Google lets it expire unused
                AppLog.warning("Google: could not revoke the old sign-in (\(error?.localizedDescription ?? "HTTP \(code)"))")
            }
        }.resume()
    }

    /// Uses the user's own OAuth client from a Google Cloud Console download
    /// ("installed" or "web" client). A sign-in made with another client ends.
    func useCustomClient(from url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ClientFileError.unreadable }
        guard let c = (d["installed"] ?? d["web"]) as? [String: Any],
              let id = (c["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
              !id.contains(where: { $0.isWhitespace }) else { throw ClientFileError.notAClient }
        let secret = (c["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let out = try JSONSerialization.data(withJSONObject: ["client_id": id, "client_secret": secret], options: [.sortedKeys])
        try Self.writeSecret(out, to: customFile)
        customClientID = id
        AppLog.info("Google: using a custom OAuth client")
        clientChanged()
    }

    /// Back to Waverly's own client. A sign-in made with the custom client ends.
    func useBuiltInClient() {
        try? FileManager.default.removeItem(at: customFile)
        customClientID = nil
        AppLog.info("Google: using the built-in OAuth client")
        clientChanged()
    }

    // MARK: flow

    /// One sign-in attempt.
    private final class Flow {
        let client: Client
        let verifier = GoogleAuth.randomToken(48)
        let stateToken = GoogleAuth.randomToken(24)
        let server = LoopbackServer()
        var redirect = ""
        var authURL: URL?
        var timeout: DispatchWorkItem?
        var exchanging = false
        init(client: Client) { self.client = client }
        func close() {
            timeout?.cancel()
            server.stop()
        }
    }

    private enum Outcome { case success(account: String?), failure(String) }

    private func authorizationURL(_ f: Flow) -> URL {
        let challenge = Data(SHA256.hash(data: Data(f.verifier.utf8))).base64URL
        var c = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: f.client.id),
            .init(name: "redirect_uri", value: f.redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: f.stateToken),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),         // always issue a refresh token, also on reconnect
        ]
        // URLComponents leaves "+" alone, which a server reads as a space
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    private func handle(_ req: LoopbackServer.Request, _ respond: @escaping (LoopbackServer.Response) -> Void, _ f: Flow) {
        guard req.method == "GET", req.path == "/" else {
            respond(.init(status: 404, body: Data()))                 // favicon and the like
            return
        }
        let q = req.query
        guard q["code"] != nil || q["error"] != nil else {
            respond(.init(status: 404, body: Data()))
            return
        }
        guard let st = q["state"], Self.constantTimeEqual(st, f.stateToken) else {
            // not our sign-in (an old tab, or someone else): keep waiting for the real one
            AppLog.warning("Google: ignored a redirect with the wrong state")
            respond(Self.page(ok: false, "This sign-in link is out of date. Go back to Waverly and try again.", status: 400))
            return
        }
        if let err = q["error"] {
            let msg = err == "access_denied" ? "Google sign-in was cancelled. Try again when you're ready."
                                             : "Google didn't allow the sign-in (\(err))."
            AppLog.warning("Google: sign-in refused (\(err))")
            respond(Self.page(ok: false, msg))
            finish(f, .failure(msg))
            return
        }
        guard !f.exchanging, let code = q["code"], !code.isEmpty else {
            respond(Self.page(ok: false, "This sign-in is already being finished in Waverly.", status: 409))
            return
        }
        f.exchanging = true
        f.timeout?.cancel()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.exchange(code, f)
            guard self.flow === f else {
                respond(Self.page(ok: false, "This sign-in has ended. Go back to Waverly and try again.", status: 410))
                return
            }
            switch outcome {
            case .success: respond(Self.page(ok: true, "Waverly can now show your calendar. You can close this tab."))
            case .failure(let m): respond(Self.page(ok: false, m))
            }
            // let the page reach the browser before the server stops
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish(f, outcome) }
        }
    }

    private func exchange(_ code: String, _ f: Flow) async -> Outcome {
        var req = URLRequest(url: endpoints.token)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["code": code, "client_id": f.client.id, "redirect_uri": f.redirect,
                      "grant_type": "authorization_code", "code_verifier": f.verifier]
        if !f.client.secret.isEmpty { fields["client_secret"] = f.client.secret }   // a client without one: PKCE only
        req.httpBody = Self.form(fields)
        let body: [String: Any]
        do {
            let (data, response) = try await http.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard status == 200 else {
                let err = d["error"] as? String ?? "HTTP \(status)"
                AppLog.warning("Google: code exchange failed (\(err))")
                if err == "invalid_client" || err == "unauthorized_client" {
                    return .failure("Google didn't accept Waverly's client (\(err)). Check the client file in Settings › Google › Advanced.")
                }
                return .failure("Google didn't finish the sign-in (\(err)). Try again.")
            }
            body = d
        } catch {
            AppLog.warning("Google: code exchange failed (\(error.localizedDescription))")
            return .failure("Waverly couldn't reach Google. Check your internet connection and try again.")
        }
        guard let refresh = body["refresh_token"] as? String, !refresh.isEmpty else {
            AppLog.warning("Google: no refresh token in the answer")
            return .failure("Google didn't give Waverly lasting access. Try again.")
        }
        let granted = (body["scope"] as? String)?.split(separator: " ").map(String.init) ?? Self.scopes
        // Saved as granted: a calendar-only (or read-only tasks) sign-in still connects for
        // reading; hud-core offers checking off only with the tasks scope.
        let ours = Self.knownScopes.filter(granted.contains)
        guard !ours.isEmpty else {
            AppLog.warning("Google: neither calendar nor tasks access was allowed")
            return .failure("Waverly needs access to your calendar or tasks. Try again and leave the boxes ticked.")
        }
        if !Self.scopes.allSatisfy(granted.contains) {
            AppLog.warning("Google: only part of the access was allowed (\(ours.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: ", ")))")
        }
        var account: String?
        if let access = body["access_token"] as? String, granted.contains(Self.scopes[0]) {
            account = await primaryCalendarID(access)
        }
        do {
            let client = try JSONSerialization.data(withJSONObject: ["client_id": f.client.id, "client_secret": f.client.secret,
                                                                     "source": f.client.source], options: [.sortedKeys])
            var tok: [String: Any] = ["refresh_token": refresh, "scopes": ours]
            if let account { tok["account"] = account }
            let token = try JSONSerialization.data(withJSONObject: tok, options: [.sortedKeys])
            try Self.writeSecret(client, to: clientFile)
            try Self.writeSecret(token, to: tokenFile)
        } catch {
            AppLog.error("Google: could not save the sign-in (\(error.localizedDescription))")
            return .failure("Waverly couldn't save the sign-in (\(error.localizedDescription)).")
        }
        return .success(account: account)
    }

    /// The signed-in account's e-mail: the primary calendar's ID.
    private func primaryCalendarID(_ access: String) async -> String? {
        var req = URLRequest(url: endpoints.primaryCalendar)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await http.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = d["id"] as? String, id.contains("@") else { return nil }
        return id
    }

    private func finish(_ f: Flow, _ outcome: Outcome) {
        guard flow === f else { return }
        f.close()
        flow = nil
        switch outcome {
        case .success(let account):
            state = .connected(account: account)
            AppLog.info("Google: connected")
            // back to the window the sign-in was started from
            if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.activate(ignoringOtherApps: true)
            }
            onFinish?(true)
        case .failure(let message):
            state = .failed(message)
            onFinish?(false)
        }
    }

    // MARK: clients and files

    private var activeClient: Client? {
        if let c = Self.readJSON(customFile), let id = c["client_id"] as? String, !id.isEmpty {
            return Client(id: id, secret: c["client_secret"] as? String ?? "", source: "custom")
        }
        return builtIn
    }

    /// What the files on disk say: connected when a refresh token is saved.
    private func savedState() -> State {
        guard let t = Self.readJSON(tokenFile), let r = t["refresh_token"] as? String, !r.isEmpty else { return .disconnected }
        return .connected(account: t["account"] as? String)
    }

    private func savedTasksAccess() -> TasksAccess {
        let scopes = Self.readJSON(tokenFile)?["scopes"] as? [String] ?? []
        return scopes.contains(Self.scopes[1]) ? .full : scopes.contains(Self.tasksReadOnly) ? .readOnly : .none
    }

    /// After choosing another client: a token issued to the old one can't be used
    /// with the new one, so that sign-in ends.
    private func clientChanged() {
        if let f = flow { f.close(); flow = nil }
        let saved = Self.readJSON(clientFile)?["client_id"] as? String
        if case .connected = savedState(), let saved, saved != activeClient?.id {
            AppLog.info("Google: the client changed; signing out of the old one")
            disconnect()
        } else {
            state = savedState()
        }
    }

    /// A new build may carry a new secret for the same built-in client.
    private func refreshBuiltInSecret() {
        guard let b = builtIn, var c = Self.readJSON(clientFile), c["source"] as? String == "builtin",
              c["client_id"] as? String == b.id, c["client_secret"] as? String != b.secret else { return }
        c["client_secret"] = b.secret
        if let data = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys]) {
            try? Self.writeSecret(data, to: clientFile)
        }
    }

    private static func infoPlistClient() -> Client? {
        let info = Bundle.main.infoDictionary ?? [:]
        let id = (info["HUGoogleClientID"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (info["HUGoogleClientSecret"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return Client(id: id, secret: secret.hasPrefix("$(") ? "" : secret, source: "builtin")
    }

    nonisolated static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Writes a file only the user can read (0600), atomically (temp file + rename).
    nonisolated static func writeSecret(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard ok, rename(tmp.path, url.path) == 0 else {
            let e = POSIXErrorCode(rawValue: errno) ?? .EIO
            unlink(tmp.path)
            throw POSIXError(e)
        }
    }

    // MARK: helpers

    nonisolated static func randomToken(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        let ok = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        precondition(ok == errSecSuccess, "no secure random bytes")
        return Data(b).base64URL
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    nonisolated static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.sorted { $0.key < $1.key }.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(v.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    /// The page the browser shows at the end: the sunset sky of the app icon with a short message.
    nonisolated static func page(ok: Bool, _ message: String, status: Int = 200) -> LoopbackServer.Response {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let title = ok ? "Connected" : "Couldn't connect"
        let mark = ok
            ? "<path d=\"M14 24.5l6.5 6.5L34 17.5\" fill=\"none\" stroke=\"#8BE0A4\" stroke-width=\"3.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
            : "<path d=\"M24 14v12M24 32.5v.5\" fill=\"none\" stroke=\"#FFC37A\" stroke-width=\"3.2\" stroke-linecap=\"round\"/>"
        let html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Waverly — \(title)</title>
        <style>
        html,body{height:100%;margin:0}
        body{display:flex;align-items:center;justify-content:center;color:#fff;
          font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased;
          background:radial-gradient(120% 55% at 50% 115%,rgba(255,178,122,.55),rgba(233,137,90,.38) 32%,rgba(122,62,110,.24) 60%,rgba(122,62,110,0) 80%),
                     linear-gradient(180deg,#1F2752 0%,#29295A 50%,#372B5F 80%,#4A2F64 100%)}
        .card{width:min(420px,calc(100vw - 48px));padding:40px 36px 34px;text-align:center;border-radius:22px;
          background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.13);
          box-shadow:0 30px 80px rgba(20,12,40,.45);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px)}
        svg{width:56px;height:56px;margin-bottom:14px}
        h1{margin:0 0 8px;font:650 26px/1.2 "Bricolage Grotesque",-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:-.01em}
        p{margin:0;color:rgba(255,255,255,.78)}
        .brand{margin-top:26px;font:600 13px/1 "Bricolage Grotesque",-apple-system,BlinkMacSystemFont,sans-serif;letter-spacing:.02em;color:rgba(255,255,255,.7)}
        </style></head>
        <body><main class="card">
        <svg viewBox="0 0 48 48" aria-hidden="true"><circle cx="24" cy="24" r="22" fill="rgba(255,255,255,.08)" stroke="rgba(255,255,255,.16)"/>\(mark)</svg>
        <h1>\(title)</h1>
        <p>\(esc(message))</p>
        <div class="brand">Waverly</div>
        </main></body></html>
        """
        return .init(status: status, body: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 for the OAuth redirect: one request per
/// connection, answered once, then the connection closes.
final class LoopbackServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
    }

    struct Response {
        var status: Int
        var body: Data
        var contentType = "text/plain; charset=utf-8"
    }

    /// Called on the main queue; `respond` may be called later, from any thread, once.
    var onRequest: ((Request, @escaping (Response) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "waverly.oauth-loopback")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Listens on an ephemeral port; `ready` gets the port (nil on failure) on the main queue.
    func start(ready: @escaping (UInt16?) -> Void) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = false
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            AppLog.error("Google: could not listen for the sign-in (\(error.localizedDescription))")
            DispatchQueue.main.async { ready(nil) }
            return
        }
        var reported = false
        l.stateUpdateHandler = { [weak l] st in
            switch st {
            case .ready:
                guard !reported else { return }
                reported = true
                let port = l?.port?.rawValue
                DispatchQueue.main.async { ready(port) }
            case .failed(let e):
                AppLog.error("Google: the sign-in listener failed (\(e.localizedDescription))")
                l?.cancel()
                if !reported { reported = true; DispatchQueue.main.async { ready(nil) } }
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            // connections still being answered finish on their own (they hold the response)
        }
    }

    private func accept(_ c: NWConnection) {
        let key = ObjectIdentifier(c)
        connections[key] = c
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.queue.async { self?.connections[key] = nil }
            default: break
            }
        }
        c.start(queue: queue)
        receive(c, Data())
        // a client that never sends a full request is dropped
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.connections[key] != nil, c.state != .cancelled { c.cancel() }
        }
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.dispatch(c, buf.subdata(in: buf.startIndex..<end.lowerBound))
            } else if error != nil || done || buf.count > 32_768 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func dispatch(_ c: NWConnection, _ head: Data) {
        let line = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1].hasPrefix("/"),
              let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            send(c, Response(status: 400, body: Data()))
            return
        }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value ?? "" }
        let req = Request(method: String(parts[0]), path: comps.path.isEmpty ? "/" : comps.path, query: query)
        let once = Once()
        DispatchQueue.main.async {
            guard let handler = self.onRequest else { self.send(c, Response(status: 503, body: Data())); return }
            handler(req) { response in
                guard once.claim() else { return }
                self.queue.async { self.send(c, response) }
            }
        }
    }

    private func send(_ c: NWConnection, _ r: Response) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 409: "Conflict", 410: "Gone",
                      503: "Service Unavailable"][r.status] ?? "Error"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
        head += "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
        head += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
