// UIStyle.swift — the Waverly look for the app's own windows (setup wizard,
// Settings): the sunset sky of the app icon, glass panels, Bricolage headings,
// buttons and fields. The windows force the dark appearance, so native controls
// match the sky. Text keeps a contrast of at least 4.5:1 on the sky and the panels
// (the sky stays deep wherever text can be; the warm glow sits low, behind the footer).

import AppKit
import CoreText
import SwiftUI

// MARK: colours

enum HudColor {
    static let ink = Color.white.opacity(0.96)
    static let ink2 = Color.white.opacity(0.76)
    static let ink3 = Color.white.opacity(0.68)
    static let glass = Color.white.opacity(0.07)
    static let glassHover = Color.white.opacity(0.11)
    static let rim = Color.white.opacity(0.13)
    static let line = Color.white.opacity(0.08)
    static let field = Color.black.opacity(0.18)
    /// The icon's warm light: primary buttons, focus, switches.
    static let sun = Color(nsColor: Sunset.glow)
    static let sunLight = Color(nsColor: Sunset.glowLight)
    static let cream = Color(nsColor: Sunset.cream)
    static let sunInk = Color(nsColor: NSColor(hex: 0x2A1B30))
    static let good = Color(nsColor: NSColor(hex: 0x8BE0A4))
    static let warn = Color(nsColor: NSColor(hex: 0xFFC37A))
    static let bad = Color(nsColor: NSColor(hex: 0xFF9C8F))
}

/// The palette of the app icon (design/icon/AppIcon.svg).
enum Sunset {
    /// The icon's sky, top to bottom.
    static let indigo = NSColor(hex: 0x1F2752)
    static let plum = NSColor(hex: 0x7A3E6E)
    static let ember = NSColor(hex: 0xE9895A)
    /// The warm glow behind the hand.
    static let glow = NSColor(hex: 0xFFB27A)
    static let glowLight = NSColor(hex: 0xFFD9A8)
    /// The hand.
    static let cream = NSColor(hex: 0xFFF9F1)
}

// MARK: fonts

@MainActor enum HudFont {
    private static var registered: Bool?
    private static var cache: [String: Font] = [:]

    /// Registers the bundled Bricolage Grotesque for this process (once; the app
    /// calls this at launch, the views also call it lazily).
    @discardableResult
    static func register() -> Bool {
        if let r = registered { return r }
        let url = HelperSupervisor.resources.appendingPathComponent("ui/fonts/BricolageGrotesque.ttf")
        var error: Unmanaged<CFError>?
        var ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !ok, let e = error?.takeRetainedValue(),
           CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue { ok = true }
        if !ok { AppLog.warning("could not register the Bricolage font at \(url.path); using the system font") }
        registered = ok
        return ok
    }

    /// Bricolage at `size` and variable weight (200...800), optical size matched to
    /// the point size like the page's `font-optical-sizing: auto`.
    static func display(_ size: CGFloat, weight: CGFloat = 620) -> Font {
        let key = "\(size)-\(weight)"
        if let f = cache[key] { return f }
        let font: Font
        if register() {
            let axes: [NSNumber: NSNumber] = [
                0x6F70_737A as NSNumber: NSNumber(value: Double(min(max(size, 12), 96))),   // opsz
                0x7767_6874 as NSNumber: NSNumber(value: Double(weight)),                   // wght
                0x7764_7468 as NSNumber: 100,                                               // wdth
            ]
            let d = CTFontDescriptorCreateWithAttributes([
                kCTFontFamilyNameAttribute: "Bricolage Grotesque",
                kCTFontVariationAttribute: axes,
            ] as CFDictionary)
            font = Font(CTFontCreateWithFontDescriptor(d, size, nil))
        } else {
            font = .system(size: size, weight: weight >= 600 ? .semibold : .medium)
        }
        cache[key] = font
        return font
    }
}

// MARK: background

/// The sunset sky of the app icon: indigo overhead deepening to plum, with the
/// ember-and-glow horizon rising from the bottom edge. `glow` (about 0...1) sets how much
/// of the horizon shows (the welcome page, with no text low down, goes to 1.35); the
/// sky stays deep enough for 4.5:1 text wherever text can be.
struct SunsetBackground: View {
    var glow: Double = 1

