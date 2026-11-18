// ConfigStore.swift — the in-memory model of config.json (spec §2), the single
// source of truth for the helpers. Only the app writes the file: every change
// is saved, debounced (0.4 s) and atomically (temp file + rename), readable only
// by the user (0600, in a 0700 folder); keys the app does not know (engine tuning,
// anything added by hand) are kept as they are on disk. After each save the app
// tells hud-core (onSaved -> CoreLink "config-changed"), which re-reads the file at
// once and applies it live; hud-core also polls the file every 2 s, and hud-engine
// (gesture settings) checks it every 2 s, also while the HUD is closed.

import AppKit
import Combine

enum TemperatureUnit: String, CaseIterable { case fahrenheit, celsius }
enum WindUnit: String, CaseIterable { case mph, kmh }
enum ClockFormat: String, CaseIterable { case h12 = "12h", h24 = "24h" }
/// The cards' tone on the page: adaptive follows the sky (light by day, dark at night).
enum Theme: String, CaseIterable { case adaptive, light, dark }
/// How much of the weather the page's sky draws.
enum WeatherDetail: String, CaseIterable { case low, medium, high }

/// Hand-scrolling speed: a multiple of the standard speed, in 0.25 steps in Settings.
/// The same rules as hud/python/hud/common.py (SCROLL_SPEED_RANGE) and the page.
enum ScrollSpeed {
    static let range = 0.5...2.0
    static let step = 0.25
    static let defaultValue = 1.0
    /// Not a number -> the default; otherwise clamped to the range, kept to hundredths.
    static func validated(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return defaultValue }
        return (min(max(v, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }
}

/// The page's open / close animation (hud/ui/anim.js); the same names as common.py.
enum AnimationType: String, CaseIterable {
    case fade, zoom, shatter, slide, swirl
    var title: String { rawValue.capitalized }
}

/// How long the page's open (wake) or close animation takes, in seconds. 0 means instant
/// (no animation); otherwise a value in `range`, in 0.1 s steps in Settings. The same
/// rules as hud/python/hud/common.py (animation_seconds) and the page.
struct AnimationLength {
    let key: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    static let step = 0.1

    static let open = AnimationLength(key: "open_animation_s", range: 0.3...2.0, defaultValue: 1.0)
    static let close = AnimationLength(key: "close_animation_s", range: 0.2...1.5, defaultValue: 0.75)

    /// Not a number -> the default; below the range -> 0 (instant); above it -> the maximum.
    /// Kept to hundredths, so config.json reads 0.3, not 0.30000000000000004.
    func validated(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return defaultValue }
        return v < range.lowerBound ? 0 : (min(v, range.upperBound) * 100).rounded() / 100
    }
}

struct ListConfig: Equatable {
    var title: String
    var sources: [String]?              // nil = never customised: hud-core resolves the defaults
    var eventKeywords: String
    var taskKeywords: String
    var countdowns: Bool                // right list only
    var lookaheadDays: Int              // right list only

    static let leftDefault = ListConfig(title: "Calendar", sources: nil, eventKeywords: "", taskKeywords: "",
                                        countdowns: true, lookaheadDays: 30)
    static let rightDefault = ListConfig(title: "Tasks", sources: nil, eventKeywords: "", taskKeywords: "",
                                         countdowns: true, lookaheadDays: 30)
    static let lookaheadChoices: [(days: Int, label: String)] = [
        (7, "1 week"), (14, "2 weeks"), (30, "1 month"), (90, "3 months"), (180, "6 months"), (365, "1 year"),
    ]
}

struct SourceStyle: Equatable {
    var color: String?                  // palette id; nil = automatic
    var category: String?               // LabelCategory.id; nil = none
}

struct LabelCategory: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String
}

@MainActor final class ConfigStore: ObservableObject {
    static let shared = ConfigStore(file: HelperSupervisor.configFile)
    static let defaultPort = 47780

