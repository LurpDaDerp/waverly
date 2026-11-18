// DebugControl.swift — developer hook for automated verification. Off (no socket,
// nothing listening) unless the user default "HUDDebugSocket" names a socket path:
//
//   open -n build/Waverly.app --args -HUDDebugSocket /tmp/waverly-debug.sock
//
// One command per connection (a single line), answered with one line of JSON:
//   status                  app state (setup, overlay, camera, link, helpers, hotkeys, windows)
//   config                  config.json as saved
//   onboard-skip [name]     finish the setup wizard without clicking (sets name + onboarded)
//   wizard [env]            show the setup wizard (env: only the environment page)
//   settings [tab]          open Settings (general | appearance | controls | lists | labels | google | permissions)
//   set <key> <value>       change a setting: theme, weather_detail, parallax, weather_animation,
//                           open_animation_s / close_animation_s (seconds, or instant / 0),
//                           open_animation / close_animation (fade | zoom | shatter | slide | swirl),
//                           scroll_speed_vertical / scroll_speed_horizontal (0.5…2),
//                           gesture_open_wave, gesture_open_fist, gesture_close_fist, auto_close_away, auto_close_dark,
//                           scroll_reverse_vertical, scroll_reverse_horizontal, hotkey (<key code> <fn,shift,…> | default)
//   hotkey-test <code> [mods] [visible] [repeat]   what the key tap would do with that key press
//   installer | install     the Python environment installer's state | start it
//   permissions             camera / accessibility / location states
//   location [refresh]      location state (and take a fix)
//   place <city>            the city search (MapKit)
//   google                  Google sign-in state
//   menu <title>            run a menu bar item (without a title: list them)
//   js <code>               run <code> as an async function body in the page, return its result
//   snapshot <path.png>     save what the overlay's web view shows (needs no Screen Recording permission)
//   window-snapshot <title> <path.png>   the same for one of the app's windows ("Waverly Setup", "General"…)
//   show | hide             show / hide the overlay directly (bypassing the engine)
//   quit                    quit Waverly
// The socket is created with mode 0600 in a directory of the caller's choosing.

import AppKit
import WebKit

final class DebugControl {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let handler: (String, @escaping (Any) -> Void) -> Void

    init?(handler: @escaping (String, @escaping (Any) -> Void) -> Void) {
        guard let p = UserDefaults.standard.string(forKey: "HUDDebugSocket"), !p.isEmpty else { return nil }
        path = (p as NSString).expandingTildeInPath
        self.handler = handler
        guard listen() else { return nil }
        AppLog.info("debug control listening on \(path)")
    }

    private func listen() -> Bool {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return false }
        chmod(path, 0o600)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
        return true
    }

    private func accept() {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return }
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async {
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while !data.contains(10) {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self.handler(line) { result in
                    let obj: Any = JSONSerialization.isValidJSONObject(result) ? result : ["result": "\(result)"]
                    var out = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
                    out.append(10)
                    DispatchQueue.global().async {
                        out.withUnsafeBytes { _ = write(c, $0.baseAddress, out.count) }
                        close(c)
                    }
                }
            }
        }
    }

    deinit { unlink(path) }

    /// Save the web view's current rendering as a PNG.
    static func snapshot(_ webView: WKWebView, to path: String, _ done: @escaping (Any) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else {
                done(["ok": false, "error": error?.localizedDescription ?? "no image"])
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                done(["ok": true, "path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
            } catch {
                done(["ok": false, "error": error.localizedDescription])
            }
        }
    }

    /// Save a window's content (drawn by the app itself, so no Screen Recording permission is needed).
    static func snapshot(window: NSWindow, to path: String, _ done: @escaping (Any) -> Void) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            done(["ok": false, "error": "no view"])
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            done(["ok": false, "error": "no image"])
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            done(["ok": true, "path": path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
        } catch {
            done(["ok": false, "error": error.localizedDescription])
        }
    }
}
