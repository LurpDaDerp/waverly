// CoreLink.swift — the app's WebSocket connection to hud-core (/ws), the same hub
// the page uses. Through it the app receives the engine's requests (overlay
// show / hide / prepare, camera-want) and sends keyboard actions ("force"),
// overlay confirmations ("overlay-ready" / "overlay-hidden"), its camera mode and
// "config-changed" after each save of config.json (hud-core then re-reads it at once).
// It connects as ?client=app: hud-core sends the engine's status (vstat, every 2 s)
// only to the app (and to a ?debug page), so the hidden page is not woken for it.
// Reconnects forever (hud-core may be starting or restarting). Main thread only.

import Foundation

final class CoreLink: NSObject, URLSessionWebSocketDelegate {
    var onMessage: (([String: Any]) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    private(set) var isConnected = false

    private let url: URL
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var reconnectPending = false

    init(port: Int) {
        url = URL(string: "ws://127.0.0.1:\(port)/ws?client=app")!
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]                   // never send localhost traffic through a proxy
        cfg.timeoutIntervalForRequest = 10
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    func start() { connect() }

    private func connect() {
        generation += 1
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 16 << 20                      // data snapshots can be large
        task = t
        t.resume()
        receive(t, generation)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let d = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] {
                        self.onMessage?(d)
                    }
                    self.receive(t, gen)
                case .failure:
                    self.reconnectSoon(gen)
                }
            }
        }
    }

    /// Drop the current connection (if `gen` is still current) and try again shortly.
    private func reconnectSoon(_ gen: Int) {
        guard gen == generation, !reconnectPending else { return }
        reconnectPending = true
        let wasConnected = isConnected
        isConnected = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if wasConnected { onDisconnected?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            self.connect()
        }
    }

    func send(_ obj: [String: Any]) {
        guard let t = task, isConnected,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { _ in }
    }

    // MARK: URLSessionWebSocketDelegate (main queue)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        isConnected = true
        AppLog.info("connected to hud-core")
        onConnected?()
        schedulePing(webSocketTask, generation)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        reconnectSoon(generation)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        reconnectSoon(generation)
    }

    /// Keep-alive that also notices a dead hud-core.
    private func schedulePing(_ t: URLSessionWebSocketTask, _ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, gen == self.generation, self.isConnected else { return }
            t.sendPing { [weak self] err in
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    if err != nil { self.reconnectSoon(gen) } else { self.schedulePing(t, gen) }
                }
            }
        }
    }
}
