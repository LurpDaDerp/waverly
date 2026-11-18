// LocationService.swift — where the Mac is, for the weather card. With automatic
// location on (config "location_auto"), one low-accuracy fix is taken at launch,
// after waking from sleep and every few hours; it is turned into a city name and
// saved in config.json only when it changed (moved more than 3 km, or another
// place name). The manual city field searches places by name.
//
// Accuracy is about a kilometre (no GPS-grade fixes are needed); hud-core rounds
// the coordinates further before it asks the weather service.

import AppKit
import CoreLocation
import MapKit

struct PlaceResult: Identifiable, Hashable {
    let id: UUID
    let name: String
    let detail: String
    let lat: Double
    let lon: Double
}

@MainActor final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    @Published private(set) var authorization: PermissionState = .notDetermined
    @Published private(set) var isLocating = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()          // kept alive for the whole request
    private var locateTimeout: DispatchWorkItem?
    /// Asked by `refresh()` before the user answered the prompt: locate once they allow it.
    private var refreshWhenAllowed = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = kCLDistanceFilterNone
        authorization = Self.state(manager.authorizationStatus)
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            NSApp.activate(ignoringOtherApps: true)
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            Permissions.shared.openSystemSettings(.location)
        default:
            refresh()
        }
    }

    /// One fix, if automatic location is on and allowed. Saves the place when it changed.
    func refresh() {
        guard ConfigStore.shared.locationAuto else { return }
        guard authorization == .granted else {
            refreshWhenAllowed = authorization == .notDetermined
            return
        }
        guard !isLocating else { return }
        isLocating = true
        manager.requestLocation()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.isLocating else { return }
            AppLog.warning("location: no fix after 45 s")
            self.manager.stopUpdatingLocation()
            self.isLocating = false
        }
        locateTimeout?.cancel()
        locateTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: w)
    }

    /// Places matching `query` (a city name as the user types it), best first.
    /// MapKit's completer understands partial names ("san fr"); its first few
    /// suggestions are then looked up for their coordinates.
    func search(_ query: String) async -> [PlaceResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let completions = await CompletionFetcher().fetch(q)
        guard !Task.isCancelled else { return [] }
        var results: [PlaceResult] = await withTaskGroup(of: (Int, PlaceResult?).self) { group in
            for (i, c) in completions.prefix(5).enumerated() {
                group.addTask {
                    let item = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start().mapItems.first
                    return (i, item.flatMap { Self.result($0.placemark) })
                }
            }
            var found: [(Int, PlaceResult)] = []
            for await (i, r) in group { if let r { found.append((i, r)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if results.isEmpty, !Task.isCancelled {
            // nothing suggested (or MapKit failed): a plain search, then the geocoder
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = q
            request.resultTypes = .address
            if let response = try? await MKLocalSearch(request: request).start() {
                results = response.mapItems.compactMap { Self.result($0.placemark) }
            }
            if results.isEmpty, !Task.isCancelled, let marks = try? await CLGeocoder().geocodeAddressString(q) {
                results = marks.compactMap { Self.result($0) }
            }
        }
        var seen = Set<String>()
        return results.filter { seen.insert("\($0.name)|\($0.detail)").inserted }
    }

    // MARK: CLLocationManagerDelegate (called on the main thread: the manager was made there)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            let s = Self.state(status)
            let was = authorization
            if s != was {
                authorization = s
                AppLog.info("location access: \(s == .granted ? "allowed" : s == .denied ? "not allowed" : "not asked yet")")
            }
            Permissions.shared.refresh()
            if s == .granted && (refreshWhenAllowed || was != .granted) && ConfigStore.shared.locationAuto {
                refreshWhenAllowed = false
                refresh()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated { located(loc) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        MainActor.assumeIsolated {
            locateTimeout?.cancel()
            isLocating = false
            if code == .denied { authorization = Self.state(self.manager.authorizationStatus) }
            AppLog.warning("location: no fix (\(code.map { "CLError \($0.rawValue)" } ?? error.localizedDescription))")
        }
    }

    // MARK: private

    private func located(_ loc: CLLocation) {
        guard isLocating else { return }
        locateTimeout?.cancel()
        let config = ConfigStore.shared
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(loc) { [weak self] marks, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLocating = false
                guard config.locationAuto else { return }          // switched to a chosen city meanwhile
                let mark = marks?.first
                var place = mark.map(Self.placeName) ?? ""
                let moved: Bool
                if let lat = config.lat, let lon = config.lon {
                    moved = loc.distance(from: CLLocation(latitude: lat, longitude: lon)) > 3000
                } else {
                    moved = true
                }
                if place.isEmpty {
                    // no name (offline?): keep the old one unless we really moved
                    if error != nil { AppLog.warning("location: could not name the place (\(error!.localizedDescription))") }
                    place = moved ? "" : config.place
                }
                guard moved || place != config.place else { return }
                config.setLocation(place: place, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
                AppLog.info("location updated" + (place.isEmpty ? "" : " (\(place))"))
            }
        }
    }

    nonisolated private static func placeName(_ m: CLPlacemark) -> String {
        for s in [m.locality, m.subAdministrativeArea, m.administrativeArea, m.name] {
            if let s, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return ""
    }

    nonisolated private static func result(_ m: CLPlacemark) -> PlaceResult? {
        guard let c = m.location?.coordinate else { return nil }
        let name = placeName(m)
        guard !name.isEmpty else { return nil }
        var detail: [String] = []
        for s in [m.administrativeArea, m.country] {
            if let s, !s.isEmpty, s != name, !detail.contains(s) { detail.append(s) }
        }
        return PlaceResult(id: UUID(), name: name, detail: detail.joined(separator: ", "),
                           lat: c.latitude, lon: c.longitude)
    }

    private static func state(_ s: CLAuthorizationStatus) -> PermissionState {
        switch s {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

/// One round of MapKit search suggestions for a query (addresses and places only).
@MainActor private final class CompletionFetcher: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()
    private var continuation: CheckedContinuation<[MKLocalSearchCompletion], Never>?

    func fetch(_ query: String) async -> [MKLocalSearchCompletion] {
        await withCheckedContinuation { c in
            continuation = c
            completer.delegate = self
            completer.resultTypes = .address
            completer.queryFragment = query
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.finish([]) }   // no answer
        }
    }

    private func finish(_ results: [MKLocalSearchCompletion]) {
        guard let c = continuation else { return }
        continuation = nil
        completer.cancel()
        c.resume(returning: results)
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        MainActor.assumeIsolated { finish(results) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish([]) }
    }
}
