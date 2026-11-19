// Shortcut.swift — the keyboard shortcut that opens and closes Waverly (config.json
// "hotkey": {"key_code": 13, "modifiers": ["control", "option"], "display": "⌃ ⌥ W"}).
//
// key_code is a macOS virtual key code (kVK_…), so a shortcut keeps working when the
// keyboard layout changes; `display` is how it read on the keyboard it was recorded on.
// Hotkeys.swift matches key-down events against it, the Settings recorder
// (ShortcutRecorder.swift) makes new ones and checks them with `verdict`.

import AppKit
import Carbon.HIToolbox

struct Shortcut: Equatable {
    enum Modifier: String, CaseIterable {
        // the order macOS menus write them in (fn first)
        case fn, control, option, shift, command

        var symbol: String {
            switch self {
            case .fn: "fn"
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        var cgFlag: CGEventFlags {
            switch self {
            case .fn: .maskSecondaryFn
            case .control: .maskControl
            case .option: .maskAlternate
            case .shift: .maskShift
            case .command: .maskCommand
            }
        }

        var nsFlag: NSEvent.ModifierFlags {
            switch self {
            case .fn: .function
            case .control: .control
            case .option: .option
            case .shift: .shift
            case .command: .command
            }
        }
    }

    var keyCode: Int
    var modifiers: Set<Modifier>
    /// How the shortcut reads, e.g. "⌃ ⌥ W".
    var display: String

    static let `default` = Shortcut(keyCode: kVK_ANSI_W, modifiers: [.control, .option])

    init(keyCode: Int, modifiers: Set<Modifier>, display: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = Self.isFunctionKey(keyCode) ? modifiers.subtracting([.fn]) : modifiers
        let d = display?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.display = d.isEmpty ? Self.describe(keyCode: keyCode, modifiers: self.modifiers) : d
    }

    var isDefault: Bool { keyCode == Self.default.keyCode && modifiers == Self.default.modifiers }

    /// Modifiers in menu order.
    var orderedModifiers: [Modifier] { Modifier.allCases.filter(modifiers.contains) }

    // MARK: config.json

    var json: [String: Any] {
        ["key_code": keyCode, "modifiers": orderedModifiers.map(\.rawValue), "display": display]
    }

    /// A shortcut from config.json; nil when it is missing, malformed or not allowed
    /// (the caller then uses the default).
    init?(json: Any?) {
        guard let d = json as? [String: Any],
              let n = d["key_code"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue == n.doubleValue.rounded(), (0...127).contains(n.doubleValue),
              let mods = d["modifiers"] as? [Any] else { return nil }
        var set = Set<Modifier>()
        for m in mods {
            guard let s = m as? String, let mod = Modifier(rawValue: s) else { return nil }
            set.insert(mod)
        }
        let code = n.intValue
        guard Self.keyName(code) != nil else { return nil }
        self.init(keyCode: code, modifiers: set, display: d["display"] as? String)
        if case .rejected = verdict() { return nil }
    }

    // MARK: matching

    /// Keys that macOS reports with the fn flag set whether or not fn is held
    /// (arrows, F1–F20, Home, End, Page Up/Down, Forward Delete, Help, keypad Clear): fn is
    /// never part of a shortcut on them.
    static func isFunctionKey(_ code: Int) -> Bool {
        functionKeys.contains(code)
    }

    private static let fKeys: [(Int, String)] = [
        (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"), (kVK_F6, "F6"),
        (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"), (kVK_F11, "F11"), (kVK_F12, "F12"),
        (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"), (kVK_F16, "F16"), (kVK_F17, "F17"),
        (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
    ]
    private static let functionKeys: Set<Int> = Set(fKeys.map(\.0)).union([
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
        kVK_ForwardDelete, kVK_Help, kVK_ANSI_KeypadClear,
    ])

    static func modifiers(from flags: CGEventFlags) -> Set<Modifier> {
        Set(Modifier.allCases.filter { flags.contains($0.cgFlag) })
    }

    static func modifiers(from flags: NSEvent.ModifierFlags) -> Set<Modifier> {
        Set(Modifier.allCases.filter { flags.contains($0.nsFlag) })
    }

    /// True when a key-down with this key code and these flags is this shortcut:
    /// exactly these modifiers (Caps Lock and the keypad flag don't count; fn doesn't
    /// count on the function keys).
    func matches(keyCode code: Int, flags: CGEventFlags) -> Bool {
        guard code == keyCode else { return false }
        var held = Self.modifiers(from: flags)
        if Self.isFunctionKey(code) { held.remove(.fn) }
        return held == modifiers
    }

    // MARK: names

    private static let modifierKeys: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    private static let specialNames: [Int: String] = {
        var d: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑",
            kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
            kVK_ANSI_KeypadClear: "⌧",
        ]
        for (code, name) in fKeys { d[code] = name }
        return d
    }()

    /// The name of a key as printed on this Mac's keyboard ("H", "Space", "F5", "→");
    /// nil for the modifier keys themselves and codes that are no key.
    static func keyName(_ code: Int) -> String? {
        guard (0...127).contains(code), !modifierKeys.contains(code) else { return nil }
        if let s = specialNames[code] { return s }
        if let s = translate(code), !s.isEmpty { return s.uppercased() }
        return nil
    }

    static func describe(keyCode: Int, modifiers: Set<Modifier>) -> String {
        let mods = Modifier.allCases.filter(modifiers.contains).map(\.symbol)
        return (mods + [keyName(keyCode) ?? "Key \(keyCode)"]).joined(separator: " ")
    }

    /// What the key types with no modifiers in the current keyboard layout.
    private static func translate(_ code: Int) -> String? {
        let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
        for src in sources {
            guard let source = src?.takeRetainedValue(),
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                      OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            }
            guard status == noErr, length > 0 else { continue }
            let s = String(utf16CodeUnits: chars, count: length)
            // control characters (keypad Clear and the like) have no printable name
            if s.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0 != " " }) { return s }
        }
        return nil
    }

    // MARK: checking

    enum Verdict: Equatable {
        case ok
        /// Allowed, with a word of warning.
        case caution(String)
        /// Not allowed: the message says why.
        case rejected(String)
    }

    /// Whether this can be the shortcut: it needs a modifier (fn, ⌃, ⌥ or ⌘; Shift
    /// alone is just typing), and must not take over one macOS or every app relies on.
    func verdict() -> Verdict {
        let m = modifiers
        if m.isDisjoint(with: [.fn, .control, .option, .command]) {
            // fn never counts on the F-keys and arrows (macOS sets it on them by itself)
            if Self.isFunctionKey(keyCode) { return .rejected("Add ⌃, ⌥ or ⌘ to \(Self.keyName(keyCode) ?? "the key").") }
            return .rejected(m.isEmpty ? "Add fn, ⌃, ⌥ or ⌘ to the key."
                                       : "Shift alone isn't enough. Add fn, ⌃, ⌥ or ⌘.")
        }
        if let use = Self.systemUse(keyCode: keyCode, modifiers: m) {
            return .rejected("\(display) is used by macOS for \(use).")
        }
        if m == [.command] {
            return .rejected("\(display) is a standard shortcut in most apps.")
        }
        if m == [.command, .shift] || m == [.command, .option] {
            return .caution("Some apps use \(display) too. While it's set here, they won't get it.")
        }
        // ⌥ and ⌥⇧ with a character key type a special character (å, é, ™…)
        let nonTyping: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_Delete]
        if m.contains(.option), m.isSubset(of: [.option, .shift]),
           !Self.isFunctionKey(keyCode), !nonTyping.contains(keyCode) {
            return .caution("\(display) normally types a special character. While it's set here, you can't type it.")
        }
        return .ok
    }

    /// What macOS itself does with this shortcut, if anything (Apple's list of Mac
    /// keyboard shortcuts, the parts that work everywhere).
    static func systemUse(keyCode k: Int, modifiers m: Set<Modifier>) -> String? {
        let digits3to6 = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        // fn + an arrow reaches apps as Home / End / Page Up / Page Down on keyboards without those keys
        let fnArrows = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        switch (m, k) {
        case ([.command], kVK_Space): return "Spotlight"
        case ([.command, .option], kVK_Space): return "Spotlight in Finder"
        case ([.control], kVK_Space), ([.control, .option], kVK_Space): return "switching input sources"
        case ([.control, .command], kVK_Space), ([.fn], kVK_ANSI_E): return "Emoji & Symbols"
        case ([.command], kVK_Tab), ([.command, .shift], kVK_Tab): return "switching apps"
        case ([.command], kVK_ANSI_Grave), ([.command, .shift], kVK_ANSI_Grave): return "switching windows"
        case ([.command, .option], kVK_Escape): return "Force Quit"
        case ([.control, .command], kVK_ANSI_Q): return "Lock Screen"
        case ([.command, .shift], kVK_ANSI_Q), ([.command, .option, .shift], kVK_ANSI_Q): return "Log Out"
        case ([.control, .command], kVK_ANSI_F), ([.fn], kVK_ANSI_F): return "full screen"
        case ([.command, .shift], _) where digits3to6.contains(k): return "screenshots"
        case ([.control, .command, .shift], _) where digits3to6.contains(k): return "screenshots"
        case ([.command, .option], kVK_ANSI_D), ([.fn], kVK_ANSI_A): return "showing and hiding the Dock"
        case ([.control], _) where arrows.contains(k): return "Mission Control and Spaces"
        case ([.control], kVK_F2), ([.control], kVK_F3), ([.control], kVK_F4), ([.control], kVK_F5),
             ([.control], kVK_F6), ([.control], kVK_F7), ([.control], kVK_F8): return "keyboard navigation"
        case ([.fn, .shift], kVK_ANSI_A): return "Apps"
        case ([.fn], kVK_ANSI_C): return "Control Center"
        case ([.fn], kVK_ANSI_D): return "dictation"
        case ([.fn], kVK_ANSI_H): return "showing the desktop"
        case ([.fn], kVK_ANSI_N): return "Notification Center"
        case ([.fn], kVK_ANSI_Q): return "Quick Note"
        // window tiling: fn ⌃ F / C / R, fn ⌃ arrows and fn ⌃ ⇧ arrows (fn never counts on the arrows,
        // and fn + an arrow may arrive as Home / End / Page Up / Page Down)
        case ([.fn, .control], kVK_ANSI_F), ([.fn, .control], kVK_ANSI_C), ([.fn, .control], kVK_ANSI_R):
            return "arranging windows"
        case ([.control], _) where fnArrows.contains(k): return "arranging windows"
        case ([.control, .shift], _) where arrows.contains(k) || fnArrows.contains(k): return "arranging windows"
        default: return nil
        }
    }
}
