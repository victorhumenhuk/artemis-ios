//  DebugView.swift
//  Hidden diagnostics, reached by triple-tapping the version number in Settings.
//  Shows live connection status for the voice session, the token server and the
//  NHS API, and a switch to prove the retrieval refusal path.

import SwiftUI

private enum Probe: Equatable { case unknown, checking, ok(String), fail(String) }

struct DebugView: View {
    var onClose: () -> Void
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    @State private var token: Probe = .unknown
    @State private var nhs: Probe = .unknown
    @State private var server: Probe = .unknown
    @State private var logs: [String] = []

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.92, onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Diagnostics").voiceStyle(28, weight: .medium).foregroundStyle(p.ink)

                    statusCard
                    flagsCard
                    PillButton(title: "Run checks", tone: .sage) { Task { await runChecks() } }
                    logsCard
                }
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .task { await runChecks() }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                row("Voice session", voiceProbe)
                Divider().overlay(p.hairline2)
                row("Token server", server)
                Divider().overlay(p.hairline2)
                row("NHS content API", nhs)
                Divider().overlay(p.hairline2)
                row("Ephemeral key", token)
            }
        }
    }

    private var voiceProbe: Probe {
        let s = engine.voiceStatus
        return s == "not started" ? .fail(s) : .ok(s)
    }

    private var flagsCard: some View {
        Card {
            Toggle(isOn: Binding(
                get: { DebugFlags.shared.retrievalDisabled },
                set: { DebugFlags.shared.retrievalDisabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Disable NHS retrieval").font(ArtemisFont.sans(16, .medium)).foregroundStyle(p.ink)
                    Text("Proves Artemis refuses and escalates instead of guessing")
                        .font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute)
                }
            }.tint(p.sage600)
        }
    }

    private var logsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                OverlineLabel(text: "Recent log")
                if logs.isEmpty {
                    Text("No events yet.").font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute)
                } else {
                    ForEach(Array(logs.suffix(14).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Server: \(RealtimeConfig.serverBaseURL.absoluteString) · model: \(RealtimeConfig.model)")
                    .font(ArtemisFont.sans(12)).foregroundStyle(p.inkMute).padding(.top, 4)
            }
        }
    }

    private func row(_ title: String, _ probe: Probe) -> some View {
        HStack(spacing: 10) {
            dot(probe)
            Text(title).font(ArtemisFont.sans(15.5, .medium)).foregroundStyle(p.ink)
            Spacer()
            Text(label(probe)).font(ArtemisFont.sans(13)).foregroundStyle(p.inkSoft)
                .multilineTextAlignment(.trailing)
        }
    }
    private func dot(_ probe: Probe) -> some View {
        let c: Color = {
            switch probe {
            case .ok: return p.routine
            case .fail: return p.emergency
            case .checking: return p.urgent
            case .unknown: return p.inkMute
            }
        }()
        return Circle().fill(c).frame(width: 9, height: 9)
    }
    private func label(_ probe: Probe) -> String {
        switch probe {
        case .unknown: return "—"
        case .checking: return "checking…"
        case .ok(let s): return s
        case .fail(let s): return s
        }
    }

    private func runChecks() async {
        logs = ArtemisLog.recent
        server = .checking; nhs = .checking; token = .checking

        // token server health
        server = await probe(path: "health") { _ in "reachable" }

        // NHS content via proxy
        nhs = await probe(path: "nhs/content?path=/conditions/pre-eclampsia") { data in
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["name"] as? String { return "live: \(name)" }
            return "reachable"
        }

        // mint an ephemeral key
        token = await probePost(path: "realtime/token") { data in
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let v = obj["value"] as? String { return "minted \(v.prefix(3))…" }
                if let cs = obj["client_secret"] as? [String: Any], let v = cs["value"] as? String { return "minted \(v.prefix(3))…" }
                if let err = obj["error"] { return "error: \(err)" }
            }
            return "unexpected response"
        }
        logs = ArtemisLog.recent
    }

    private func probe(path: String, _ parse: @escaping (Data) -> String) async -> Probe {
        guard let url = URL(string: RealtimeConfig.serverBaseURL.absoluteString + "/" + path) else { return .fail("invalid URL") }
        var req = URLRequest(url: url); req.timeoutInterval = 6
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return .fail("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            return .ok(parse(data))
        } catch { return .fail("unreachable") }
    }
    private func probePost(path: String, _ parse: @escaping (Data) -> String) async -> Probe {
        guard let url = URL(string: RealtimeConfig.serverBaseURL.absoluteString + "/" + path) else { return .fail("invalid URL") }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = Data("{}".utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .fail("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            return .ok(parse(data))
        } catch { return .fail("unreachable") }
    }
}