    @Published var onboarded = false
    @Published var name = ""
    @Published var locationAuto = true
    @Published var place = ""
    @Published var lat: Double?
    @Published var lon: Double?
    @Published var temperatureUnit: TemperatureUnit = .fahrenheit
    @Published var windUnit: WindUnit = .mph
    @Published var clock: ClockFormat = .h12
    @Published var theme: Theme = .adaptive
    @Published var parallax = true
    @Published var weatherAnimation = true
    @Published var weatherDetail: WeatherDetail = .high
    /// Seconds; 0 = instant (AnimationLength).
    @Published var openAnimation = AnimationLength.open.defaultValue
    @Published var closeAnimation = AnimationLength.close.defaultValue
    @Published var openAnimationType: AnimationType = .fade
    @Published var closeAnimationType: AnimationType = .fade
    /// Hand-gesture scrolling only; the trackpad and mouse follow macOS.
    @Published var scrollReverseVertical = false
    @Published var scrollReverseHorizontal = false
    /// Hand-scrolling speed, a multiple of the standard speed (ScrollSpeed.range).
    @Published var scrollSpeedVertical = ScrollSpeed.defaultValue
    @Published var scrollSpeedHorizontal = ScrollSpeed.defaultValue
    /// Which gestures open and close the HUD (hud-engine applies them live). With both open
    /// gestures off, only the keyboard shortcut and the menu open it.
    @Published var gestureOpenWave = true          // gesture_open_wave: wave, palm to the camera
    @Published var gestureOpenFist = true          // gesture_open_fist: a fist, then an open hand
    @Published var gestureCloseFist = true         // gesture_close_fist: an open palm, then a fist
    @Published var autoCloseAway = true            // auto_close_away: nobody seen for away_seconds
    @Published var autoCloseDark = true            // auto_close_dark: the room dark for away_seconds
    /// Opens and closes the HUD (Hotkeys.swift).
    @Published var hotkey = Shortcut.default
    @Published var left = ListConfig.leftDefault
    @Published var right = ListConfig.rightDefault
    @Published var sourceStyle: [String: SourceStyle] = [:]
    @Published var categories: [LabelCategory] = []

    let file: URL
    /// Called after config.json was written (the app nudges hud-core to re-read it at once).
    var onSaved: (() -> Void)?
    private var raw: [String: Any] = [:]          // the file as last read or written (unknown keys live here)
    private var lastWritten: Data?
    private var pendingSave: DispatchWorkItem?
    private var changes: AnyCancellable?

    var httpPort: Int {
        if let p = (raw["http_port"] as? NSNumber)?.intValue, (1...65535).contains(p) { return p }
        return Self.defaultPort
    }

    /// Seconds without anyone in view (or in the dark) before the HUD closes by itself
    /// (engine tuning, not in the UI; the same fallback as hud/python/hud/common.py).
    var awaySeconds: Double {
        Self.number(raw["away_seconds"]) ?? 5.0
    }

    /// Whether any hand gesture opens the HUD.
    var gestureOpens: Bool { gestureOpenWave || gestureOpenFist }
    /// Whether anything but the keyboard and the menu closes it.
    var gestureCloses: Bool { gestureCloseFist || autoCloseAway || autoCloseDark }

