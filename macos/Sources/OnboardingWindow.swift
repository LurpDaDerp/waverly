// OnboardingWindow.swift — the setup wizard on first launch: welcome,
// name, permissions, preferences, Google Calendar, then "finishing setup" while
// the Python environment installs in the background. Closing it before the end
// quits Waverly; the next launch starts the wizard again. With `environmentOnly`
// (set up before, environment missing) it shows just the last page.

import AppKit
import SwiftUI

@MainActor final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let model: OnboardingModel

    init(environmentOnly: Bool, onFinish: @escaping () -> Void) {
        model = OnboardingModel(environmentOnly: environmentOnly)
        let w = HudWindow.make(size: OnboardingView.size, title: "Waverly Setup", miniaturizable: false)
        w.isMovableByWindowBackground = true
        super.init(window: w)
        let host = NSHostingController(rootView: OnboardingView(model: model))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(OnboardingView.size)
        w.delegate = self
        w.center()
        model.onDone = { [weak self] in
            self?.window?.close()
            onFinish()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        HudWindow.installMainMenu()
        if model.environmentOnly { EnvironmentInstaller.shared.start() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Nothing works until setup is done, so closing the wizard quits Waverly
    /// (after asking, while the download runs).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.finished else { return true }
        switch EnvironmentInstaller.shared.phase {
        case .installing, .checking:
            let a = NSAlert()
            a.messageText = "Quit Waverly?"
            a.informativeText = "Setup is still downloading. It starts again the next time you open Waverly."
            a.addButton(withTitle: "Continue Setup")
            a.addButton(withTitle: "Quit")
            a.beginSheetModal(for: sender) { response in
                guard response == .alertSecondButtonReturn else { return }
                AppLog.info("setup wizard closed while installing: quitting")
                EnvironmentInstaller.shared.cancel()
                NSApp.terminate(nil)
            }
        default:
            AppLog.info("setup wizard closed before the end: quitting")
            NSApp.terminate(nil)
        }
        return false
    }
}

// MARK: model

@MainActor final class OnboardingModel: ObservableObject {
    enum Page: Int, CaseIterable { case welcome, name, permissions, preferences, google, finish }

    let environmentOnly: Bool
    @Published private(set) var page: Page
    @Published private(set) var forward = true                // direction of the page transition
    @Published var name: String
    @Published var launchAtLogin = true
    private(set) var finished = false
    var onDone: (() -> Void)?

    init(environmentOnly: Bool) {
        self.environmentOnly = environmentOnly
        page = environmentOnly ? .finish : .welcome
        let saved = ConfigStore.shared.name
        name = saved.isEmpty ? String(NSFullUserName().split(separator: " ").first ?? "") : saved
    }

    var isFirst: Bool { page == .welcome || environmentOnly }

    func next() {
        guard let to = Page(rawValue: page.rawValue + 1) else { return }
        leave(page)
        go(to, forward: true)
    }

    func back() {
        guard !isFirst, let to = Page(rawValue: page.rawValue - 1) else { return }
        leave(page)
        go(to, forward: false)
    }

    func start() {
        guard !finished else { return }
        finished = true
        let config = ConfigStore.shared
        if !environmentOnly {
            config.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            LoginItemSetting.set(launchAtLogin)
        }
        config.onboarded = true
        config.flush()
        AppLog.info("setup wizard finished")
        onDone?()
    }

    private func leave(_ p: Page) {
        switch p {
        case .welcome: EnvironmentInstaller.shared.start()   // downloads while the user answers the rest
        case .name: ConfigStore.shared.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        default: break
        }
    }

    private func go(_ to: Page, forward: Bool) {
        // the direction must be in place before the pages swap, so both use it
        self.forward = forward
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.92)) { self.page = to }
        }
    }
}

// MARK: views

struct OnboardingView: View {
    static let size = NSSize(width: 680, height: 520)
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var installer = EnvironmentInstaller.shared
    @ObservedObject private var google = GoogleAuth.shared
    @State private var searching = false

    /// Return = the footer's main button, except while a city search offers results.
    private var returnKey: KeyboardShortcut? { searching ? nil : .defaultAction }

