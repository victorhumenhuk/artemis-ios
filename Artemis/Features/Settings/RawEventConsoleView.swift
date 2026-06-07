//  RawEventConsoleView.swift
//  Definitive proof the model is being called: the live raw realtime events
//  with timestamps, plus token-mint, peer-connection and data-channel state.
//  Response events are highlighted; nothing is filtered.

import SwiftUI

struct RawEventConsoleView: View {
    var onClose: () -> Void
    @Environment(\.palette) private var p
    private var log: RealtimeEventLog { RealtimeEventLog.shared }

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.94, onClose: onClose) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Realtime events").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                    Spacer()
                    Button("Clear") { log.reset() }
                        .font(ArtemisFont.sans(14, .semibold)).foregroundStyle(p.sage600)
                }

                // connection facts
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        factRow("Token mint", log.tokenResult, ok: log.tokenResult.hasPrefix("HTTP 2"))
                        Divider().overlay(p.hairline2)
                        factRow("Peer / connection", log.connectionState, ok: log.connectionState == "connected")
                        Divider().overlay(p.hairline2)
                        factRow("Data channel", log.dataChannelState, ok: log.dataChannelState == "open")
                    }
                }

                OverlineLabel(text: "Live events (\(log.entries.count))")

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if log.entries.isEmpty {
                                Text("No events yet. Send a typed message to call the model.")
                                    .font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute).padding(.vertical, 8)
                            }
                            ForEach(log.entries) { e in
                                eventRow(e).id(e.id)
                            }
                        }
                        .padding(10)
                    }
                    .background(Color.black.opacity(p.isDark ? 0.4 : 0.04), in: RoundedRectangle(cornerRadius: 14))
                    .scrollIndicators(.hidden)
                    .onChange(of: log.entries.count) { _, _ in
                        withAnimation { proxy.scrollTo(log.entries.last?.id, anchor: .bottom) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
    }

    private func factRow(_ k: String, _ v: String, ok: Bool) -> some View {
        HStack {
            Circle().fill(ok ? p.routine : p.inkMute).frame(width: 8, height: 8)
            Text(k).font(ArtemisFont.sans(14, .medium)).foregroundStyle(p.ink)
            Spacer()
            Text(v).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(p.inkSoft)
        }
    }

    private func eventRow(_ e: RealtimeEventLog.Entry) -> some View {
        let c: Color = e.isError ? p.emergency : (e.isResponse ? p.routine : p.inkMute)
        return HStack(alignment: .top, spacing: 8) {
            Text(log.timeString(e.time))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(p.inkMute)
            Text(e.name)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(c)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
