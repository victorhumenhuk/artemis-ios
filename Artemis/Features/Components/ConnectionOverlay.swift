//  ConnectionOverlay.swift
//  Temporary live diagnostics overlay (toggled from Settings, off by default).
//  Proves the realtime pipeline is genuinely on: connection state, model, voice,
//  source of the last reply, and the last token-mint result.

import SwiftUI

struct ConnectionOverlay: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text("REALTIME DIAGNOSTICS").font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.white.opacity(0.6))
            }
            row("conn", "\(engine.voiceMode.rawValue) · \(engine.realtimeState)")
            row("model", engine.activeModel)
            row("voice", engine.activeVoice)
            row("audio", engine.didReceiveModelAudio ? "deltas received" : "none yet")
            row("reply", engine.lastReplySource)
            row("token", engine.lastTokenStatus)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: 230)
    }

    private var dotColor: Color {
        switch engine.voiceMode {
        case .realtime: return engine.realtimeState == "connected" ? .green : .yellow
        case .connecting: return .yellow
        case .offline: return .orange
        case .failed: return .red
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)
            Text(v).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A calm banner shown when the voice is offline or could not connect.
struct VoiceStateBanner: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    var body: some View {
        if engine.connectionFailed {
            banner(icon: "micOff",
                   text: "I can't reach my voice right now.",
                   action: "Retry") { engine.retryConnection() }
        } else if engine.voiceOffline {
            banner(icon: "micOff",
                   text: "Voice offline. I'm here in text, on your phone.",
                   action: nil, perform: {})
        }
    }

    @ViewBuilder
    private func banner(icon: String, text: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Icon(name: icon, size: 15).foregroundStyle(p.urgent)
            Text(text).font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.ink)
            Spacer(minLength: 0)
            if let action {
                Button(action: perform) {
                    Text(action).font(ArtemisFont.sans(13, .bold)).foregroundStyle(p.sage600)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(p.urgentBg, in: Capsule())
        .padding(.horizontal, 16)
    }
}