    var body: some View {
        ZStack {
            LinearGradient(stops: [
                .init(color: Color(nsColor: Sunset.indigo), location: 0),
                .init(color: Color(nsColor: NSColor(hex: 0x29295A)), location: 0.5),
                .init(color: Color(nsColor: NSColor(hex: 0x372B5F)), location: 0.8),
                .init(color: Color(nsColor: NSColor(hex: 0x4A2F64)), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            // the horizon: a wide, low glow from the icon's warm light through ember into plum
            RadialGradient(stops: [
                .init(color: Color(nsColor: Sunset.glow).opacity(0.6 * glow), location: 0),
                .init(color: Color(nsColor: Sunset.ember).opacity(0.42 * glow), location: 0.3),
                .init(color: Color(nsColor: Sunset.plum).opacity(0.3 * glow), location: 0.62),
                .init(color: Color(nsColor: Sunset.plum).opacity(0), location: 1),
            ], center: .bottom, startRadius: 0, endRadius: 180)
                .scaleEffect(x: 2.6, y: 1, anchor: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: panels and rows

/// A glass panel: translucent white over the sky with a fine rim.
struct GlassPanel<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // the rim is drawn behind the content: a floating list (city results) may cross it
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HudColor.glass)
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HudColor.rim, lineWidth: 1)
            }
    }
}

/// A row in a panel: label on the leading side, control on the trailing side.
struct PanelRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(HudColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }
}

struct PanelDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(HudColor.line).frame(height: 1).padding(.leading, inset).padding(.trailing, 16)
    }
}

/// A small heading above a panel.
struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(HudFont.display(15, weight: 600)).foregroundStyle(HudColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: buttons

struct HudButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, kind: kind, large: large)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: large ? 14.5 : 13, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, kind == .quiet ? 8 : (large ? 26 : 16))
                .frame(minHeight: large ? 40 : 30)
                .background(background)
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.42)
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hover = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .primary: HudColor.sunInk
            case .secondary: HudColor.ink
            case .quiet: hover && enabled ? HudColor.ink : HudColor.ink2
            case .destructive: HudColor.bad
            }
        }

        @ViewBuilder private var background: some View {
            switch kind {
            case .primary:
                Capsule().fill(LinearGradient(colors: [HudColor.sunLight, HudColor.sun], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().fill(configuration.isPressed ? Color.black.opacity(0.1)
                                            : Color.white.opacity(hover && enabled ? 0.12 : 0)))
                    .shadow(color: HudColor.sun.opacity(enabled ? 0.28 : 0), radius: 10, y: 3)
            case .secondary, .destructive:
                Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : (hover && enabled ? 0.16 : 0.11)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            case .quiet:
                Color.clear
            }
        }
    }
}

extension View {
    func hudButton(_ kind: HudButtonStyle.Kind = .secondary, large: Bool = false) -> some View {
        buttonStyle(HudButtonStyle(kind: kind, large: large))
    }
}

// MARK: text fields

/// The well behind our text fields; the rim lights up while editing.
struct FieldChrome: ViewModifier {
    var focused: Bool
    var large = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 12 : 8, style: .continuous)
        return content
            .padding(.horizontal, large ? 14 : 10)
            .frame(height: large ? 44 : 30)
            .background(shape.fill(HudColor.field))
            .overlay(shape.strokeBorder(focused ? HudColor.sun.opacity(0.85) : Color.white.opacity(0.14),
                                        lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// A plain text field in the Waverly style.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var large = false
    var accessibilityLabel: String? = nil
    var autoFocus = false
    var onSubmit: (() -> Void)? = nil
    /// Called when editing ends (Return or focus moves away).
    var onCommit: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: large ? 14 : 12, weight: .medium))
                    .foregroundStyle(HudColor.ink3)
                    .accessibilityHidden(true)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(HudColor.ink3))
                .textFieldStyle(.plain)
                .font(.system(size: large ? 17 : 13))
                .foregroundStyle(HudColor.ink)
                .focused($focused)
                .onSubmit { onSubmit?(); onCommit?() }
                .accessibilityLabel(accessibilityLabel ?? placeholder)
        }
        .modifier(FieldChrome(focused: focused, large: large))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, f in if !f { onCommit?() } }
        .onAppear { if autoFocus { DispatchQueue.main.async { focused = true } } }
    }
}