    init(file: URL) {
        self.file = file
        load()
        changes = objectWillChange.sink { [weak self] _ in self?.scheduleSave() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    // MARK: API

    /// A located or chosen place. Coordinates are rounded to 4 decimals (~10 m);
    /// hud-core rounds further before it calls the weather service.
    func setLocation(place: String, lat: Double, lon: Double) {
        let la = (lat * 10_000).rounded() / 10_000, lo = (lon * 10_000).rounded() / 10_000
        if self.place != place { self.place = place }
        if self.lat != la { self.lat = la }
        if self.lon != lo { self.lon = lo }
    }

    /// Writes a pending change now (the app is quitting).
    func flush() {
        guard let w = pendingSave else { return }
        w.cancel()
        pendingSave = nil
        save()
    }

    /// The units and clock people in this region expect (used for a new config).
    static func regionalDefaults(_ locale: Locale = .current) -> (TemperatureUnit, WindUnit, ClockFormat) {
        let us = locale.measurementSystem == .us
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        return (us ? .fahrenheit : .celsius, us ? .mph : .kmh, format.contains("a") ? .h12 : .h24)
    }

    // MARK: load

    private func load() {
        let fm = FileManager.default
        if let data = fm.contents(atPath: file.path) {
            if let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                raw = d
                apply(d)
                lastWritten = data
                // only the user may read it (files written by older builds were 0644)
                if let mode = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber,
                   mode.intValue & 0o777 != 0o600 {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
                return
            }
            // unreadable: keep a copy for the user, start again from the defaults
            let bad = file.deletingPathExtension().appendingPathExtension("invalid.json")
            try? fm.removeItem(at: bad)
            try? fm.moveItem(at: file, to: bad)
            AppLog.error("config.json is not valid JSON; moved it to \(bad.lastPathComponent) and created a new one")
        }
        (temperatureUnit, windUnit, clock) = Self.regionalDefaults()
        raw = ["http_port": Self.defaultPort, "away_seconds": 5.0, "dark_mean": 6.0, "dark_p99": 22.0,
               "swap_handedness": false]
        save()
        AppLog.info("created \(file.path) (\(temperatureUnit.rawValue), \(windUnit.rawValue), \(clock.rawValue))")
    }

    private func apply(_ d: [String: Any]) {
        let regional = Self.regionalDefaults()
        onboarded = d["onboarded"] as? Bool ?? false
        name = d["name"] as? String ?? ""
        locationAuto = d["location_auto"] as? Bool ?? true
        place = d["place"] as? String ?? ""
        lat = Self.number(d["lat"])
        lon = Self.number(d["lon"])
        temperatureUnit = (d["temperature_unit"] as? String).flatMap(TemperatureUnit.init) ?? regional.0
        windUnit = (d["wind_unit"] as? String).flatMap(WindUnit.init) ?? regional.1
        clock = (d["clock"] as? String).flatMap(ClockFormat.init) ?? regional.2
        theme = (d["theme"] as? String).flatMap(Theme.init) ?? .adaptive
        parallax = Self.bool(d["parallax"]) ?? true
        weatherAnimation = Self.bool(d["weather_animation"]) ?? true
        weatherDetail = (d["weather_detail"] as? String).flatMap(WeatherDetail.init) ?? .high
        openAnimation = AnimationLength.open.validated(Self.number(d[AnimationLength.open.key]))
        closeAnimation = AnimationLength.close.validated(Self.number(d[AnimationLength.close.key]))
        openAnimationType = (d["open_animation"] as? String).flatMap(AnimationType.init) ?? .fade
        closeAnimationType = (d["close_animation"] as? String).flatMap(AnimationType.init) ?? .fade
        scrollReverseVertical = Self.bool(d["scroll_reverse_vertical"]) ?? false
        scrollReverseHorizontal = Self.bool(d["scroll_reverse_horizontal"]) ?? false
        scrollSpeedVertical = ScrollSpeed.validated(Self.number(d["scroll_speed_vertical"]))
        scrollSpeedHorizontal = ScrollSpeed.validated(Self.number(d["scroll_speed_horizontal"]))
        gestureOpenWave = Self.bool(d["gesture_open_wave"]) ?? true
        gestureOpenFist = Self.bool(d["gesture_open_fist"]) ?? true
        gestureCloseFist = Self.bool(d["gesture_close_fist"]) ?? true
        autoCloseAway = Self.bool(d["auto_close_away"]) ?? true
        autoCloseDark = Self.bool(d["auto_close_dark"]) ?? true
        hotkey = Shortcut(json: d["hotkey"]) ?? .default
        let lists = d["lists"] as? [String: Any]
        left = Self.list(lists?["left"], ListConfig.leftDefault)
        right = Self.list(lists?["right"], ListConfig.rightDefault)
        var styles: [String: SourceStyle] = [:]
        for (key, v) in d["source_style"] as? [String: Any] ?? [:] {
            guard let s = v as? [String: Any] else { continue }
            styles[key] = SourceStyle(color: s["color"] as? String, category: s["category"] as? String)
        }
        sourceStyle = styles
        categories = (d["categories"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, !id.isEmpty else { return nil }
            return LabelCategory(id: id, name: c["name"] as? String ?? "", color: c["color"] as? String ?? "slate")
        }
    }

    /// A JSON true / false (not a number that happens to be 0 or 1).
    private static func bool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func list(_ v: Any?, _ def: ListConfig) -> ListConfig {
        guard let d = v as? [String: Any] else { return def }
        var l = def
        if let t = d["title"] as? String { l.title = t }
        l.sources = (d["sources"] as? [Any])?.compactMap { $0 as? String }
        if let k = d["event_keywords"] as? String { l.eventKeywords = k }
        if let k = d["task_keywords"] as? String { l.taskKeywords = k }
        if let c = d["countdowns"] as? Bool { l.countdowns = c }
        if let n = number(d["lookahead_days"]), n >= 1 { l.lookaheadDays = Int(min(n, 3650)) }   // Int(1e300) traps
        return l
    }

    // MARK: save

    private func scheduleSave() {
        pendingSave?.cancel()
        // objectWillChange fires before the new value is stored: save on a later turn
        let w = DispatchWorkItem { [weak self] in
            self?.pendingSave = nil
            self?.save()
        }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    private func save() {
        // start from the file as it is now, so keys added by hand since we read it survive
        var d = raw
        if let data = FileManager.default.contents(atPath: file.path),
           let disk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { d = disk }
        d["version"] = 2
        d["onboarded"] = onboarded
        d["name"] = name
        d["location_auto"] = locationAuto
        d["place"] = place
        d["lat"] = lat.map { $0 as Any } ?? NSNull()
        d["lon"] = lon.map { $0 as Any } ?? NSNull()
        d["temperature_unit"] = temperatureUnit.rawValue
        d["wind_unit"] = windUnit.rawValue
        d["clock"] = clock.rawValue
        d["theme"] = theme.rawValue
        d["parallax"] = parallax
        d["weather_animation"] = weatherAnimation
        d["weather_detail"] = weatherDetail.rawValue
        d[AnimationLength.open.key] = AnimationLength.open.validated(openAnimation)
        d[AnimationLength.close.key] = AnimationLength.close.validated(closeAnimation)
        d["open_animation"] = openAnimationType.rawValue
        d["close_animation"] = closeAnimationType.rawValue
        d["scroll_reverse_vertical"] = scrollReverseVertical
        d["scroll_reverse_horizontal"] = scrollReverseHorizontal
        d["scroll_speed_vertical"] = ScrollSpeed.validated(scrollSpeedVertical)
        d["scroll_speed_horizontal"] = ScrollSpeed.validated(scrollSpeedHorizontal)
        d["gesture_open_wave"] = gestureOpenWave
        d["gesture_open_fist"] = gestureOpenFist
        d["gesture_close_fist"] = gestureCloseFist
        d["auto_close_away"] = autoCloseAway
        d["auto_close_dark"] = autoCloseDark
        d["hotkey"] = hotkey.json
        if d["http_port"] == nil { d["http_port"] = Self.defaultPort }
        d.removeValue(forKey: "timezone")                    // always the Mac's own time zone now
        var lists = d["lists"] as? [String: Any] ?? [:]
        lists["left"] = Self.encode(left, over: lists["left"], right: false)
        lists["right"] = Self.encode(right, over: lists["right"], right: true)
        d["lists"] = lists
        var styles: [String: Any] = [:]
        for (key, s) in sourceStyle where s.color != nil || s.category != nil {
            styles[key] = ["color": s.color.map { $0 as Any } ?? NSNull(), "category": s.category.map { $0 as Any } ?? NSNull()]
        }
        d["source_style"] = styles
        d["categories"] = categories.map { ["id": $0.id, "name": $0.name, "color": $0.color] }
        raw = d

        // (JSONSerialization raises an Objective-C exception, not a Swift error, on what it can't encode)
        let json = Self.exactNumbers(d)
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { AppLog.error("config.json: could not encode the settings"); return }
        guard data != lastWritten else { return }            // unchanged: don't wake hud-core's reload
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try GoogleAuth.writeSecret(data, to: file)       // 0600, atomically (temp file + rename)
            lastWritten = data
        } catch {
            AppLog.error("could not write config.json: \(error.localizedDescription)")
            return
        }
        onSaved?()
    }

    /// JSONSerialization writes doubles with 17 digits (38.72 → 38.719999999999999):
    /// write every fractional number in its shortest exact form instead.
    private static func exactNumbers(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(exactNumbers)
        case let a as [Any]: return a.map(exactNumbers)
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && !(n is NSDecimalNumber):
            let x = n.doubleValue
            guard x.isFinite, x != x.rounded() else { return n }
            let exact = NSDecimalNumber(string: "\(x)", locale: Locale(identifier: "en_US_POSIX"))
            return exact.decimalValue.isNaN ? n : exact                // out of Decimal's range (e.g. 5e-324)
        default: return v
        }
    }

    private static func encode(_ l: ListConfig, over old: Any?, right: Bool) -> [String: Any] {
        var d = old as? [String: Any] ?? [:]
        d["title"] = l.title
        d["sources"] = l.sources.map { $0 as Any } ?? NSNull()
        d["event_keywords"] = l.eventKeywords
        d["task_keywords"] = l.taskKeywords
        if right {
            d["countdowns"] = l.countdowns
            d["lookahead_days"] = l.lookaheadDays
        }
        return d
    }
}
