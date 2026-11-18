// ShortcutRecorder.swift — Settings › Controls › Keyboard: shows the shortcut that
// opens and closes Waverly as key caps; click it, then press a new one.
//
// While it listens, a local event monitor takes every key press in the app (so ⌘Q,
// ⌘W, Tab or the tab shortcuts don't act) and Hotkeys lets everything through.
// Esc cancels, as does clicking it again, clicking elsewhere or leaving the window.
// A shortcut without fn, ⌃, ⌥ or ⌘, or one macOS already uses, is refused with a
// message and the recorder keeps listening; one some apps also use is kept with a
// word of warning.

import AppKit
import SwiftUI

struct ShortcutSetting: View {
    @ObservedObject private var config = ConfigStore.shared
    @StateObject private var recorder: ShortcutRecorderModel

    init(recorder: ShortcutRecorderModel? = nil) {
        _recorder = StateObject(wrappedValue: recorder ?? ShortcutRecorderModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelRow(title: "Show and hide", detail: "Press it to open, press it again to close") {
                ShortcutField(model: recorder, shortcut: config.hotkey)
            }
            if let note = recorder.note {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: note.rejected ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(note.rejected ? HudColor.bad : HudColor.warn)
                        .accessibilityHidden(true)
                    Text(note.text)
                        .font(.system(size: 12))
                        .foregroundStyle(HudColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
            PanelDivider()
            HStack(spacing: 8) {
                Text("Esc always closes.")
                    .font(.system(size: 12)).foregroundStyle(HudColor.ink2)
                Spacer(minLength: 8)
                Button("Reset to Default") { recorder.reset() }
                    .hudButton(.quiet)
                    .disabled(config.hotkey.isDefault && !recorder.isRecording)
                    .help("Go back to \(Shortcut.default.display)")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .animation(.easeOut(duration: 0.18), value: recorder.note)
        .onDisappear { recorder.stop() }
    }
}

/// The key caps; a click starts or stops listening.
private struct ShortcutField: View {
    @ObservedObject var model: ShortcutRecorderModel
    let shortcut: Shortcut
    @State private var hover = false

    var body: some View {
        Button { model.toggle() } label: {
            HStack(spacing: 4) {
                if model.isRecording {
                    if model.held.isEmpty {
                        Text("Type a shortcut")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(HudColor.sunLight)
                    } else {
                        ForEach(Shortcut.Modifier.allCases.filter(model.held.contains), id: \.self) { KeyCap(text: $0.symbol) }
                        Text("…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(HudColor.sunLight)
                    }
                } else {
                    ForEach(Array(caps.enumerated()), id: \.offset) { KeyCap(text: $0.element) }
                }
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 132, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.isRecording ? HudColor.sun.opacity(0.12) : (hover ? Color.white.opacity(0.06) : HudColor.field)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(model.isRecording ? HudColor.sun.opacity(0.9) : Color.white.opacity(0.14),
                              lineWidth: model.isRecording ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: model.isRecording)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { model.fieldFrame = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in model.fieldFrame = f }
            })
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(model.isRecording ? "Press the new shortcut. Esc cancels." : "Click to change the shortcut")
        .accessibilityLabel("Keyboard shortcut")
        .accessibilityValue(model.isRecording ? "Listening for a new shortcut" : shortcut.display)
        .accessibilityHint(model.isRecording ? "Press the new shortcut, or Escape to cancel" : "Click, then press a new shortcut")
    }

    private var caps: [String] {
        shortcut.orderedModifiers.map(\.symbol) + [Shortcut.keyName(shortcut.keyCode) ?? "Key \(shortcut.keyCode)"]
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 2 ? 11.5 : 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(HudColor.ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
    }
}

@MainActor final class ShortcutRecorderModel: ObservableObject {
    struct Note: Equatable {
        let text: String
        let rejected: Bool
    }

    @Published private(set) var isRecording = false
    @Published private(set) var held: Set<Shortcut.Modifier> = []
    @Published private(set) var note: Note?
    /// Where the field is, in the window's content (top-left origin).
    var fieldFrame: CGRect = .zero
    private var monitor: Any?
    private var resign: NSObjectProtocol?

    init() {
        if case .caution(let why) = ConfigStore.shared.hotkey.verdict() { note = Note(text: why, rejected: false) }
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        held = []
        Hotkeys.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self else { return e }
            let consumed = MainActor.assumeIsolated { self.handle(e) }
            return consumed ? nil : e
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        held = []
        Hotkeys.recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        if let r = resign { NotificationCenter.default.removeObserver(r) }
        monitor = nil
        resign = nil
        if note?.rejected == true { note = nil }       // a refusal is about the attempt, which is over
    }

    func reset() {
        stop()
        ConfigStore.shared.hotkey = .default
        note = nil
        AppLog.info("keyboard shortcut reset to \(Shortcut.default.display)")
    }

    /// True: the event is taken (it goes no further).
    private func handle(_ e: NSEvent) -> Bool {
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            // a click anywhere ends listening; on the field itself its button toggles it off
            if !isOnField(e) { stop() }
            return false
        case .flagsChanged:
            held = Shortcut.modifiers(from: e.modifierFlags.intersection(.deviceIndependentFlagsMask))
            return false
        case .keyDown:
            if e.isARepeat { return true }
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let mods = Shortcut.modifiers(from: flags)
            let code = Int(e.keyCode)
            if code == 53 && mods.subtracting([.fn]).isEmpty {          // Esc: cancel
                stop()
                return true
            }
            guard Shortcut.keyName(code) != nil else { return true }
            let candidate = Shortcut(keyCode: code, modifiers: mods)
            switch candidate.verdict() {
            case .rejected(let why):
                note = Note(text: why, rejected: true)
                NSSound.beep()
            case .caution(let why):
                save(candidate)
                note = Note(text: why, rejected: false)
            case .ok:
                save(candidate)
                note = nil
            }
            return true
        default:
            return false
        }
    }

    private func save(_ s: Shortcut) {
        stop()
        ConfigStore.shared.hotkey = s
        AppLog.info("keyboard shortcut set to \(s.display)")
    }

    /// Clicks on the field itself are left to its button (which stops listening).
    private func isOnField(_ e: NSEvent) -> Bool {
        guard let content = e.window?.contentView else { return false }
        let p = e.locationInWindow
        return fieldFrame.contains(CGPoint(x: p.x, y: content.bounds.height - p.y))
    }
}