// MARK: small pieces

/// "✓ Allowed"-style status text.
struct StatusLabel: View {
    let text: String
    var icon = "checkmark.circle.fill"
    var color = HudColor.good

    var body: some View {
        Label {
            Text(text).font(.system(size: 12.5, weight: .medium))
        } icon: {
            Image(systemName: icon).font(.system(size: 13))
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(color)
    }
}

/// An SF Symbol on a soft tinted tile, used at the start of rows.
struct IconTile: View {
    let symbol: String
    var tint: Color = HudColor.sun
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(tint.opacity(0.16)))
            .accessibilityHidden(true)
    }
}

/// A palette colour dot.
struct ColorDot: View {
    let id: String?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Palette.color(id)?.color ?? Color.white.opacity(0.25))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? HudColor.ink : Color.white.opacity(0.24))
                    .frame(width: i == index ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: index)
        .accessibilityElement()
        .accessibilityLabel("Step \(index + 1) of \(count)")
    }
}

/// A calm message in place of content that isn't there (yet).
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var busy = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small).frame(height: 28)
            } else {
                Image(systemName: symbol).font(.system(size: 24, weight: .regular)).foregroundStyle(HudColor.ink2)
                    .frame(height: 28)
                    .accessibilityHidden(true)
            }
            Text(title).font(HudFont.display(15, weight: 600)).foregroundStyle(HudColor.ink)
            Text(message).font(.system(size: 12.5)).foregroundStyle(HudColor.ink2)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            actions.padding(.top, 4)
        }
        .padding(.vertical, 26)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: windows

@MainActor enum HudWindow {
    /// A window in the Waverly style: dark, full-size content under a clear title bar.
    static func make(size: NSSize, title: String, miniaturizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if miniaturizable { style.insert(.miniaturizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Sunset.indigo
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.zoomButton)?.isHidden = true
        if !miniaturizable { w.standardWindowButton(.miniaturizeButton)?.isHidden = true }
        w.collectionBehavior.insert(.fullScreenNone)
        return w
    }

    /// A menu-bar app has no main menu, so ⌘C / ⌘V / ⌘A / ⌘W would do nothing in
    /// our windows. Install a minimal one (never shown: the app has no menu bar).
    static func installMainMenu() {
        guard NSApp.mainMenu?.item(withTitle: "Edit") == nil else { return }
        let main = WindowsOnlyMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Waverly")
        app.addItem(withTitle: "Settings…", action: #selector(HudMenuTarget.openSettings), keyEquivalent: ",").target = HudMenuTarget.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Waverly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}

/// The hidden main menu's shortcuts only act in our own titled windows (setup,
/// Settings, their sheets and panels). The overlay is a key, non-activating panel
/// shown over whatever app the user is in: there ⌘Q must not quit Waverly and ⌘A
/// must not select the page's text, as before the menu existed.
final class WindowsOnlyMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let w = NSApp.keyWindow, !w.styleMask.contains(.nonactivatingPanel) else { return false }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class HudMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = HudMenuTarget()
    @objc func openSettings() { SettingsWindowController.shared.show(tab: nil) }

    /// Settings only once the setup wizard is done.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(openSettings) || ConfigStore.shared.onboarded
    }
}

// MARK: native pieces

/// Set while a floating list (the city search results) covers a part of the
/// window. AppKit hit-tests native controls before SwiftUI content drawn over
/// them, so the controls underneath step aside and the list gets the clicks.
struct ClickThroughKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hudClickThrough: Bool {
        get { self[ClickThroughKey.self] }
        set { self[ClickThroughKey.self] = newValue }
    }
}

final class HudSegmentedControl: NSSegmentedControl {
    var clickThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { clickThrough ? nil : super.hitTest(point) }
}

final class HudPopUpButton: NSPopUpButton {
    var clickThrough = false
    override func hitTest(_ point: NSPoint) -> NSView? { clickThrough ? nil : super.hitTest(point) }
}

/// A native segmented control whose segments share the width equally (SwiftUI's
/// segmented Picker sizes each segment to its label, so rows wouldn't line up).
struct SegmentedChoice<Value: Hashable>: NSViewRepresentable {
    let label: String
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    func makeNSView(context: Context) -> HudSegmentedControl {
        let c = HudSegmentedControl(labels: options.map(\.title), trackingMode: .selectOne,
                                    target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.selectedSegmentBezelColor = Sunset.glow                     // HudColor.sun, like the switches
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.setAccessibilityLabel(label)
        return c
    }

    func updateNSView(_ c: HudSegmentedControl, context: Context) {
        context.coordinator.parent = self
        c.clickThrough = context.environment.hudClickThrough
        c.selectedSegment = options.firstIndex { $0.value == selection } ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HudSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: SegmentedChoice
        init(_ parent: SegmentedChoice) { self.parent = parent }
        @objc func changed(_ c: NSSegmentedControl) {
            guard parent.options.indices.contains(c.selectedSegment) else { return }
            parent.selection = parent.options[c.selectedSegment].value
        }
    }
}

/// Temperature, wind and clock: the same three rows in the wizard and Settings.
struct UnitRows: View {
    @ObservedObject private var config = ConfigStore.shared
    var width: CGFloat = 170

