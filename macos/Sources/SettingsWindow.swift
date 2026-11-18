// SettingsWindow.swift — Waverly Settings (menu "Settings…", ⌘,), one toolbar tab
// per category: General, Appearance, Controls, Lists, Labels, Google and
// Permissions (⌘1…⌘7). Every change is saved as it happens through ConfigStore;
// there is no Save button. Calendars and task lists come from hud-core (SourcesClient).

import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, appearance, controls, lists, labels, google, permissions

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .controls: "Controls"
        case .lists: "Lists"
        case .labels: "Labels"
        case .google: "Google"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .controls: "keyboard"
        case .lists: "list.bullet.rectangle"
        case .labels: "tag"
        case .google: "calendar"
        case .permissions: "hand.raised"
        }
    }
}

@MainActor final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "HUDSettingsTab") }
    }

    init() {
        tab = UserDefaults.standard.string(forKey: "HUDSettingsTab").flatMap(SettingsTab.init) ?? .general
    }
}

@MainActor final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let size = NSSize(width: 720, height: 560)
    private let model = SettingsModel()
    private var tabWatch: Any?

    private init() {
        let w = HudWindow.make(size: Self.size, title: "Settings", miniaturizable: true)
        w.titleVisibility = .visible
        super.init(window: w)
        let host = NSHostingController(rootView: SettingsView(model: model))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(Self.size)
        w.delegate = self
        w.setFrameAutosaveName("WaverlySettings")
        if !w.setFrameUsingName("WaverlySettings") { w.center() }
        w.title = model.tab.title
        tabWatch = model.$tab.sink { [weak w] in w?.title = $0.title }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(tab: SettingsTab?) {
        if let tab { model.tab = tab }
        HudWindow.installMainMenu()
        SourcesClient.shared.reload()
        Permissions.shared.refresh()
        let wasVisible = window?.isVisible ?? false
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // AppKit would focus (and select) the first text field: a stray key would replace the name
        if !wasVisible { DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) } }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        Permissions.shared.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)            // ends editing, so the last keystrokes are saved
    }
}

