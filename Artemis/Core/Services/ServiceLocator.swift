//  ServiceLocator.swift
//  Nearest NHS maternity unit from the cached list. A coarse one-shot location
//  is enough. The live Directory of Healthcare Services v3 client is behind a
//  feature flag; the cached list is the default per the brief.

import Foundation
import CoreLocation
import MapKit

struct MaternityUnit: Decodable, Equatable {
    let name: String
    let phone: String
    var address: String? = nil
    let lat: Double
    let lng: Double
    let open: String

    var displayDistanceUnknown: NearestService {
        NearestService(name: name, phone: phone, distanceKm: 0, address: address)
    }
}

enum ServiceFeatureFlags {
    /// Default to the cached list; live v3 needs assurance we won't have in time.
    static let useLiveDirectoryOfServices = false
}

final class ServiceLocator {
    static let shared = ServiceLocator()
    let units: [MaternityUnit]

    private init() {
        guard let url = Bundle.main.url(forResource: "maternity_units", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { self.units = []; return }
        struct Wrapper: Decodable { let units: [MaternityUnit] }
        self.units = (try? JSONDecoder().decode(Wrapper.self, from: data))?.units ?? []
    }

    /// find_nearest_service implementation. Coordinates optional: if missing we
    /// return the first unit so a call button is always available.
    func nearest(lat: Double?, lng: Double?) -> (service: NearestService, unit: MaternityUnit)? {
        guard !units.isEmpty else { return nil }
        guard let lat, let lng else {
            let u = units[0]
            return (NearestService(name: u.name, phone: u.phone, distanceKm: 0, address: u.address), u)
        }
        let here = CLLocation(latitude: lat, longitude: lng)
        var best: MaternityUnit?
        var bestKm = Double.greatestFiniteMagnitude
        for u in units {
            let km = here.distance(from: CLLocation(latitude: u.lat, longitude: u.lng)) / 1000
            if km < bestKm { bestKm = km; best = u }
        }
        guard let unit = best else { return nil }
        return (NearestService(name: unit.name, phone: unit.phone, distanceKm: (bestKm * 10).rounded() / 10, address: unit.address), unit)
    }
}

/// One-shot coarse location. Reduced accuracy is plenty for nearest-unit.
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    // A LIST, not one slot: connect-prefetch and find_nearest can ask for location
    // at the same time. With a single slot the second overwrote the first, leaking it
    // (and hanging that caller). All waiters resume together when the fix arrives.
    private var continuations: [CheckedContinuation<CLLocationCoordinate2D?, Never>] = []

    @Published private(set) var lastKnown: CLLocationCoordinate2D?
    /// Reverse-geocoded place name (town/city) for the model instructions.
    @Published private(set) var placeName: String?

    /// A short line for the session instructions, so the model uses her location
    /// and never asks for a city or postcode. Nil until we have a fix.
    var sessionLocationLine: String? {
        guard let c = lastKnown else { return nil }
        let place = placeName.map { " in \($0)" } ?? ""
        return String(format: "She is located%@ at latitude %.3f, longitude %.3f. Use this to find her nearest NHS maternity unit. Never ask her for a city, town or postcode, you already have her location.", place, c.latitude, c.longitude)
    }

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        // iOS 26: CLGeocoder is deprecated; use MapKit's reverse-geocoding request.
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) else { return }
        Task { @MainActor in
            let items = try? await request.mapItems
            self.placeName = items?.first?.name
        }
    }
    /// Cached authorization, updated by the delegate. NEVER read
    /// `manager.authorizationStatus` from a view body or getter, that call can
    /// block the main thread (watchdog 0x8BADF00D). Views read this cached value.
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        // The delegate's locationManagerDidChangeAuthorization fires shortly after
        // and seeds authStatus off the render path. No synchronous read here.
    }

    /// Ask for location once, at onboarding, so nearest-unit routing can work.
    func requestPermission() {
        if authStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    var isAuthorized: Bool {
        authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways
    }
    var statusText: String {
        switch authStatus {
        case .authorizedWhenInUse, .authorizedAlways: return "On"
        case .denied, .restricted: return "Off, tap to open Settings"
        default: return "Tap to enable"
        }
    }
    /// A coarse area label for display, if we have a fix.
    var areaText: String? {
        guard let c = lastKnown else { return nil }
        return String(format: "Near %.2f, %.2f", c.latitude, c.longitude)
    }

    /// Returns a coarse coordinate, or nil if denied/unavailable. Never blocks
    /// the safety flow: callers fall back to the first unit.
    func currentCoarseLocation() async -> CLLocationCoordinate2D? {
        #if targetEnvironment(simulator)
        // The simulator's GPS defaults to Cupertino, California (~8190 km from any
        // UK unit), which makes nearest-unit nonsense. There is no real GPS on a
        // sim, so use her stated location (E14) for realistic testing. On a real
        // device this branch is never compiled, and her actual GPS is used.
        let e14 = CLLocationCoordinate2D(latitude: 51.5054, longitude: -0.0235)
        lastKnown = e14
        return e14
        #else
        // Use her REAL GPS on device. Never hardcode over a real fix.
        if let last = lastKnown { return last }
        if authStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if authStatus == .denied || authStatus == .restricted {
            return nil
        }
        let fix: CLLocationCoordinate2D? = await withCheckedContinuation { (cont: CheckedContinuation<CLLocationCoordinate2D?, Never>) in
            self.continuations.append(cont)
            // Only the FIRST waiter starts the request + the safety timeout; the rest
            // just join the queue and resume together when the fix (or timeout) lands.
            if self.continuations.count == 1 {
                self.manager.requestLocation()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    self.finishLocation(nil)
                }
            }
        }
        return fix
        #endif
    }

    // CRASH FIX: CLLocationManager can deliver these callbacks on a NON-main thread
    // on a real device. MainActor.assumeIsolated TRAPS (SIGTRAP) when that happens,
    // which crashed the app on "find my nearest clinic" (the simulator never hit
    // this because it returns a fixed coordinate without a continuation). We now hop
    // to the main actor with a Task (never traps) and resume the continuation EXACTLY
    // once via finishLocation (guards against CoreLocation firing more than once).
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        Task { @MainActor in
            if let coord { self.lastKnown = coord; self.reverseGeocode(coord) }
            self.finishLocation(coord)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authStatus = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if !self.continuations.isEmpty { self.manager.requestLocation() }
            } else if status == .denied || status == .restricted {
                self.finishLocation(nil)
            }
        }
    }

    /// Resume EVERY pending location waiter exactly once, then clear the queue.
    @MainActor private func finishLocation(_ coord: CLLocationCoordinate2D?) {
        let pending = continuations
        continuations = []
        for c in pending { c.resume(returning: coord) }
    }
}