    var body: some View {
        ZStack {
            SunsetBackground(glow: model.page == .welcome ? 1.35 : 0.8)
                .animation(.easeInOut(duration: 0.6), value: model.page)
            VStack(spacing: 0) {
                ZStack {
                    pageView(model.page)
                        .id(model.page)
                        .transition(.asymmetric(
                            insertion: .offset(x: model.forward ? 48 : -48).combined(with: .opacity),
                            removal: .offset(x: model.forward ? -48 : 48).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
        .tint(HudColor.sun)
        .onPreferenceChange(SearchListShownKey.self) { searching = $0 }
    }

    @ViewBuilder private func pageView(_ page: OnboardingModel.Page) -> some View {
        switch page {
        case .welcome: WelcomePage(model: model)
        case .name: NamePage(model: model)
        case .permissions: PermissionsPage()
        case .preferences: PreferencesPage(model: model)
        case .google: GooglePage()
        case .finish: FinishPage(environmentOnly: model.environmentOnly)
        }
    }

    private var footer: some View {
        ZStack {
            if !model.environmentOnly {
                PageDots(count: OnboardingModel.Page.allCases.count, index: model.page.rawValue)
            }
            HStack {
                if !model.isFirst {
                    Button(action: model.back) {
                        Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
                    }
                    .hudButton(.quiet)
                    .transition(.opacity)
                }
                Spacer()
                primaryButton
            }
            .padding(.horizontal, 28)
        }
        .frame(height: 76)
        .animation(.easeOut(duration: 0.2), value: model.page)
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.page {
        case .welcome:
            EmptyView()
        case .google:
            if case .connected = google.state {
                Button("Continue", action: model.next).hudButton(.primary).keyboardShortcut(returnKey)
            } else {
                Button("Skip for Now", action: model.next).hudButton(.secondary).keyboardShortcut(returnKey)
            }
        case .finish:
            Button("Start Waverly", action: model.start)
                .hudButton(.primary)
                .keyboardShortcut(returnKey)
                .disabled(installer.phase != .ready)
        default:
            Button("Continue", action: model.next).hudButton(.primary).keyboardShortcut(returnKey)
        }
    }
}

/// Title and one line under it, centred at the top of a page.
private struct PageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(HudFont.display(28, weight: 640))
                .foregroundStyle(HudColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundStyle(HudColor.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .padding(.bottom, 26)
    }
}

// 1. Welcome

private struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: HudColor.sun.opacity(0.4), radius: 30, y: 8)
                .accessibilityHidden(true)
            Text("Waverly")
                .font(HudFont.display(46, weight: 700))
                .foregroundStyle(HudColor.ink)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text("Your day at a glance, a wave of the hand away.")
                .font(.system(size: 15))
                .foregroundStyle(HudColor.ink2)
                .padding(.top, 6)
            Spacer(minLength: 24)
            Button("Get Started", action: model.next)
                .hudButton(.primary, large: true)
                .keyboardShortcut(.defaultAction)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

// 2. Name

private struct NamePage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "What should Waverly call you?",
                       subtitle: "Your name appears in the greeting. You can leave it empty.")
            GlassField(placeholder: "Your name", text: $model.name, large: true, accessibilityLabel: "Your name",
                       autoFocus: true)
                .frame(width: 340)
            Text(greeting)
                .font(HudFont.display(22, weight: 560))
                .foregroundStyle(HudColor.ink.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 520)
                .padding(.top, 34)
                .animation(.easeOut(duration: 0.15), value: greeting)
                .accessibilityLabel("Preview: \(greeting)")
            Spacer()
        }
    }

    /// The page's own greeting for this hour, as a live preview.
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hello = h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
        return name.isEmpty ? hello : "\(hello), \(name)"
    }
}

// 3. Permissions

private struct PermissionsPage: View {
    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "A few permissions", subtitle: "Each one is optional. Allow what you'd like Waverly to use.")
            PermissionsPanel().frame(width: 520)
            Text("You can change these any time in Waverly Settings.")
                .font(.system(size: 12))
                .foregroundStyle(HudColor.ink3)
                .padding(.top, 14)
            Spacer()
        }
    }
}

// 4. Preferences

private struct PreferencesPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var permissions = Permissions.shared

    // either source may be first to hear about a change (prompt answered, System Settings)
    private var allowed: Bool { permissions.location == .granted || location.authorization == .granted }
    private var automatic: Bool { config.locationAuto && allowed }
    /// The city results cover the rows below; their native controls would take the clicks.
    @State private var resultsShown = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Preferences", subtitle: "Set how Waverly shows the weather and time.")
            GlassPanel {
                PanelRow(title: "Location", detail: locationDetail) { locationControl }
                    .zIndex(1)
                PanelDivider()
                Group {
                    UnitRows(width: 170)
                    PanelDivider()
                    PanelRow(title: "Launch at login",
                             detail: LoginItemSetting.canRegister ? nil : "Turns on once Waverly is in Applications") {
                        Toggle("Launch at login", isOn: $model.launchAtLogin)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                }
                .environment(\.hudClickThrough, resultsShown)
            }
            .frame(width: 520)
            Spacer()
        }
        .onPreferenceChange(SearchListShownKey.self) { resultsShown = $0 }
        .onAppear {
            if automatic && config.place.isEmpty { location.refresh() }
        }
        .onChange(of: location.authorization) { _, a in
            if a == .granted && config.locationAuto { location.refresh() }
        }
    }

    private var locationDetail: String {
        if automatic {
            if location.isLocating { return "Finding your location…" }
            return config.place.isEmpty ? "Couldn't find your location" : config.place
        }
        return config.place.isEmpty ? "Used for the local weather" : config.place
    }

    @ViewBuilder private var locationControl: some View {
        if automatic {
            HStack(spacing: 8) {
                if location.isLocating { ProgressView().controlSize(.small).accessibilityLabel("Locating") }
                Button("Change…") { config.locationAuto = false }
                    .hudButton()
                    .accessibilityLabel("Choose a city instead")
            }
        } else {
            HStack(spacing: 8) {
                if allowed {
                    Button {
                        config.locationAuto = true
                        location.refresh()
                    } label: {
                        Image(systemName: "location.fill").font(.system(size: 12))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(HudColor.ink2)
                    .help("Use my current location")
                    .accessibilityLabel("Use my current location")
                }
                CitySearchField(width: 220) { config.choosePlace($0) }
            }
        }
    }
}

