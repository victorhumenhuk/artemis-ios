//  Reachability.swift
//  Minimal network reachability so we can route to the on-device fallback
//  automatically when there is no connection.

import Foundation
import Network

@MainActor
final class Reachability: ObservableObject {
    static let shared = Reachability()
    @Published private(set) var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "artemis.reachability")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
