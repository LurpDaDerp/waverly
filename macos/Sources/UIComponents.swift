// UIComponents.swift — pieces shared by the setup wizard and Settings:
// permission rows, calm notes, the location editor with its city search, the
// colour swatch picker, and small helpers for the Google client file and login item.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

let googleHelpURL = URL(string: "https://github.com/LurpDaDerp/Waverly#google-calendar")!

// MARK: permissions

struct PermissionRow: View {
    let kind: PermissionKind
    @ObservedObject private var permissions = Permissions.shared

    private var info: (symbol: String, tint: String, title: String, why: String) {
        switch kind {
        case .camera: ("camera.fill", "teal", "Camera", "Sees your hand gestures. Video never leaves this Mac.")
        case .accessibility: ("keyboard.fill", "violet", "Accessibility", "Lets \(ConfigStore.shared.hotkey.display) and Esc work from any app.")
        case .location: ("location.fill", "amber", "Location", "Shows the weather where you are.")
        }
    }

    private var state: PermissionState {
        switch kind {
        case .camera: permissions.camera
        case .accessibility: permissions.accessibility
        case .location: permissions.location
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: info.symbol, tint: Palette.color(info.tint)!.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                Text(info.why).font(.system(size: 11.5)).foregroundStyle(HudColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Group {
                switch state {
                case .granted:
                    StatusLabel(text: "Allowed")
                        .accessibilityLabel("\(info.title): allowed")
                case .denied:
                    Button("Open Settings…") { permissions.openSystemSettings(kind) }
                        .hudButton()
                        .accessibilityLabel("Open System Settings to allow \(info.title)")
                case .notDetermined:
                    Button("Allow…") { permissions.request(kind) }
                        .hudButton()
                        .accessibilityLabel("Allow \(info.title)")
                }
            }
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: state)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .accessibilityElement(children: .contain)
    }
}

/// The three permission rows. Re-reads the states while visible: macOS doesn't
/// tell us when the user flips a switch in System Settings. Under Camera, a note
/// when macOS Video Effects that watch every frame are on for Waverly.
struct PermissionsPanel: View {
    @Environment(\.controlActiveState) private var active
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        GlassPanel {
            PermissionRow(kind: .camera)
            if permissions.videoEffects.costly {
                CalmNote(text: "macOS video effects are on for Waverly (\(permissions.videoEffects.costlyNames.joined(separator: ", "))). "
                               + "They look at every camera frame and use extra battery. Waverly doesn't need them.",
                         button: "Video Effects…", action: VideoEffects.showSystemMenu)
                    .padding(.leading, 42)
            }
            PanelDivider(inset: 58)
            PermissionRow(kind: .accessibility)
            PanelDivider(inset: 58)
            PermissionRow(kind: .location)
        }
        .animation(.easeOut(duration: 0.2), value: permissions.videoEffects)
        .task(id: active == .key) {
            // poll only while our window is in front (a closed Settings window keeps its views)
            guard active == .key else { return }
            while !Task.isCancelled {
                Permissions.shared.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Permissions.shared.refresh()
        }
    }
}

/// A quiet line of information inside a panel (not a warning: nothing is wrong),
/// with an optional button.
struct CalmNote: View {
    let text: String
    var button: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle").font(.system(size: 11.5)).foregroundStyle(HudColor.sunLight)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let button { Button(button, action: action).hudButton() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .transition(.opacity)
        .accessibilityElement(children: button == nil ? .combine : .contain)
    }
}

// MARK: location

/// Searches places as you type and offers up to five results below the field.
/// Return picks the highlighted result, ↑ ↓ move, Esc clears.
struct CitySearchField: View {
    var width: CGFloat = 240
    var placeholder = "Search for a city"
    let onPick: (PlaceResult) -> Void

    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var searched = false
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var showList: Bool { focused && trimmed.count >= 2 && (searching || searched) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(HudColor.ink3)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(placeholder).foregroundColor(HudColor.ink3))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(HudColor.ink)
                .focused($focused)
                .onSubmit(pickHighlighted)
                .onExitCommand { query = "" }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .accessibilityLabel("City")
                .accessibilityHint("Type a city name, then choose a result")
            if searching {
                ProgressView().controlSize(.mini).accessibilityLabel("Searching")
            } else if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(HudColor.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .modifier(FieldChrome(focused: focused))
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .overlay(alignment: .topLeading) {
            if showList {
                resultList.offset(y: 36).transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: showList)
        .task(id: trimmed) { await search(trimmed) }
        .preference(key: SearchListShownKey.self, value: showList)
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(searching ? "Searching…" : "No places found")
                    .font(.system(size: 12.5)).foregroundStyle(HudColor.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { i, r in
                Button { pick(r) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.name).font(.system(size: 13, weight: .medium)).foregroundStyle(HudColor.ink)
                        if !r.detail.isEmpty {
                            Text(r.detail).font(.system(size: 11)).foregroundStyle(HudColor.ink2)
                        }
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(i == highlighted ? Color.white.opacity(0.13) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { highlighted = i } }
                .accessibilityLabel(r.detail.isEmpty ? r.name : "\(r.name), \(r.detail)")
            }
        }
        .padding(4)
        .frame(width: max(width, 260), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(nsColor: NSColor(hex: 0x2A2558))))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }

    private func search(_ q: String) async {
        guard q.count >= 2 else {
            results = []; searching = false; searched = false
            return
        }
        searching = true
        try? await Task.sleep(nanoseconds: 350_000_000)       // wait for a pause in typing
        guard !Task.isCancelled else { return }
        let found = await LocationService.shared.search(q)
        guard !Task.isCancelled else { return }
        results = Array(found.prefix(5))
        highlighted = 0
        searching = false
        searched = true
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard showList, !results.isEmpty else { return .ignored }
        highlighted = (highlighted + by + results.count) % results.count
        return .handled
    }

