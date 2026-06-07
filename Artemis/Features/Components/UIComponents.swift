//  UIComponents.swift
//  Shared building blocks, styled to artemis-style.css. Icons map to SF Symbols
//  for a native feel; the look (radii, shadows, tonal fills) follows the design.

import SwiftUI

// MARK: - Icon

struct Icon: View {
    let name: String
    var size: CGFloat = 22
    var weight: Font.Weight = .regular

    private static let map: [String: String] = [
        "mic": "mic.fill", "micOff": "mic.slash.fill", "keyboard": "keyboard",
        "send": "paperplane.fill", "arrowUp": "arrow.up", "phone": "phone.fill",
        "chevDown": "chevron.down", "chevUp": "chevron.up", "chevRight": "chevron.right", "chevLeft": "chevron.left", "close": "xmark",
        "heart": "heart.fill", "sparkle": "sparkles", "chart": "chart.bar.fill",
        "calendar": "calendar", "gear": "gearshape.fill", "globe": "globe",
        "lock": "lock.fill", "bell": "bell.fill", "person": "person.fill",
        "check": "checkmark", "plus": "plus", "minus": "minus", "image": "photo",
        "leaf": "leaf.fill", "moon": "moon.fill", "play": "play.fill",
        "foot": "figure.walk", "drop": "drop.fill", "ear": "ear", "shield": "checkmark.shield.fill",
        "link": "arrow.up.right", "wave": "waveform",
        "stop": "stop.fill", "location": "location.fill",
    ]

    var body: some View {
        Image(systemName: Self.map[name] ?? name)
            .font(.system(size: size, weight: weight))
    }
}

// MARK: - Artemis mark (the pearlescent moon)

struct ArtemisMark: View {
    var size: CGFloat = 40
    @Environment(\.palette) private var p
    var body: some View {
        Circle()
            .fill(p.orbGradient())
            .frame(width: size, height: size)
            .overlay(
                Circle().fill(
                    RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)],
                                   center: .init(x: 0.34, y: 0.26), startRadius: 0, endRadius: size * 0.4))
                    .blendMode(.screen)
            )
            .shadow(color: Color(hex: "6E5A8C").opacity(0.28), radius: size * 0.16, x: 0, y: size * 0.06)
    }
}

// MARK: - Pill button

struct PillButton: View {
    enum Tone { case sage, dark, blush, ghost, routine, urgent, emergency, crisis, white }
    let title: String
    var tone: Tone = .sage
    var icon: String? = nil
    var height: CGFloat = 56
    var action: () -> Void = {}
    @Environment(\.palette) private var p

    private var colors: (bg: Color, fg: Color) {
        switch tone {
        case .sage: return (p.btnPrimaryBg, p.btnPrimaryFg)
        case .dark: return (p.sage800, .white)
        case .blush: return (p.clay, .white)
        case .ghost: return (Color(hex: "6E5A8C").opacity(0.10), p.sage800)
        case .routine: return (p.routine, .white)
        case .urgent: return (p.urgent, .white)
        case .emergency: return (p.emergency, .white)
        case .crisis: return (p.crisis, p.isDark ? Color(hex: "241E33") : .white)
        case .white: return (.white, p.ink)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Icon(name: icon, size: 20, weight: .semibold) }
                Text(title).font(ArtemisFont.sans(17, .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(colors.fg)
            .background(colors.bg, in: Capsule())
            .shadow(color: tone == .ghost ? .clear : Color(hex: "283C37").opacity(0.16), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(PressButtonStyle())
    }
}

struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            // A tactile micro-spring on press, then a soft settle on release.
            .animation(.spring(response: 0.28, dampingFraction: 0.58), value: configuration.isPressed)
    }
}

// MARK: - Glass icon button

struct GlassIcon: View {
    let icon: String
    var action: () -> Void = {}
    @Environment(\.palette) private var p
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 20)
                .foregroundStyle(p.inkSoft)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(p.glassBorder, lineWidth: 1))
                .shadow(color: Color(hex: "2A2433").opacity(0.08), radius: 4, y: 1)
        }
        .buttonStyle(PressButtonStyle())
    }
}

// MARK: - NHS citation chip (the single most important pixel)

struct NHSCitation: View {
    let title: String
    let url: String
    var sourceNote: String = "Cached NHS guidance"
    @Environment(\.palette) private var p
    var body: some View {
        Link(destination: URL(string: url) ?? URL(string: "https://www.nhs.uk") ?? URL(fileURLWithPath: "/")) {
            HStack(spacing: 10) {
                Text("NHS")
                    .font(ArtemisFont.sans(12, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(Color(hex: "005EB8"), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text("GROUNDED IN")
                        .font(ArtemisFont.sans(11, .semibold))
                        .tracking(0.4)
                        .foregroundStyle(p.inkMute)
                    Text(title)
                        .font(ArtemisFont.sans(14.5, .semibold))
                        .foregroundStyle(p.ink)
                        .lineLimit(1)
                    // Honest about source: live DoS result vs cached fallback.
                    Text(sourceNote)
                        .font(ArtemisFont.sans(10.5, .medium))
                        .foregroundStyle(p.inkMute)
                }
                Spacer(minLength: 0)
                Icon(name: "link", size: 16).foregroundStyle(p.inkMute)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(p.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p
    var body: some View {
        content
            .padding(padding)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(p.hairline2, lineWidth: 1))
            .shadow(color: Color(hex: "3C3357").opacity(p.isDark ? 0.3 : 0.08), radius: 20, y: 10)
    }
}

// MARK: - Bottom sheet (custom, to match the design)

struct ArtemisSheet<Content: View>: View {
    var tint: Color? = nil
    var maxHeightFraction: CGFloat = 0.88
    var onClose: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color(hex: "222D2A").opacity(0.32)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                    .transition(.opacity)   // dim fades in with the slide, no instant pop
                VStack(spacing: 0) {
                    Capsule().fill(Color(hex: "283C37").opacity(0.18))
                        .frame(width: 38, height: 5)
                        .padding(.top, 10).padding(.bottom, 2)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: geo.size.height * maxHeightFraction, alignment: .top)
                .background((tint ?? p.surfaceWarm), in: UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30))
                .shadow(color: Color(hex: "2A2433").opacity(p.isDark ? 0.5 : 0.18), radius: 40, y: -10)
                .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }
}

// MARK: - Section label

struct OverlineLabel: View {
    let text: String
    @Environment(\.palette) private var p
    var body: some View {
        Text(text.uppercased())
            .font(ArtemisFont.sans(12, .bold))
            .tracking(0.8)
            .foregroundStyle(p.inkMute)
    }
}
