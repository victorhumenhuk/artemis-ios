//  DoSClient.swift
//  One call for the nearest maternity unit: the Worker's /dos/nearest returns the
//  LIVE NHS Directory of Services result when auth + DoS succeed, otherwise a
//  cached-fallback signal that we honour with the bundled ServiceLocator units.
//  Either way the caller always gets a usable nearest unit.

import Foundation
import CoreLocation

enum DoSClient {
    /// Try the live DoS lookup, fall back to the cached units. Returns a service
    /// (for the call button + distance) and a unit (for coordinates/handover).
    static func nearest(lat: Double?, lng: Double?) async -> (service: NearestService, unit: MaternityUnit, live: Bool)? {
        if let live = await fetchLive(lat: lat, lng: lng) { return (live.service, live.unit, true) }
        guard let cached = ServiceLocator.shared.nearest(lat: lat, lng: lng) else { return nil }
        return (cached.service, cached.unit, false)   // cached fallback, always usable
    }

    private struct Resp: Decodable {
        let source: String
        let unit: LiveUnit?
        struct LiveUnit: Decodable { let name: String; let address: String; let phone: String; let distanceKm: Double? }
    }

    private static func fetchLive(lat: Double?, lng: Double?) async -> (service: NearestService, unit: MaternityUnit)? {
        var comps = URLComponents(url: RealtimeConfig.serverBaseURL.appendingPathComponent("dos/nearest"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        if let lat, let lng { items = [URLQueryItem(name: "lat", value: "\(lat)"), URLQueryItem(name: "lng", value: "\(lng)")] }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            guard decoded.source == "live", let u = decoded.unit else {
                ArtemisLog.info("DoS: live unavailable, using cached.")
                return nil   // fallback signal → caller uses cached
            }
            ArtemisLog.info("DoS: live nearest \(u.name).")
            let service = NearestService(name: u.name, phone: u.phone, distanceKm: u.distanceKm ?? 0, address: u.address)
            let unit = MaternityUnit(name: u.name, phone: u.phone, address: u.address, lat: 0, lng: 0, open: "open 24h")
            return (service, unit)
        } catch {
            ArtemisLog.info("DoS: live call failed (\(error)); using cached.")
            return nil
        }
    }
}
