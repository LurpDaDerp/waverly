// SourcesClient.swift — the user's Google calendars and task lists, as hud-core
// sees them (GET /api/sources, spec §4.2), for the Lists and Labels settings.
// hud-core may still be starting or fetching the metadata: "loading" and
// "unavailable" answers are retried for a while on their own.

import Foundation

struct SourceItem: Identifiable, Equatable {
    let id: String                      // source key: "cal:<id>" or "tasks:<id>"
    let name: String
    let color: String?                  // effective palette id when it was served (override or automatic)
    let googleSelected: Bool            // calendars: shown in Google Calendar (task lists: always true)
}

@MainActor final class SourcesClient: ObservableObject {
    static let shared = SourcesClient()

    @Published private(set) var state = "loading"   // setup | loading | ok | auth | error | unavailable
    @Published private(set) var account: String?
    @Published private(set) var calendars: [SourceItem] = []
    @Published private(set) var tasklists: [SourceItem] = []
    @Published private(set) var defaults: (left: [String], right: [String]) = ([], [])
    /// hud-core's automatic colour per source (HUD_STATE/source_colors.json), so the
    /// settings can show what "Automatic" means without asking again.
    @Published private(set) var autoColors: [String: String] = [:]
    @Published private(set) var isLoading = false

    private var task: Task<Void, Never>?
    private var retry: DispatchWorkItem?
    private var retries = 0
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25            // hud-core may fetch the metadata first (≤ 20 s)
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    var hasSources: Bool { !calendars.isEmpty || !tasklists.isEmpty }

    /// The colour to show for a source: the user's override, else the automatic one.
    func color(of key: String) -> String? {
        if let c = ConfigStore.shared.sourceStyle[key]?.color, Palette.isValid(c) { return c }
        return autoColors[key] ?? (calendars + tasklists).first { $0.id == key }?.color
    }

    /// The sources a list shows: its explicit choice, else hud-core's defaults.
    func resolved(_ list: ListConfig, right: Bool) -> [String] {
        list.sources ?? (right ? defaults.right : defaults.left)
    }

    func reload() {
        retries = 0
        fetch()
    }

    private func fetch() {
        retry?.cancel()
        task?.cancel()
        isLoading = true
        let url = URL(string: "http://127.0.0.1:\(ConfigStore.shared.httpPort)/api/sources")!
        task = Task { [weak self, session] in
            var result: [String: Any]?
            do {
                let (data, response) = try await session.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
            } catch {
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            self?.received(result)
        }
    }

    private func received(_ d: [String: Any]?) {
        isLoading = false
        readAutoColors()
        guard let d, let s = d["state"] as? String else {
            state = "unavailable"
            scheduleRetry(after: 3, max: 20)                  // hud-core starting (or restarting)
            return
        }
        state = s
        account = d["account"] as? String
        calendars = (d["calendars"] as? [[String: Any]] ?? []).compactMap { Self.item($0, calendar: true) }
        tasklists = (d["tasklists"] as? [[String: Any]] ?? []).compactMap { Self.item($0, calendar: false) }
        let def = d["defaults"] as? [String: Any]
        defaults = (def?["left"] as? [String] ?? [], def?["right"] as? [String] ?? [])
        switch s {
        case "loading": scheduleRetry(after: 1.5, max: 40)
        case "error": scheduleRetry(after: 10, max: 30)             // hud-core keeps trying Google too
        case "setup":
            // just signed in: hud-core picks up the new token within a few seconds
            if case .connected = GoogleAuth.shared.state { scheduleRetry(after: 2, max: 15) }
        default: break
        }
    }

    private static func item(_ d: [String: Any], calendar: Bool) -> SourceItem? {
        guard let key = d["key"] as? String else { return nil }
        let name = (d["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (calendar ? "Untitled calendar" : "Untitled list")
        return SourceItem(id: key, name: name, color: d["color"] as? String,
                          googleSelected: d["google_selected"] as? Bool ?? true)
    }

    private func readAutoColors() {
        let f = HelperSupervisor.appSupport.appendingPathComponent("source_colors.json")
        guard let data = FileManager.default.contents(atPath: f.path),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let colors = d.compactMapValues { $0 as? String }.filter { Palette.isValid($0.value) }
        if colors != autoColors { autoColors = colors }
    }

    private func scheduleRetry(after seconds: TimeInterval, max: Int) {
        guard retries < max else { return }
        retries += 1
        let w = DispatchWorkItem { [weak self] in self?.fetch() }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}
