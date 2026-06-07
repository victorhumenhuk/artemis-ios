//  RealtimeEventLog.swift
//  A live, timestamped record of raw realtime events plus the connection facts,
//  for the developer console. This is how we prove the model is actually being
//  called: real `response.*` events arriving from the realtime endpoint.

import Foundation
import Observation

@MainActor @Observable
final class RealtimeEventLog {
    static let shared = RealtimeEventLog()

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let name: String
        let detail: String
        let isResponse: Bool
        let isError: Bool
    }

    private(set) var entries: [Entry] = []
    var tokenResult = "—"
    var connectionState = "idle"
    var dataChannelState = "—"

    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    func record(_ raw: String, outbound: Bool = false, decodeError: Bool = false) {
        let type = jsonType(raw) ?? String(raw.prefix { $0 != "(" && $0 != " " && $0 != "{" })
        var name = type.isEmpty ? "event" : type
        if outbound { name = "→ " + name }
        if decodeError { name = "decode ✗ " + name }
        let lower = type.lowercased()
        let e = Entry(time: Date(), name: name, detail: String(raw.prefix(280)),
                      isResponse: !outbound && !decodeError && lower.contains("response"),
                      isError: decodeError || lower.contains("error") || lower.contains("fault"))
        entries.append(e)
        if entries.count > 250 { entries.removeFirst(entries.count - 250) }
    }

    /// Pull the "type" value out of a raw realtime JSON string.
    private func jsonType(_ raw: String) -> String? {
        guard let r = raw.range(of: "\"type\"") else { return nil }
        let tail = raw[r.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        let after = tail[tail.index(after: colon)...].drop(while: { $0 == " " || $0 == "\"" })
        let val = after.prefix(while: { $0 != "\"" })
        return val.isEmpty ? nil : String(val)
    }

    func timeString(_ d: Date) -> String { stamp.string(from: d) }

    func reset() {
        entries.removeAll()
        tokenResult = "—"; connectionState = "idle"; dataChannelState = "—"
    }
}
