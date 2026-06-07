//  RootScreens.swift
//  Composes the app once onboarding is done: the conversation home, plus the
//  History and Settings screens, with the verdict / advocacy / crisis / paywall
//  sheets slid up over everything.

import SwiftUI

struct ArtemisRootScreens: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Remembers which screen we came from, so the new screen slides in from the
    // correct side (History is to the left, Settings to the right of Home).
    @State private var lastRank = 1

    private func rank(_ v: AppView) -> Int {
        switch v { case .history: return 0; case .home: return 1; case .settings: return 2 }
    }

    var body: some View {
        ZStack {
            // Directional page slide with depth: the destination glides in from the
            // side it lives on, the old screen parallaxes out and dims (Headspace feel).
            Group {
                switch engine.view {
                case .home: ConversationView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .id(engine.view)
            .transition(pageTransition)

            sheetHost
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: engine.sheet)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.4) : .spring(response: 0.55, dampingFraction: 0.86), value: engine.view)
        .onChange(of: engine.view) { _, new in lastRank = rank(new) }
    }

    /// Slide in from the destination's side, parallax + dim the old screen out.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let forward = rank(engine.view) >= lastRank
        let inEdge: Edge = forward ? .trailing : .leading
        let outEdge: Edge = forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: inEdge)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94, anchor: .center)),
            removal: .move(edge: outEdge)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.94, anchor: .center)))
    }

    @ViewBuilder
    private var sheetHost: some View {
        switch engine.sheet {
        case .verdict:
            if let v = engine.verdict {
                VerdictSheetView(result: v, service: engine.verdictService,
                                 onClose: { engine.closeSheet() },
                                 onAdvocacy: { engine.buildAdvocacy() },
                                 onCall: { engine.callUnit() },
                                 onMaps: { engine.openInMaps() })
            }
        case .advocacy:
            if let a = engine.advocacy {
                AdvocacySheetView(script: a, onClose: { engine.sheet = .verdict })
            }
        case .crisis:
            CrisisSheetView(support: engine.crisis,
                            onClose: { engine.closeSheet() },
                            onCall: { engine.callCrisisLine() })
        case .paywall:
            PaywallView(onClose: { engine.closeSheet() })
        case .none:
            EmptyView()
        }
    }
}
