//  ArtemisApp.swift
//  Entry point. Builds the SwiftData container and the engine, resolves the
//  moonlit palette (auto: follows system appearance and switches after dark),
//  and routes between onboarding and the conversation.

import SwiftUI
import SwiftData
import UIKit

@main
struct ArtemisApp: App {
    let container = Store.makeContainer()

    var body: some Scene {
        WindowGroup {
            RootView(container: container)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    let container: ModelContainer
    @State private var engine: ConversationEngine
    @State private var entitlements: Entitlements
    @State private var didStart = false
    @State private var now = Date()
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase

    private let clock = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

    init(container: ModelContainer) {
        self.container = container
        let store = Store(context: container.mainContext)
        let ent = Entitlements()
        _entitlements = State(initialValue: ent)
        _engine = State(initialValue: ConversationEngine(store: store, entitlements: ent))
    }

    private var forcedMoonlit: Bool { ProcessInfo.processInfo.environment["ARTEMIS_MOONLIT"] == "1" }

    /// Right-to-left for Arabic and Urdu. profileRev ties this to profile changes.
    private var isRTL: Bool {
        _ = engine.profileRev
        return ["Arabic", "Urdu"].contains(engine.store.profile()?.language ?? "English")
    }

    /// Auto dark mode follows the SYSTEM appearance, with a manual override.
    private var palette: Palette {
        _ = engine.profileRev   // re-render when the override changes
        if forcedMoonlit { return .dark }
        switch engine.store.profile()?.appearanceOverride {
        case "Light": return .light
        case "Dark":  return .dark
        default:      return systemScheme == .dark ? .dark : .light   // System
        }
    }

    var body: some View {
        ZStack {
            palette.bg.ignoresSafeArea()
            ArtemisCanvas().ignoresSafeArea()

            if engine.onboarded {
                ArtemisRootScreens()
                    .environment(engine)
            } else {
                OnboardingView(onDone: { profile in
                    engine.finishOnboarding(profile)
                }, initial: engine.store.profile())   // pre-filled when re-running from Settings
            }
        }
        .artemisPalette(palette)
        .environment(entitlements)
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
        .onReceive(clock) { now = $0 }
        .task {
            entitlements.configure()
            await runDemoIfRequested()
            if engine.onboarded, !didStart {
                didStart = true
                await engine.startSession()
            }
        }
    }

    /// A simple drawn flower image, so the image (vision) path can be demoed.
    private static func testFlowerJPEG() -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300))
        let img = r.image { ctx in
            UIColor(red: 0.92, green: 0.94, blue: 1, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            for x in [CGFloat(90), 200, 310] {
                UIColor(red: 0.24, green: 0.55, blue: 0.27, alpha: 1).setFill()
                ctx.fill(CGRect(x: x - 4, y: 150, width: 8, height: 110))
                UIColor(red: 0.86, green: 0.27, blue: 0.47, alpha: 1).setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: x - 30, y: 90, width: 60, height: 70))
            }
        }
        return img.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// QA / demo hook driven by launch env vars. Never runs in normal use.
    /// ARTEMIS_DEMO = home | triage | checkin | crisis | trends | settings | paywall
    private func runDemoIfRequested() async {
        guard let demo = ProcessInfo.processInfo.environment["ARTEMIS_DEMO"], !didStart else { return }
        if !engine.store.hasCompletedOnboarding {
            let lang = ProcessInfo.processInfo.environment["ARTEMIS_LANG"] ?? "English"
            engine.store.saveProfile(UserProfile(name: "Sarah", language: lang))
            engine.store.seedDemoDataIfEmpty()
        }
        engine.onboarded = true
        didStart = true
        // Render-only test of the live caption (no connection needed).
        if demo == "interim" {
            engine.interim = "I have a really bad headache and my vision has gone blurry"
            return
        }
        await engine.startSession()

        // Proof demo: a typed turn to generate response events, then the console.
        if demo == "console" {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            engine.send("I've got a pounding headache and my hands are really puffy and I'm seeing flashing when I stand up")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            engine.view = .settings    // SettingsView opens the console when ARTEMIS_OPEN_CONSOLE=1
            return
        }

        // Chip / result-card demos.
        switch demo {
        case "bpcheck":   engine.submitBPCheck(systolic: 150, diastolic: 100); return
        case "safecheck": engine.submitSafeCheck(ProcessInfo.processInfo.environment["ARTEMIS_SAFE_QUERY"] ?? "ibuprofen"); return
        case "nearest":   engine.findNearestUnitNow(); return
        case "advocacy":  engine.store.seedDemoDataIfEmpty(); engine.buildAdvocacy(); return
        case "interim":   engine.interim = "I have a really bad headache and my vision has gone blurry"; return
        case "image":     engine.send("Is this safe", imageData: Self.testFlowerJPEG()); return
        default: break
        }

        // Navigation demos go straight to the screen.
        switch demo {
        case "trends":   engine.view = .history; return
        case "settings": engine.view = .settings; return
        case "paywall":  engine.view = .history; try? await Task.sleep(nanoseconds: 300_000_000); engine.showPaywall(); return
        default: break
        }

        // Conversational demos: let the realtime greeting settle, then send.
        try? await Task.sleep(nanoseconds: 3_500_000_000)
        if let custom = ProcessInfo.processInfo.environment["ARTEMIS_SEND"], !custom.isEmpty {
            engine.send(custom); return
        }
        switch demo {
        case "triage":   engine.send("I've got a pounding headache and my hands are really puffy and I'm seeing flashing when I stand up")
        case "checkin":  engine.send("I'm okay I think, just a bit tired and my ankles are swollen by the evening, and a little anxious about the scan next week")
        case "crisis":   engine.send("honestly I don't know if I can do this anymore, everyone would be better off without me")
        default: break
        }
    }
}

enum Appearance {
    /// Moonlit when the system is dark, or simply after dark (the 2am signature).
    static func isMoonlit(systemScheme: ColorScheme, date: Date) -> Bool {
        if systemScheme == .dark { return true }
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 20 || hour < 6
    }
}

/// The warm lilac-white (or moonlit) atmosphere wash behind everything.
struct ArtemisCanvas: View {
    @Environment(\.palette) private var p
    var body: some View {
        ZStack {
            if p.isDark {
                RadialGradient(colors: [Color(hex: "241D36"), p.bg.opacity(0)], center: .init(x: 0.5, y: -0.1), startRadius: 0, endRadius: 600)
                RadialGradient(colors: [p.orbHalo.opacity(0.14), p.bg.opacity(0)], center: .init(x: 0.85, y: 1.1), startRadius: 0, endRadius: 500)
            } else {
                RadialGradient(colors: [Color(hex: "FBF8FB"), p.bg.opacity(0)], center: .init(x: 0.5, y: -0.12), startRadius: 0, endRadius: 600)
                RadialGradient(colors: [Color(hex: "9B83C4").opacity(0.10), p.bg.opacity(0)], center: .init(x: 0.06, y: 1.04), startRadius: 0, endRadius: 520)
            }
        }
        .background(p.bg)
    }
}