    private func pickHighlighted() {
        guard showList, results.indices.contains(highlighted) else { return }
        pick(results[highlighted])
    }

    private func pick(_ r: PlaceResult) {
        onPick(r)
        query = ""
        focused = false
    }
}

/// True while a city search shows its results: Return then picks a result, so
/// a window's default button must not take it.
struct SearchListShownKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension ConfigStore {
    /// A place the user chose by hand: automatic location goes off.
    func choosePlace(_ r: PlaceResult) {
        locationAuto = false
        setLocation(place: r.name, lat: r.lat, lon: r.lon)
    }
}

/// Settings › General › Location: Automatic (with the detected city) or a city
/// the user searched for.
struct LocationEditor: View {
    @ObservedObject private var config = ConfigStore.shared
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var permissions = Permissions.shared

    // either source may be first to hear about a change (prompt answered, System Settings)
    private var allowed: Bool { permissions.location == .granted || location.authorization == .granted }

    var body: some View {
        GlassPanel {
            PanelRow(title: "Automatic", detail: autoDetail) {
                Toggle("Automatic location", isOn: Binding(get: { config.locationAuto }, set: setAuto))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if config.locationAuto && !allowed {
                PanelDivider()
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HudColor.warn)
                        .accessibilityHidden(true)
                    Text("Waverly doesn't have access to your location.")
                        .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                    Spacer(minLength: 8)
                    Button(permissions.location == .denied ? "Open Settings…" : "Allow…") {
                        permissions.request(.location)
                    }
                    .hudButton()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if !config.locationAuto {
                PanelDivider()
                PanelRow(title: "City", detail: config.place.isEmpty ? "None chosen yet" : config.place) {
                    CitySearchField(width: 230) { config.choosePlace($0) }
                }
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.2), value: config.locationAuto)
        .onChange(of: location.authorization) { _, a in
            if a == .granted && config.locationAuto { location.refresh() }
        }
    }

    private var autoDetail: String {
        guard config.locationAuto else { return "Use your Mac's location for the weather" }
        if location.isLocating { return "Locating…" }
        if !allowed { return "Location access is off" }
        return config.place.isEmpty ? "Location not found yet" : config.place
    }

    private func setAuto(_ on: Bool) {
        config.locationAuto = on
        guard on else { return }
        if allowed { location.refresh() } else { permissions.request(.location) }
    }
}

// MARK: colours

/// A colour well that opens the palette; "Automatic" removes the override.
struct SwatchPicker: View {
    let selection: String?              // nil = automatic
    var automatic: String? = nil        // what automatic currently looks like
    var allowsAutomatic = true
    var label = "Color"
    let onPick: (String?) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                ColorDot(id: selection ?? automatic, size: 14)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(HudColor.ink3)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(selection.flatMap { Palette.color($0)?.name } ?? "Automatic")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if allowsAutomatic {
                    Button { choose(nil) } label: {
                        HStack(spacing: 8) {
                            ColorDot(id: automatic, size: 14)
                            Text("Automatic").font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            if selection == nil { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                        }
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selection == nil ? 0.1 : 0.04)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 5), spacing: 8) {
                    ForEach(Palette.all) { c in
                        Button { choose(c.id) } label: {
                            Circle().fill(c.color).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: selection == c.id ? 2 : 0).padding(-3))
                                .frame(width: 26, height: 26)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                        .accessibilityLabel(c.name)
                        .accessibilityAddTraits(selection == c.id ? .isSelected : [])
                    }
                }
            }
            .padding(12)
            .frame(width: 186)
        }
    }

    private func choose(_ id: String?) {
        onPick(id)
        open = false
    }
}

// MARK: Google client file, login item

enum GoogleClientFile {
    /// Asks for a Google "client_secret_….json" file and switches sign-in to it.
    @MainActor static func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose Google Client File"
        panel.message = "Choose the client_secret….json file you downloaded from Google Cloud Console."
        panel.prompt = "Use File"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try GoogleAuth.shared.useCustomClient(from: url)
                AppLog.info("Google: using the client in \(url.lastPathComponent)")
            } catch {
                let a = NSAlert()
                a.messageText = "That file can't be used"
                a.informativeText = "Choose the OAuth client file for a Desktop app, as downloaded from Google Cloud Console. (\(error.localizedDescription))"
                if let w = NSApp.keyWindow { a.beginSheetModal(for: w) } else { a.runModal() }
            }
        }
        if let w = NSApp.keyWindow { panel.beginSheetModal(for: w, completionHandler: handle) } else { handle(panel.runModal()) }
    }
}

enum LoginItemSetting {
    private static let pendingKey = "HUDLoginItemPending"

    /// Opened from the disk image or a translocated copy: that path goes away, so
    /// the login item is only registered once Waverly runs from where it's installed.
    static var canRegister: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    /// Turning it on where that can't be done yet is remembered and done by
    /// `applyPending()` on a later launch from the installed copy.
    @MainActor static func set(_ on: Bool) {
        if on && !canRegister {
            UserDefaults.standard.set(true, forKey: pendingKey)
            AppLog.info("launch at login: deferred while running from \(Bundle.main.bundlePath)")
            return
        }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        LoginItem.setEnabled(on)
    }

    /// Call at launch: registers a login item the setup wizard had to defer.
    @MainActor static func applyPending() {
        guard UserDefaults.standard.bool(forKey: pendingKey), canRegister else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        AppLog.info("launch at login: registering the deferred login item")
        LoginItem.setEnabled(true)
    }
}