// 5. Google Calendar

private struct GooglePage: View {
    @ObservedObject private var google = GoogleAuth.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Google Calendar",
                       subtitle: "See today's events and what's coming up from Google Calendar and Tasks. Waverly only changes a task when you check it off.")
            GlassPanel { GoogleConnectBox() }
                .frame(width: 440)
            Spacer()
        }
    }
}

/// Connect / connecting / connected / failed, and the "no client" case.
struct GoogleConnectBox: View {
    @ObservedObject private var google = GoogleAuth.shared

    private var hasClient: Bool { google.hasBuiltInClient || google.customClientID != nil }

    var body: some View {
        VStack(spacing: 12) {
            switch google.state {
            case .connected(let account):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 34)).foregroundStyle(HudColor.good)
                    .accessibilityHidden(true)
                Text("Connected").font(HudFont.display(17, weight: 600)).foregroundStyle(HudColor.ink)
                Text(account.map { "Signed in as \($0)" } ?? "Signed in to Google")
                    .font(.system(size: 13)).foregroundStyle(HudColor.ink2)
                    .textSelection(.enabled)
            case .connecting:
                ProgressView().controlSize(.regular).frame(height: 34)
                Text("Waiting for Google…").font(HudFont.display(17, weight: 600)).foregroundStyle(HudColor.ink)
                Text("Finish signing in in your browser, then come back here.")
                    .font(.system(size: 13)).foregroundStyle(HudColor.ink2).multilineTextAlignment(.center)
                Button("Cancel") { google.cancel() }.hudButton()
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 30)).foregroundStyle(HudColor.warn)
                    .accessibilityHidden(true)
                Text("Couldn't connect").font(HudFont.display(17, weight: 600)).foregroundStyle(HudColor.ink)
                Text(message).font(.system(size: 12.5)).foregroundStyle(HudColor.ink2)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Try Again") { google.connect() }.hudButton(.primary).padding(.top, 2)
            case .disconnected:
                if hasClient {
                    IconTile(symbol: "calendar", tint: HudColor.sunLight, size: 52)
                    Button("Connect Google Calendar…") { google.connect() }
                        .hudButton(.primary, large: true)
                        .padding(.top, 6)
                    Text("Opens your browser to sign in with Google.")
                        .font(.system(size: 12)).foregroundStyle(HudColor.ink3)
                } else {
                    IconTile(symbol: "key.fill", tint: HudColor.sunLight, size: 52)
                    Text("This copy of Waverly has no Google sign-in of its own. Use an OAuth client file from your Google Cloud project.")
                        .font(.system(size: 13)).foregroundStyle(HudColor.ink2)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Choose Client File…") { GoogleClientFile.choose() }.hudButton(.primary)
                        HelpLinkButton()
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, minHeight: 210)
        .animation(.easeOut(duration: 0.2), value: google.state)
    }
}

struct HelpLinkButton: View {
    var title = "How to Get One"

    var body: some View {
        Button { NSWorkspace.shared.open(googleHelpURL) } label: {
            Label(title, systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
        }
        .hudButton(.quiet)
        .help(googleHelpURL.absoluteString)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.system(size: 10, weight: .semibold))
        }
    }
}

// 6. Finish

