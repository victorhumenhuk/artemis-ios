//  OrbView.swift
//  Artemis herself. Concentric living rings and a warm breathing core. In
//  moonlit mode the core becomes a glowing moon. Driven per-frame by a
//  TimelineView so state changes are smooth and never get stuck.

import SwiftUI

struct Orb: View {
    var state: ConversationState
    var size: CGFloat
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: a calm, still orb with a soft glow, no breathing.
            content(t: 0).frame(width: size, height: size)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Canvas { _, _ in } // keep TimelineView lively even if subviews are static
                .overlay(content(t: t))
                .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        let core = coreScale(t)
        let halo = haloAlpha(t)

        ZStack {
            // halo / bloom (the moon's light)
            Circle()
                .fill(RadialGradient(colors: [p.orbHalo, p.orbBloom, p.orbHalo.opacity(0)],
                                     center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: size * 0.6))
                .frame(width: size * 1.18, height: size * 1.18)
                .blur(radius: 7)
                .opacity(halo)
                .scaleEffect(haloScale(t))

            // ripples (listening)
            if state == .listening {
                ForEach(0..<3, id: \.self) { i in
                    let phase = (t / 2.8 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .strokeBorder(p.sage300.opacity(0.5), lineWidth: 1.5)
                        .frame(width: size, height: size)
                        .scaleEffect(0.62 + phase * 0.88)
                        .opacity(rippleOpacity(phase))
                }
            }

            // concentric rings
            Circle().stroke(p.sage300.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: size * 0.94, height: size * 0.94)
                .rotationEffect(.degrees(ringRotation(t)))
            Circle().stroke(p.sage300.opacity(0.22), lineWidth: 1)
                .frame(width: size * 0.82, height: size * 0.82)
            if state == .thinking {
                Circle().stroke(p.sage600.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [3, 10]))
                    .frame(width: size * 0.72, height: size * 0.72)
                    .rotationEffect(.degrees(-t * 45))
            }

            // core disc
            Circle()
                .fill(RadialGradient(colors: p.orbStops,
                                     center: .init(x: p.isDark ? 0.38 : 0.36, y: p.isDark ? 0.32 : 0.30),
                                     startRadius: 1, endRadius: size * 0.34))
                .frame(width: size * 0.6, height: size * 0.6)
                .overlay(
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.92), .white.opacity(0)],
                                                 center: .init(x: 0.34, y: 0.26), startRadius: 0, endRadius: size * 0.22))
                        .frame(width: size * 0.6, height: size * 0.6)
                        .blendMode(.screen))
                .shadow(color: p.isDark ? p.orbHalo.opacity(0.5) : Color(hex: "6E5A8C").opacity(0.24),
                        radius: p.isDark ? 25 : 19, x: 0, y: p.isDark ? 0 : 14)
                .scaleEffect(core)
                .saturation(state == .silentTyping ? 0.4 : 1)
                .opacity(state == .silentTyping ? 0.9 : 1)
        }
        .frame(width: size, height: size)
    }

    // MARK: motion functions

    private func coreScale(_ t: TimeInterval) -> CGFloat {
        switch state {
        case .idle: return 1 + 0.05 * sinp(t, 5.5)
        case .listening: return 1 + 0.06 * sinp(t, 2.2) + 0.03 * sinp(t, 0.7)
        case .thinking: return 0.99 + 0.03 * sinp(t, 2.6)
        case .responding: return 1 + 0.045 * sinp(t, 1.6)
        case .silentTyping: return 0.94
        }
    }
    private func haloAlpha(_ t: TimeInterval) -> Double {
        switch state {
        case .idle: return 0.7 + 0.25 * (0.5 + 0.5 * sinp(t, 5.5))
        case .listening, .responding: return 1
        case .thinking: return 0.6
        case .silentTyping: return 0.25
        }
    }
    private func haloScale(_ t: TimeInterval) -> CGFloat {
        switch state {
        case .responding: return 1.12
        case .listening: return 1 + 0.06 * (0.5 + 0.5 * sinp(t, 2.2))
        default: return 1
        }
    }
    private func ringRotation(_ t: TimeInterval) -> Double {
        switch state {
        case .idle: return t * 6
        case .listening: return t * 9
        case .responding: return t * 12
        case .thinking: return -t * 18
        case .silentTyping: return t * 3
        }
    }
    private func rippleOpacity(_ phase: Double) -> Double {
        phase < 0.18 ? phase / 0.18 * 0.5 : max(0, 0.5 * (1 - (phase - 0.18) / 0.82))
    }
    private func sinp(_ t: TimeInterval, _ period: Double) -> CGFloat {
        CGFloat(sin(t / period * 2 * .pi))
    }
}