// MARK: shell

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var google = GoogleAuth.shared

    var body: some View {
        ZStack {
            SunsetBackground(glow: 0.2)
            VStack(spacing: 0) {
                tabBar
                    .padding(.top, 30)
                    .padding(.bottom, 10)
                Rectangle().fill(HudColor.line).frame(height: 1)
                ZStack {
                    content(model.tab)
                        .id(model.tab)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
        .environment(\.colorScheme, .dark)
        .tint(HudColor.sun)
        .onChange(of: google.state) { _, _ in SourcesClient.reloadSoon() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(SettingsTab.allCases.enumerated()), id: \.element) { i, t in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.tab = t }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol).font(.system(size: 17, weight: .regular)).frame(height: 21)
                        Text(t.title).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(model.tab == t ? HudColor.sunLight : HudColor.ink2)
                    .frame(width: 76, height: 50)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(model.tab == t ? Color.white.opacity(0.11) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(model.tab == t ? [.isSelected] : [])
                .help("\(t.title) (⌘\(i + 1))")
            }
        }
    }

    @ViewBuilder private func content(_ tab: SettingsTab) -> some View {
        ScrollView {
            Group {
                switch tab {
                case .general: GeneralTab()
                case .appearance: AppearanceTab()
                case .controls: ControlsTab()
                case .lists: ListsTab()
                case .labels: LabelsTab()
                case .google: GoogleTab()
                case .permissions: PermissionsTab()
                }
            }
            .frame(width: 560)
            .padding(.top, 22)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

extension SourcesClient {
    /// hud-core notices new Google credentials within a couple of seconds: ask now and again shortly.
    static func reloadSoon() {
        shared.reload()
        for delay in [2.5, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { shared.reload() }
        }
    }
}

// MARK: General

private struct GeneralTab: View {
    @ObservedObject private var config = ConfigStore.shared
    @State private var loginOn = LoginItem.isEnabled
    @State private var resultsShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GlassPanel {
                PanelRow(title: "Name", detail: "Shown in the greeting") {
                    GlassField(placeholder: "Your name", text: $config.name, accessibilityLabel: "Name", onCommit: {
                        let trimmed = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed != config.name { config.name = trimmed }
                    })
                    .frame(width: 230)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Location", detail: "Used for the local weather.")
                LocationEditor()
            }
            .zIndex(1)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Startup")
                GlassPanel {
                    PanelRow(title: "Launch at login",
                             detail: LoginItemSetting.canRegister ? nil : "Available once Waverly is in Applications") {
                        Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: { on in
                            LoginItemSetting.set(on)
                            loginOn = on
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loginOn = LoginItem.isEnabled }
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(!LoginItemSetting.canRegister)
                    }
                }
            }
            .environment(\.hudClickThrough, resultsShown)     // under the city results
        }
        .onPreferenceChange(SearchListShownKey.self) { resultsShown = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginOn = LoginItem.isEnabled
        }
    }
}

// MARK: Appearance

private struct AppearanceTab: View {
    @ObservedObject private var config = ConfigStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GlassPanel {
                PanelRow(title: "Theme", detail: themeDetail) {
                    SegmentedChoice(label: "Theme", options: [(Theme.adaptive, "Adaptive"), (.light, "Light"), (.dark, "Dark")],
                                    selection: $config.theme)
                        .frame(width: 240)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Units and Clock")
                GlassPanel { UnitRows(width: 240) }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Motion")
                GlassPanel {
                    PanelRow(title: "Parallax", detail: "Cards lean and shift as you move your head") {
                        Toggle("Parallax", isOn: $config.parallax)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    PanelDivider()
                    PanelRow(title: "Weather animation", detail: "Rain, snow and clouds move. Off shows a still sky.") {
                        Toggle("Weather animation", isOn: $config.weatherAnimation)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    PanelDivider()
                    PanelRow(title: "Open animation", detail: "How Waverly appears") {
                        AnimationTypePicker(title: "Open animation", selection: $config.openAnimationType)
                    }
                    PanelDivider()
                    PanelRow(title: "Open length", detail: "How long it takes to appear") {
                        AnimationLengthSlider(title: "Open length", length: .open, value: $config.openAnimation)
                    }
                    PanelDivider()
                    PanelRow(title: "Close animation", detail: "How it disappears") {
                        AnimationTypePicker(title: "Close animation", selection: $config.closeAnimationType)
                    }
                    PanelDivider()
                    PanelRow(title: "Close length", detail: "How long it takes to disappear") {
                        AnimationLengthSlider(title: "Close length", length: .close, value: $config.closeAnimation)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Weather Detail", detail: "How much of the weather the sky draws, moving or still.")
                GlassPanel {
                    ForEach(Array(Self.details.enumerated()), id: \.element.value) { i, d in
                        if i > 0 { PanelDivider(inset: 46) }
                        ChoiceRow(title: d.title, detail: d.detail, selected: config.weatherDetail == d.value) {
                            config.weatherDetail = d.value
                        }
                    }
                }
            }
        }
    }

    private static let details: [(value: WeatherDetail, title: String, detail: String)] = [
        (.low, "Low", "A simple sky gradient. Easiest on the battery."),
        (.medium, "Medium", "Clouds and lighter rain or snow, without fog or lightning."),
        (.high, "High", "Every weather effect, fog and lightning included."),
    ]

    private var themeDetail: String {
        switch config.theme {
        case .adaptive: "Light by day, dark at night"
        case .light: "Light cards all day and night"
        case .dark: "Dark cards all day and night"
        }
    }
}

/// Hand-scrolling speed: Slower (0.5x) to Faster (2x) in 0.25 steps. Applies while dragging.
private struct ScrollSpeedSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(spacing: 3) {
                Slider(value: Binding(get: { value },
                                      set: { v in
                                          let snapped = ScrollSpeed.validated((v / ScrollSpeed.step).rounded() * ScrollSpeed.step)
                                          if snapped != value { value = snapped }
                                      }),
                       in: ScrollSpeed.range, step: ScrollSpeed.step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(Self.label(value))
                HStack {
                    Text("Slower")
                    Spacer(minLength: 4)
                    Text("Faster")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(HudColor.ink3)
                .accessibilityHidden(true)
            }
            .frame(width: 176)
            Text(Self.label(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(HudColor.ink)
                .frame(width: 54, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    /// "1×", "1.25×", "0.5×".
    private static func label(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "×"
    }
}

/// Fade, Zoom, Shatter, Slide or Swirl, as a menu.
private struct AnimationTypePicker: View {
    let title: String
    @Binding var selection: AnimationType

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(AnimationType.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu).labelsHidden().fixedSize()
    }
}

/// An open or close animation length: "Instant" at the far left, then the range in
/// 0.1 s steps (AnimationLength). Applies while dragging, like every setting.
private struct AnimationLengthSlider: View {
    let title: String
    let length: AnimationLength
    @Binding var value: Double

    /// The slider runs one step below the range: that leftmost stop is "Instant" (stored as 0).
    private var instantStop: Double { length.range.lowerBound - AnimationLength.step }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(spacing: 3) {
                Slider(value: Binding(get: { value == 0 ? instantStop : value },
                                      set: { v in
                                          let snapped = v < length.range.lowerBound - AnimationLength.step / 2
                                              ? 0 : length.validated((v * 10).rounded() / 10)
                                          if snapped != value { value = snapped }
                                      }),
                       in: instantStop...length.range.upperBound, step: AnimationLength.step)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(Self.spoken(value))
                HStack {
                    Text("Instant")
                    Spacer(minLength: 4)
                    Text(length.range.upperBound == length.range.upperBound.rounded()
                         ? "\(Int(length.range.upperBound)) s" : Self.seconds(length.range.upperBound))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(HudColor.ink3)
                .accessibilityHidden(true)
            }
            .frame(width: 176)
            Text(value == 0 ? "Instant" : Self.seconds(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(HudColor.ink)
                .frame(width: 54, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    /// "1.0 s", "0.75 s".
    private static func seconds(_ v: Double) -> String {
        let tenths = (v * 10).rounded() / 10
        return String(format: abs(v - tenths) < 0.001 ? "%.1f s" : "%.2f s", v)
    }

    private static func spoken(_ v: Double) -> String {
        v == 0 ? "Instant" : String(format: "%g seconds", (v * 100).rounded() / 100)
    }
}

/// One choice of several in a panel: a radio dot, a title and one line about it.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? HudColor.sun : Color.white.opacity(0.32), lineWidth: 1.5)
                    if selected { Circle().fill(HudColor.sun).padding(4) }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(HudColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 50)
            .background(Color.white.opacity(hover && !selected ? 0.03 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(detail)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Controls

private struct ControlsTab: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Keyboard Shortcut")
                GlassPanel {
                    ShortcutSetting()
                    if permissions.accessibility != .granted {
                        PanelDivider()
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HudColor.warn)
                                .accessibilityHidden(true)
                            Text("Works in other apps once Accessibility is allowed.")
                                .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                            Spacer(minLength: 8)
                            Button("Allow…") { permissions.request(.accessibility) }
                                .hudButton()
                                .accessibilityLabel("Allow Accessibility")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Hand Gestures", detail: "Pick the gestures that open and close Waverly.")
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        GroupCaption(title: "Open with")
                        GlassPanel {
                            SwitchRow(title: "Wave", detail: "Wave your hand, palm toward the camera",
                                      isOn: $config.gestureOpenWave)
                            PanelDivider()
                            SwitchRow(title: "Fist, then open hand", detail: "Make a fist, then open your hand toward the camera",
                                      isOn: $config.gestureOpenFist)
                            if !config.gestureOpens {
                                PanelDivider()
                                CalmNote(text: "Waverly now opens only with \(config.hotkey.display) or from the menu bar.")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        GroupCaption(title: "Close with")
                        GlassPanel {
                            SwitchRow(title: "Make a fist", detail: "Hold up an open hand, then close it into a fist",
                                      isOn: $config.gestureCloseFist)
                            PanelDivider()
                            SwitchRow(title: "When you walk away", detail: "After \(awayTime) with nobody in view",
                                      isOn: $config.autoCloseAway)
                            PanelDivider()
                            SwitchRow(title: "When the room goes dark", detail: "After \(awayTime) of darkness",
                                      isOn: $config.autoCloseDark)
                            if !config.gestureCloses {
                                PanelDivider()
                                CalmNote(text: "Waverly now closes only with Esc or \(config.hotkey.display).")
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        GroupCaption(title: "Scrolling")
                        GlassPanel {
                            PanelRow(title: "Reverse vertical scrolling") {
                                Toggle("Reverse vertical hand scrolling", isOn: $config.scrollReverseVertical)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            PanelDivider()
                            PanelRow(title: "Reverse horizontal scrolling") {
                                Toggle("Reverse horizontal hand scrolling", isOn: $config.scrollReverseHorizontal)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            }
                            PanelDivider()
                            PanelRow(title: "Vertical scroll speed") {
                                ScrollSpeedSlider(title: "Vertical hand scroll speed", value: $config.scrollSpeedVertical)
                            }
                            PanelDivider()
                            PanelRow(title: "Horizontal scroll speed") {
                                ScrollSpeedSlider(title: "Horizontal hand scroll speed", value: $config.scrollSpeedHorizontal)
                            }
                        }
                        Text("Only hand scrolling changes. Trackpad and mouse scrolling follow macOS.")
                            .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                            .padding(.horizontal, 4).padding(.top, 8)
                    }
                }
                .padding(.top, 6)
            }
        }
        .animation(.easeOut(duration: 0.2), value: permissions.accessibility)
        .animation(.easeOut(duration: 0.2), value: config.gestureOpens)
        .animation(.easeOut(duration: 0.2), value: config.gestureCloses)
    }

    /// "5 seconds" (config away_seconds; whole seconds unless it is set to a fraction).
    private var awayTime: String {
        let s = config.awaySeconds
        let n = s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
        return "\(n) second\(s == 1 ? "" : "s")"
    }
}

/// A small label over one group of rows inside a section.
private struct GroupCaption: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(HudColor.ink2)
            .padding(.leading, 4).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A panel row with a title, a short subtitle and an on / off switch.
private struct SwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        PanelRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

// MARK: Permissions

private struct PermissionsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Permissions", detail: "Each one is optional. Allow what you'd like Waverly to use.")
            PermissionsPanel()
        }
    }
}

// MARK: Lists

private struct ListsTab: View {
    enum Side: String, CaseIterable { case left, right }

    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var sources = SourcesClient.shared
    @AppStorage("HUDSettingsListSide") private var side: Side = .left

    private var isRight: Bool { side == .right }
    private var list: Binding<ListConfig> {
        Binding(get: { isRight ? config.right : config.left },
                set: { if isRight { config.right = $0 } else { config.left = $0 } })
    }
    private var defaultTitle: String { isRight ? ListConfig.rightDefault.title : ListConfig.leftDefault.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 8) {
                SegmentedChoice(label: "List", options: [(Side.left, "Left list"), (Side.right, "Right list")],
                                selection: $side.animation(.easeOut(duration: 0.18)))
                    .frame(width: 240)
                Text(isRight ? "What's coming up: tasks and events in the days ahead."
                             : "Today: today's events, and tasks due today or overdue.")
                    .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
            }
            .frame(maxWidth: .infinity)

            GlassPanel {
                PanelRow(title: "Title", detail: "The heading of the card") {
                    GlassField(placeholder: defaultTitle, text: list.title, accessibilityLabel: "Title").frame(width: 230)
                }
            }

            SourcesSection(isRight: isRight, list: list)

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Filters",
                              detail: "Only matching items show. Start a word with - to hide it, e.g. deadline, -lunch")
                GlassPanel {
                    PanelRow(title: "Event keywords") {
                        GlassField(placeholder: "All events", text: list.eventKeywords, accessibilityLabel: "Event keywords")
                            .frame(width: 260)
                    }
                    PanelDivider()
                    PanelRow(title: "Task keywords") {
                        GlassField(placeholder: "All tasks", text: list.taskKeywords, accessibilityLabel: "Task keywords")
                            .frame(width: 260)
                    }
                }
            }

            if isRight {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Upcoming")
                    GlassPanel {
                        PanelRow(title: "Look ahead", detail: "How far ahead dated items are shown") {
                            Picker("Look ahead", selection: list.lookaheadDays) {
                                ForEach(lookaheadChoices, id: \.days) { Text($0.label).tag($0.days) }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        }
                        PanelDivider()
                        PanelRow(title: "Countdowns", detail: "Show the time left next to each item") {
                            Toggle("Countdowns", isOn: list.countdowns)
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// The fixed choices, plus a hand-edited value so the picker never shows blank.
    private var lookaheadChoices: [(days: Int, label: String)] {
        let all = ListConfig.lookaheadChoices
        let n = list.wrappedValue.lookaheadDays
        return all.contains { $0.days == n } ? all : (all + [(n, "\(n) days")]).sorted { $0.days < $1.days }
    }
}

/// The calendars and task lists a list shows, or a calm placeholder.
private struct SourcesSection: View {
    let isRight: Bool
    @Binding var list: ListConfig
    @ObservedObject private var sources = SourcesClient.shared

    var body: some View {
        if sources.state == "ok" && sources.hasSources {
            VStack(alignment: .leading, spacing: 18) {
                if !sources.calendars.isEmpty { group("Calendars", sources.calendars) }
                if !sources.tasklists.isEmpty { group("Task lists", sources.tasklists) }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Sources")
                GlassPanel { SourcesPlaceholder() }
            }
        }
    }

    private func group(_ title: String, _ items: [SourceItem]) -> some View {
        let chosen = Set(sources.resolved(list, right: isRight))
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            GlassPanel {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { PanelDivider(inset: 44) }
                    Toggle(isOn: Binding(get: { chosen.contains(item.id) }, set: { set(item.id, $0) })) {
                        HStack(spacing: 9) {
                            ColorDot(id: sources.color(of: item.id), size: 10)
                            Text(item.name).font(.system(size: 13)).foregroundStyle(HudColor.ink).lineLimit(1)
                            if !item.googleSelected {
                                Text("Hidden in Google Calendar").font(.system(size: 11.5)).foregroundStyle(HudColor.ink3)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 6)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .accessibilityLabel(item.name)
                }
            }
        }
    }

    /// Ticking writes an explicit list (in Google's order), starting from what is shown.
    private func set(_ key: String, _ on: Bool) {
        var keys = sources.resolved(list, right: isRight)
        keys.removeAll { $0 == key }
        if on { keys.append(key) }
        let order = (sources.calendars + sources.tasklists).map(\.id)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        list.sources = keys.sorted { (rank[$0] ?? Int.max) < (rank[$1] ?? Int.max) }
    }
}

/// What to show instead of calendars while Google isn't connected, hud-core
/// isn't reachable or the lists are still loading.
struct SourcesPlaceholder: View {
    @ObservedObject private var sources = SourcesClient.shared
    @ObservedObject private var google = GoogleAuth.shared

    private var googleConnected: Bool { if case .connected = google.state { true } else { false } }

    var body: some View {
        Group {
            if google.state == .connecting {
                EmptyStateView(symbol: "calendar", title: "Waiting for Google…",
                               message: "Finish signing in in your browser.", busy: true) { EmptyView() }
            } else {
                switch sources.state {
                case "setup" where googleConnected:
                    // signed in a moment ago: hud-core hasn't read the new sign-in yet
                    EmptyStateView(symbol: "calendar", title: "Loading your calendars…",
                                   message: "This takes a moment the first time.", busy: true) { EmptyView() }
                case "setup":
                    EmptyStateView(symbol: "calendar.badge.plus", title: "Google Calendar isn't connected",
                                   message: "Connect your Google account to choose which calendars and task lists appear.") {
                        ConnectGoogleButton()
                    }
                case "auth":
                    EmptyStateView(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in again",
                                   message: "Google asked Waverly to sign in again before it can read your calendars.") {
                        ConnectGoogleButton(title: "Reconnect…")
                    }
                case "ok":
                    EmptyStateView(symbol: "tray", title: "Nothing to show",
                                   message: "Your Google account has no calendars or task lists.") {
                        Button("Refresh") { sources.reload() }.hudButton()
                    }
                case "error":
                    EmptyStateView(symbol: "exclamationmark.triangle", title: "Couldn't load your calendars",
                                   message: "Google didn't answer. Waverly keeps trying in the background.") {
                        Button("Try Again") { sources.reload() }.hudButton().disabled(sources.isLoading)
                    }
                case "unavailable":
                    EmptyStateView(symbol: "bolt.horizontal.circle", title: "Waverly is starting",
                                   message: "Your calendars appear here once Waverly's background service is running.",
                                   busy: sources.isLoading) {
                        Button("Try Again") { sources.reload() }.hudButton().disabled(sources.isLoading)
                    }
                default:
                    EmptyStateView(symbol: "calendar", title: "Loading your calendars…",
                                   message: "This takes a moment the first time.", busy: true) { EmptyView() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: sources.state)
    }
}

/// Connect Google Calendar, or go to the Google tab when there's no client to sign in with.
private struct ConnectGoogleButton: View {
    var title = "Connect Google Calendar…"
    @ObservedObject private var google = GoogleAuth.shared

    var body: some View {
        Button(title) {
            if google.hasBuiltInClient || google.customClientID != nil {
                google.connect()
            } else {
                SettingsWindowController.shared.show(tab: .google)
            }
        }
        .hudButton(.primary)
    }
}

// MARK: Labels

private struct LabelsTab: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var sources = SourcesClient.shared
    @State private var newCategory: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Every calendar and task list has a colored label. Give several the same category to show one shared label instead of their own.")
                .font(.system(size: 12.5)).foregroundStyle(HudColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Categories")
                    Button(action: addCategory) {
                        Label("Add Category", systemImage: "plus").labelStyle(.titleAndIcon)
                    }
                    .hudButton(.quiet)
                    .padding(.bottom, 8)
                }
                GlassPanel {
                    if config.categories.isEmpty {
                        Text("No categories yet. A category like “Work” or “School” can group several calendars under one label.")
                            .font(.system(size: 12.5)).foregroundStyle(HudColor.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    ForEach($config.categories) { $c in
                        if c.id != config.categories.first?.id { PanelDivider(inset: 56) }
                        CategoryRow(category: $c, autoFocus: c.id == newCategory) { delete(c.id) }
                    }
                }
            }

            if sources.state == "ok" && sources.hasSources {
                if !sources.calendars.isEmpty { styleGroup("Calendars", sources.calendars) }
                if !sources.tasklists.isEmpty { styleGroup("Task lists", sources.tasklists) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Calendars and task lists")
                    GlassPanel { SourcesPlaceholder() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: config.categories.count)
    }

    private func styleGroup(_ title: String, _ items: [SourceItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title)
            GlassPanel {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { PanelDivider() }
                    SourceStyleRow(item: item)
                }
            }
        }
    }

    private func addCategory() {
        let used = config.categories.map(\.color) + (sources.calendars + sources.tasklists).compactMap { sources.color(of: $0.id) }
        let ids = Set(config.categories.map(\.id))
        var n = (config.categories.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) + 1
        while ids.contains("c\(n)") { n += 1 }                  // hand-edited ids
        let id = "c\(n)"
        newCategory = id                                     // its name field takes the focus once
        config.categories.append(LabelCategory(id: id, name: "", color: Palette.leastUsed(used)))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { newCategory = nil }
    }

    private func delete(_ id: String) {
        config.categories.removeAll { $0.id == id }
        for (key, s) in config.sourceStyle where s.category == id {
            config.updateStyle(key) { $0.category = nil }
        }
    }
}

private struct CategoryRow: View {
    @Binding var category: LabelCategory
    let autoFocus: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SwatchPicker(selection: category.color, allowsAutomatic: false, label: "Category color") {
                if let c = $0 { category.color = c }
            }
            GlassField(placeholder: "Category name", text: $category.name, accessibilityLabel: "Category name",
                       autoFocus: autoFocus, onCommit: {
                if category.name.trimmingCharacters(in: .whitespaces).isEmpty { category.name = "Untitled" }
            })
            Button(action: onDelete) {
                Image(systemName: "trash").font(.system(size: 12.5))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(HudColor.ink2)
            .help("Delete category")
            .accessibilityLabel("Delete \(category.name.isEmpty ? "category" : category.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

private struct SourceStyleRow: View {
    let item: SourceItem
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var sources = SourcesClient.shared

    private var style: SourceStyle { config.sourceStyle[item.id] ?? SourceStyle() }
    private var category: LabelCategory? { config.categories.first { $0.id == style.category } }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13)).foregroundStyle(HudColor.ink).lineLimit(1)
                if let category {
                    HStack(spacing: 5) {
                        Text("Shows as").font(.system(size: 11.5)).foregroundStyle(HudColor.ink3)
                        pill(category)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Spacer(minLength: 8)
            SwatchPicker(selection: Palette.isValid(style.color) ? style.color : nil,
                         automatic: sources.autoColors[item.id] ?? item.color, label: "\(item.name) color") { c in
                config.updateStyle(item.id) { $0.color = c }
            }
            .disabled(category != nil)
            .opacity(category != nil ? 0.35 : 1)
            .help(category != nil ? "Uses the color of its category" : "Color")
            PopUpChoice(label: "Category for \(item.name)",
                        options: [.init(value: "", title: "No category")]
                            + config.categories.map { .init(value: $0.id, title: $0.name.isEmpty ? "Untitled" : $0.name, dot: $0.color) },
                        selection: Binding(get: { category?.id ?? "" },
                                           set: { id in config.updateStyle(item.id) { $0.category = id.isEmpty ? nil : id } }))
                .frame(width: 150)
                .disabled(config.categories.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 50)
    }

    /// The category's pill as the page will show it.
    private func pill(_ c: LabelCategory) -> some View {
        let color = Palette.color(c.color)?.color ?? HudColor.ink2
        return Text(c.name.isEmpty ? "Untitled" : c.name)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

extension ConfigStore {
    /// Changes one source's style; an entry with nothing set is removed.
    func updateStyle(_ key: String, _ change: (inout SourceStyle) -> Void) {
        var s = sourceStyle[key] ?? SourceStyle()
        change(&s)
        if s.color == nil && s.category == nil { sourceStyle[key] = nil } else { sourceStyle[key] = s }
    }
}

// MARK: Google

private struct GoogleTab: View {
    @ObservedObject private var google = GoogleAuth.shared
    @ObservedObject private var sources = SourcesClient.shared
    @State private var advanced = GoogleAuth.shared.customClientID != nil      // open while it's in use

    private var hasClient: Bool { google.hasBuiltInClient || google.customClientID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Google account",
                              detail: "Waverly reads your calendars and task lists to show them. It changes a task only to mark it done when you check it off.")
                GlassPanel {
                    HStack(spacing: 14) {
                        IconTile(symbol: statusSymbol, tint: statusTint, size: 38)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(statusTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HudColor.ink)
                            Text(statusDetail).font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 8)
                        actions
                    }
                    .padding(16)
                    .animation(.easeOut(duration: 0.2), value: google.state)
                }
                if let note = tasksNote {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle").font(.system(size: 13)).foregroundStyle(HudColor.ink3)
                        Text(note).font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                        Spacer(minLength: 8)
                        Button("Sign In Again…") { google.connect() }.hudButton(.quiet)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { advanced.toggle() }
                } label: {
                    Label("Advanced", systemImage: "chevron.right").labelStyle(DisclosureLabelStyle(open: advanced))
                        .font(HudFont.display(15, weight: 600))
                }
                .hudButton(.quiet)
                .padding(.leading, -4)
                if advanced {
                    GlassPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Use your own Google Cloud OAuth client")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                            Text(clientDetail)
                                .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            HStack(spacing: 10) {
                                Button("Choose Client File…") { GoogleClientFile.choose() }.hudButton()
                                if google.hasBuiltInClient && google.customClientID != nil {
                                    Button("Use Built-in Client") { google.useBuiltInClient() }.hudButton()
                                }
                                Spacer()
                                HelpLinkButton(title: "Help")
                            }
                        }
                        .padding(16)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch google.state {
        case .connected:
            if sources.state == "auth" {
                Button("Reconnect…") { google.connect() }.hudButton(.primary)
            } else {
                Button("Disconnect…", action: confirmDisconnect).hudButton()
            }
        case .connecting:
            Button("Cancel") { google.cancel() }.hudButton()
        case .disconnected, .failed:
            if hasClient {
                Button(sources.state == "auth" ? "Reconnect…" : "Connect…") { google.connect() }.hudButton(.primary)
            } else {
                Button("Choose Client File…") { GoogleClientFile.choose() }.hudButton(.primary)
            }
        }
    }

    private var statusSymbol: String {
        switch google.state {
        case .connected: sources.state == "auth" ? "exclamationmark.triangle.fill" : "checkmark"
        case .connecting: "hourglass"
        case .failed: "exclamationmark.triangle.fill"
        case .disconnected: "calendar"
        }
    }

    private var statusTint: Color {
        switch google.state {
        case .connected: sources.state == "auth" ? HudColor.warn : HudColor.good
        case .failed: HudColor.warn
        default: HudColor.sunLight
        }
    }

    private var statusTitle: String {
        switch google.state {
        case .connected(let account):
            if sources.state == "auth" { return "Sign-in expired" }
            return (account ?? sources.account).map { "Connected as \($0)" } ?? "Connected"
        case .connecting: return "Waiting for Google…"
        case .failed: return "Couldn't connect"
        case .disconnected: return "Not connected"
        }
    }

    private var statusDetail: String {
        switch google.state {
        case .connected:
            return sources.state == "auth" ? "Google asked Waverly to sign in again before it can read your calendars."
                                           : "Your events and tasks appear on Waverly."
        case .connecting: return "Finish signing in in your browser."
        case .failed(let message): return message
        case .disconnected:
            return hasClient ? "Connect to show your events and tasks."
                             : "This copy of Waverly has no Google sign-in of its own. Choose an OAuth client file to connect."
        }
    }

    /// A sign-in that can't check tasks off (made before Waverly could, or with Tasks unticked).
    private var tasksNote: String? {
        guard case .connected = google.state, sources.state != "auth" else { return nil }
        switch google.tasksAccess {
        case .full: return nil
        case .readOnly: return "Sign in again to check off tasks on Waverly."
        case .none: return "Tasks aren't shared with Waverly. Sign in again to show and check them off."
        }
    }

    private var clientDetail: String {
        if let id = google.customClientID { return "Signing in with your client \(id)." }
        return google.hasBuiltInClient ? "Signing in with Waverly's built-in client. You can use a Desktop app client from your own Google Cloud project instead."
                                       : "No client chosen yet. Create a Desktop app OAuth client in Google Cloud Console and choose its JSON file."
    }

    private func confirmDisconnect() {
        let a = NSAlert()
        a.messageText = "Disconnect Google Calendar?"
        a.informativeText = "Waverly will stop showing your events and tasks. You can connect again any time."
        a.addButton(withTitle: "Disconnect")
        a.addButton(withTitle: "Cancel")
        let done: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn { GoogleAuth.shared.disconnect() }
        }
        if let w = SettingsWindowController.shared.window { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }
}