private struct FinishPage: View {
    let environmentOnly: Bool
    @ObservedObject private var installer = EnvironmentInstaller.shared
    @ObservedObject private var config = ConfigStore.shared
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 0) {
            switch installer.phase {
            case .ready:
                PageHeader(title: "You're all set",
                           subtitle: "Waverly lives in the menu bar. Open it whenever you like:")
                HStack(spacing: 12) {
                    HintCard(symbol: "hand.raised.fill", title: "Open", text: openHint)
                    HintCard(symbol: "hand.raised.slash.fill", title: "Close", text: closeHint)
                    HintCard(symbol: "keyboard.fill", title: "Keyboard", text: "\(ConfigStore.shared.hotkey.display) to open,\nEsc to close")
                }
                .frame(width: 540)
            case .needsPython:
                PageHeader(title: "Python is needed",
                           subtitle: "Waverly couldn't set up its hand-tracking engine on its own.")
                problemPanel(symbol: "shippingbox.fill", text: "Install Python 3.12 from python.org, then try again.") {
                    Button("Get Python…") { installer.openPythonDownload() }.hudButton()
                    Button("Try Again") { installer.start() }.hudButton(.primary)
                }
            case .failed(let message):
                PageHeader(title: "Setup didn't finish", subtitle: "Something went wrong while installing the hand-tracking engine.")
                VStack(alignment: .leading, spacing: 14) {
                    problemPanel(symbol: "exclamationmark.triangle.fill", text: message) {
                        Button("Try Again") { installer.start() }.hudButton(.primary)
                    }
                    logPanel
                }
                .frame(width: 480)
            case .idle, .checking, .installing:
                PageHeader(title: environmentOnly ? "Finishing setup" : "Almost there",
                           subtitle: "Waverly is downloading its hand-tracking engine (about 250 MB). It takes a few minutes; you can keep using your Mac.")
                progressPanel
            }
            Spacer()
        }
        .animation(.easeOut(duration: 0.25), value: installer.phase)
        .onAppear { if installer.phase == .idle { installer.start() } }
    }

    /// The open and close hints follow Settings › Controls › Hand Gestures.
    private var openHint: String {
        switch (config.gestureOpenWave, config.gestureOpenFist) {
        case (true, true): "Wave, or make a fist and open your hand"
        case (true, false): "Wave, palm toward the camera"
        case (false, true): "Make a fist, then open your hand"
        case (false, false): "Use the keyboard shortcut"
        }
    }

    private var closeHint: String {
        var ways: [String] = []
        if config.gestureCloseFist { ways.append("make a fist") }
        if config.autoCloseAway { ways.append("walk away") } else if config.autoCloseDark { ways.append("turn off the light") }
        guard !ways.isEmpty else { return "Press Esc" }
        let text = ways.joined(separator: ", or ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func problemPanel<Buttons: View>(symbol: String, text: String,
                                             @ViewBuilder buttons: () -> Buttons) -> some View {
        GlassPanel(padding: 18) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, tint: HudColor.warn, size: 34)
                VStack(alignment: .leading, spacing: 14) {
                    Text(text)
                        .font(.system(size: 12.5)).foregroundStyle(HudColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Spacer()
                        buttons()
                    }
                }
            }
        }
        .frame(width: 480)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassPanel(padding: 18) {
                HStack(spacing: 12) {
                    IconTile(symbol: "arrow.down", tint: HudColor.sunLight, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(installer.phase == .installing ? "Installing the engine" : "Getting ready")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                        Text(statusLine)
                            .font(.system(size: 11.5)).foregroundStyle(HudColor.ink2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if let p = installer.progress {
                        Text("\(Int((min(max(p, 0), 1) * 100).rounded()))%")
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(HudColor.ink2)
                            .accessibilityHidden(true)
                    }
                }
                HudProgressBar(value: installer.progress).padding(.top, 14)
            }
            logPanel
        }
        .frame(width: 480)
    }

    @ViewBuilder private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { showLog.toggle() }
            } label: {
                Label(showLog ? "Hide Details" : "Show Details", systemImage: "chevron.right")
                    .labelStyle(DisclosureLabelStyle(open: showLog))
            }
            .hudButton(.quiet)
            .padding(.leading, -8)
            if showLog {
                LogView(text: installer.log).frame(height: 150)
                    .transition(.opacity)
            }
        }
        .frame(width: 480, alignment: .leading)
    }

    /// The newest line of the installer's output.
    private var statusLine: String {
        let last = installer.log.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "Preparing…"
    }
}

private struct HintCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            IconTile(symbol: symbol, tint: HudColor.sunLight, size: 44)
            Text(title).font(HudFont.display(15, weight: 600)).foregroundStyle(HudColor.ink)
            Text(text).font(.system(size: 12.5)).foregroundStyle(HudColor.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HudColor.glass))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HudColor.rim, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct DisclosureLabelStyle: LabelStyle {
    let open: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
            configuration.title
        }
    }
}

/// The installer's output, newest at the bottom (only the last part: the full
/// log can be large).
struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(String(text.suffix(16_000)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(HudColor.ink2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(HudColor.rim, lineWidth: 1))
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .accessibilityLabel("Setup log")
    }
}