    var body: some View {
        PanelRow(title: "Temperature") {
            SegmentedChoice(label: "Temperature", options: [(.fahrenheit, "°F"), (.celsius, "°C")],
                            selection: $config.temperatureUnit).frame(width: width)
        }
        PanelDivider()
        PanelRow(title: "Wind") {
            SegmentedChoice(label: "Wind", options: [(.mph, "mph"), (.kmh, "km/h")],
                            selection: $config.windUnit).frame(width: width)
        }
        PanelDivider()
        PanelRow(title: "Clock") {
            SegmentedChoice(label: "Clock", options: [(.h12, "12-hour"), (.h24, "24-hour")],
                            selection: $config.clock).frame(width: width)
        }
    }
}

/// A slim progress bar in the sunrise colours; nil = indeterminate (a sweeping segment).
struct HudProgressBar: View {
    let value: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                if let value {
                    Capsule().fill(fill)
                        .frame(width: max(6, g.size.width * min(max(value, 0), 1)))
                        .animation(.easeOut(duration: 0.4), value: value)
                } else {
                    Capsule().fill(fill)
                        .frame(width: g.size.width * 0.28)
                        .offset(x: sweep ? g.size.width * 0.72 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }

    private var fill: LinearGradient {
        LinearGradient(colors: [HudColor.sun, HudColor.sunLight], startPoint: .leading, endPoint: .trailing)
    }
}

/// A native pop-up button of a fixed width (SwiftUI's menu Picker keeps its
/// natural width on macOS, so a column of them wouldn't line up).
struct PopUpChoice: NSViewRepresentable {
    struct Option: Equatable {
        let value: String
        let title: String
        var dot: String? = nil          // palette id drawn before the title
    }

    let label: String
    let options: [Option]
    @Binding var selection: String

    func makeNSView(context: Context) -> HudPopUpButton {
        let b = HudPopUpButton(frame: .zero, pullsDown: false)
        b.target = context.coordinator
        b.action = #selector(Coordinator.changed(_:))
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.setAccessibilityLabel(label)
        return b
    }

    func updateNSView(_ b: HudPopUpButton, context: Context) {
        context.coordinator.parent = self
        b.clickThrough = context.environment.hudClickThrough
        if context.coordinator.shown != options {
            context.coordinator.shown = options
            b.removeAllItems()
            for o in options {
                let item = NSMenuItem(title: o.title, action: nil, keyEquivalent: "")
                item.representedObject = o.value
                if let dot = o.dot { item.image = Palette.dotImage(dot) }
                b.menu?.addItem(item)
                if o.value.isEmpty && options.count > 1 { b.menu?.addItem(.separator()) }   // "none", then the rest
            }
        }
        if let i = b.itemArray.firstIndex(where: { $0.representedObject as? String == selection }) { b.selectItem(at: i) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HudPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: PopUpChoice
        var shown: [Option] = []
        init(_ parent: PopUpChoice) { self.parent = parent }
        @objc func changed(_ b: NSPopUpButton) {
            if let v = b.selectedItem?.representedObject as? String { parent.selection = v }
        }
    }
}
