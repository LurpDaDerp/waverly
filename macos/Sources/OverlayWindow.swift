// OverlayWindow.swift — the full-screen HUD overlay: a borderless, transparent
// panel above everything (all windows, full-screen apps, every Space, the menu
// bar and the Dock) hosting a WKWebView that shows the shared HUD page from
// hud-core in macOS mode (?mac=1). The page is loaded at launch and stays
// loaded while the panel is hidden, so a wake is instant.
//
// The panel is non-activating: it takes keyboard focus (Esc, the page) and the
// trackpad without activating the app, so the app the user was in keeps its
// place and gets keyboard focus back the moment the HUD hides.

import AppKit
import WebKit

/// The HUD's web view. Waverly is never the active app while the HUD shows (the panel is
/// non-activating), so without this the first click on the page (a task's check ring)
/// would only make the panel key and never reach the page.
final class OverlayWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Never let AppKit push the panel below the menu bar: it covers the whole screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Calls back after a number of display refreshes of a window's screen (CADisplayLink),
/// or after `orAtMost` seconds if the display link stalls (no refresh comes while the
/// display sleeps), whichever is first; once.
final class RefreshWaiter: NSObject {
    private var left: Int
    private var then: (() -> Void)?
    private var link: CADisplayLink?

    static func wait(frames: Int, on window: NSWindow, orAtMost limit: TimeInterval, then: @escaping () -> Void) {
        let w = RefreshWaiter(frames: frames, then: then)
        let link = window.displayLink(target: w, selector: #selector(tick))
        w.link = link
        link.add(to: .main, forMode: .common)               // the run loop keeps the link, the link its target
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { w.finish() }
    }

    private init(frames: Int, then: @escaping () -> Void) {
        left = max(1, frames)
        self.then = then
    }

    @objc private func tick(_ link: CADisplayLink) {
        left -= 1
        if left <= 0 { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let t = then
        then = nil
        t?()
    }
}

final class OverlayController: NSObject, WKNavigationDelegate {
    let panel: OverlayPanel
    let webView: WKWebView
    let pageURL: URL
    private let port: Int
    private(set) var pageLoaded = false
    private(set) var shownAt: Date?
    private var retryScheduled = false
    var onPageLoaded: (() -> Void)?

    init(port: Int, query: String) {
        self.port = port
        pageURL = URL(string: "http://127.0.0.1:\(port)/?\(query)")!
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = true
        cfg.websiteDataStore = .nonPersistent()              // nothing to keep; the page talks to hud-core
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        webView = OverlayWebView(frame: .zero, configuration: cfg)
        webView.setValue(false, forKey: "drawsBackground")   // transparent page background
        webView.underPageBackgroundColor = .clear
        if #available(macOS 13.3, *) { webView.isInspectable = true }   // Safari > Develop, for debugging
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()
        panel.level = .screenSaver                          // above full-screen apps, the menu bar and the Dock
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        // Not quite clear: macOS sends clicks and scrolls on fully transparent window pixels to
        // the window below, and the page is drawn by another process, so with .clear nothing on
        // the HUD (task rings, trackpad scrolling) would ever get the mouse. 2/255 black is
        // invisible; the panel is only on screen while the HUD shows.
        panel.backgroundColor = NSColor(calibratedWhite: 0, alpha: 2.0 / 255.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none                     // the page does the fade
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.title = "Waverly"
        panel.contentView = webView
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        load()
    }

    var isVisible: Bool { panel.isVisible }

    /// Show on the screen that holds the pointer, make it key, then call `ready`
    /// once the window is on screen (two display refreshes later: one to composite
    /// it, one for the page to draw its first frame; at most 50 ms).
    func show(ready: @escaping () -> Void) {
        let mouse = NSEvent.mouseLocation
        // NSMouseInRect (not flipped) matches NSEvent.mouseLocation's edge convention
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        if let f = screen?.frame, panel.frame != f { panel.setFrame(f, display: true) }
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(webView)
        if !wasVisible { shownAt = Date() }
        CATransaction.flush()
        RefreshWaiter.wait(frames: 2, on: panel, orAtMost: 0.05, then: ready)
    }

    func hide(done: @escaping () -> Void) {
        panel.orderOut(nil)
        shownAt = nil
        done()
    }

    func reload() {
        AppLog.info("overlay: reloading the page")
        load()
    }

    private func load() {
        pageLoaded = false
        webView.load(URLRequest(url: pageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
    }

    @objc private func screensChanged() {
        guard panel.isVisible else { return }
        // keep covering the screen the panel is on if displays were added, removed or resized
        let screen = panel.screen ?? NSScreen.main
        if let f = screen?.frame, panel.frame != f { panel.setFrame(f, display: true) }
    }

    // MARK: WKNavigationDelegate — keep the view on the HUD page, recover from failures

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let u = action.request.url
        let ok = u?.absoluteString == "about:blank" || (u?.host == "127.0.0.1" && (u?.port ?? 80) == port)
        decisionHandler(ok ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        AppLog.info("overlay: page loaded" + (webContentPID.map { " (web content pid \($0))" } ?? ""))
        onPageLoaded?()
    }

    /// The page's WebContent process, for scripts/power_bench.sh (WebKit has no public API for it).
    var webContentPID: Int32? {
        let key = "_webProcessIdentifier"
        guard webView.responds(to: NSSelectorFromString(key)) else { return nil }
        return (webView.value(forKey: key) as? NSNumber)?.int32Value
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.warning("overlay: web content process ended; reloading")
        load()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { retryLoad(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryLoad(error)
    }

    /// hud-core may still be starting (or restarting): try again shortly.
    private func retryLoad(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }   // superseded by a newer load
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            if !self.pageLoaded { self.load() }
        }
    }
}
