//  Theme.swift
//  Artemis design tokens, translated 1:1 from artemis-style.css ("Moonlit Calm").
//  Light is the warm lilac-white day palette. Moonlit is the 2am dark palette,
//  where the orb becomes a glowing moon. The palette is injected through the
//  environment so a screen can be forced into moonlit mode exactly like the
//  prototype toggled its `.night` class.

import SwiftUI

extension Color {
    init(hex: String, opacity: Double = 1) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255
        let g = Double((v & 0x00FF00) >> 8) / 255
        let b = Double(v & 0x0000FF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// Every colour Artemis draws with. One struct, two instances (light + moonlit).
struct Palette: Equatable {
    let isDark: Bool

    // neutrals
    let bg: Color
    let bg2: Color
    let surface: Color
    let surfaceWarm: Color
    let hairline: Color
    let hairline2: Color

    // the iris / lavender family (UI inherits from this, as in the CSS --sage-*)
    let sage50, sage100, sage200, sage300, sage400, sage500, sage600, sage700, sage800, sage900: Color
    // lilac aliases (kept harmonised with the primary)
    let lilac50, lilac100, lilac200, lilac300, lilac500, lilac600, lilac700: Color

    // pearl is the orb highlight only (the moon); no gold anywhere.
    let pearl: Color

    // warmth
    let blush: Color
    let blushSoft: Color
    let clay: Color
    let cream: Color

    // ink / text
    let ink: Color
    let inkSoft: Color
    let inkMute: Color

    // triage tiers
    let routine, routineBg: Color
    let urgent, urgentBg: Color
    let emergency, emergencyBg: Color
    let crisis, crisisBg: Color

    // adaptive primary button + sent bubble
    let btnPrimaryBg: Color
    let btnPrimaryFg: Color
    let bubbleMeBg: Color
    let bubbleMeFg: Color
    let glass: Color
    let glassBorder: Color

    // the hero orb gradient stops (pearl -> lavender -> deep iris)
    let orbStops: [Color]
    let orbHalo: Color
    let orbBloom: Color
}

extension Palette {
    static let light = Palette(
        isDark: false,
        bg: Color(hex: "F5F2F7"),
        bg2: Color(hex: "F8F6F8"),
        surface: Color(hex: "FCFBFE"),
        surfaceWarm: Color(hex: "F3EFF8"),
        hairline: Color(hex: "2A2433", opacity: 0.09),
        hairline2: Color(hex: "2A2433", opacity: 0.05),
        sage50: Color(hex: "F5F2F9"), sage100: Color(hex: "ECE6F6"), sage200: Color(hex: "DCD2EC"),
        sage300: Color(hex: "C6B7DD"), sage400: Color(hex: "A593C6"), sage500: Color(hex: "8273AC"),
        sage600: Color(hex: "5C4F8C"), sage700: Color(hex: "4C4076"), sage800: Color(hex: "3D3357"),
        sage900: Color(hex: "2E2742"),
        lilac50: Color(hex: "F5F2F9"), lilac100: Color(hex: "ECE6F6"), lilac200: Color(hex: "DCD2EC"),
        lilac300: Color(hex: "C6B7DD"), lilac500: Color(hex: "5C4F8C"), lilac600: Color(hex: "4C4076"),
        lilac700: Color(hex: "3D3357"),
        pearl: Color(hex: "E7E4EE"),
        blush: Color(hex: "E3C9D6"), blushSoft: Color(hex: "F2E6EC"), clay: Color(hex: "5C4F8C"),
        cream: Color(hex: "F3EFF8"),
        ink: Color(hex: "2A2433"), inkSoft: Color(hex: "6B6475"), inkMute: Color(hex: "948CA1"),
        routine: Color(hex: "5F9E7E"), routineBg: Color(hex: "E6F1EB"),
        urgent: Color(hex: "C68A3A"), urgentBg: Color(hex: "F6ECD8"),
        emergency: Color(hex: "C24A40"), emergencyBg: Color(hex: "F3DEDB"),
        crisis: Color(hex: "5C4F8C"), crisisBg: Color(hex: "ECE6F6"),
        btnPrimaryBg: Color(hex: "5C4F8C"), btnPrimaryFg: .white,
        bubbleMeBg: Color(hex: "5C4F8C"), bubbleMeFg: .white,
        glass: Color.white.opacity(0.72), glassBorder: Color.white.opacity(0.6),
        orbStops: [Color(hex: "F2EEF8"), Color(hex: "DCD2EF"), Color(hex: "C2B2E8"), Color(hex: "9A86C4"), Color(hex: "7E6FB0")],
        orbHalo: Color(hex: "B9A9E0", opacity: 0.55), orbBloom: Color(hex: "B9A9E0", opacity: 0.34)
    )

    static let dark = Palette(
        isDark: true,
        bg: Color(hex: "1A1525"),
        bg2: Color(hex: "201A2E"),
        surface: Color(hex: "251F33"),
        surfaceWarm: Color(hex: "2B2440"),
        hairline: Color(hex: "ECE8F2", opacity: 0.10),
        hairline2: Color(hex: "ECE8F2", opacity: 0.06),
        sage50: Color(hex: "2B2440"), sage100: Color(hex: "322A4A"), sage200: Color(hex: "3C3357"),
        sage300: Color(hex: "564A78"), sage400: Color(hex: "8273AC"), sage500: Color(hex: "9D8DCB"),
        sage600: Color(hex: "B8A6E6"), sage700: Color(hex: "C8BAEC"), sage800: Color(hex: "D8CEF2"),
        sage900: Color(hex: "ECE8F2"),
        lilac50: Color(hex: "2B2440"), lilac100: Color(hex: "322A4A"), lilac200: Color(hex: "3C3357"),
        lilac300: Color(hex: "564A78"), lilac500: Color(hex: "B8A6E6"), lilac600: Color(hex: "C8BAEC"),
        lilac700: Color(hex: "D8CEF2"),
        pearl: Color(hex: "E7E4EE"),
        blush: Color(hex: "E3C9D6"), blushSoft: Color(hex: "2B2440"), clay: Color(hex: "C8BAEC"),
        cream: Color(hex: "2B2440"),
        ink: Color(hex: "ECE8F2"), inkSoft: Color(hex: "A79FB3"), inkMute: Color(hex: "837B95"),
        routine: Color(hex: "7FBE9C"), routineBg: Color(hex: "233A30"),
        urgent: Color(hex: "E0AE63"), urgentBg: Color(hex: "3B3120"),
        emergency: Color(hex: "E0796E"), emergencyBg: Color(hex: "3E2420"),
        crisis: Color(hex: "B8A6E6"), crisisBg: Color(hex: "2E2747"),
        btnPrimaryBg: Color(hex: "B8A6E6"), btnPrimaryFg: Color(hex: "241E33"),
        bubbleMeBg: Color(hex: "5A4D86"), bubbleMeFg: Color(hex: "F2EEFA"),
        glass: Color(hex: "3C3452", opacity: 0.55), glassBorder: Color(hex: "ECE8F2", opacity: 0.12),
        orbStops: [Color(hex: "FBF9FF"), Color(hex: "E4DBF7"), Color(hex: "C2B2E8"), Color(hex: "9C86CC"), Color(hex: "7E6AB6")],
        orbHalo: Color(hex: "B8A6E6", opacity: 0.85), orbBloom: Color(hex: "B8A6E6", opacity: 0.5)
    )

    /// The orb's solid core gradient (radial, pearl highlight -> deep iris).
    func orbGradient() -> RadialGradient {
        RadialGradient(
            colors: orbStops,
            center: isDark ? UnitPoint(x: 0.38, y: 0.32) : UnitPoint(x: 0.36, y: 0.30),
            startRadius: 1, endRadius: 120
        )
    }
}

// MARK: - Environment plumbing

private struct PaletteKey: EnvironmentKey {
    static let defaultValue: Palette = .light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Inject a palette and force the matching colour scheme so system controls
    /// (keyboard, selection) match Artemis's day / moonlit look.
    func artemisPalette(_ palette: Palette) -> some View {
        environment(\.palette, palette)
            .preferredColorScheme(palette.isDark ? .dark : .light)
            .tint(palette.sage600)
    }
}
