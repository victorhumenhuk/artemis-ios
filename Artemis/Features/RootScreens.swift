//  RootScreens.swift
//  Composes the app once onboarding is done: the conversation home, plus the
//  History and Settings screens, with the verdict / advocacy / crisis / paywall
//  sheets slid up over everything.

import SwiftUI

struct ArtemisRootScreens: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    var body: some View {
        ZStack {
            // Fluid, calm cross-dissolve with gentle depth between screens (Headspace/Flow feel).
            Group {
                switch engine.view {
                case .home: ConversationView()
                case .history: HistoryView()
                case .settings: SettingsView()
                }
            }
            .id(engine.view)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .center)),
                removal: .opacity.combined(with: .scale(scale: 1.02, anchor: .center))))

            sheetHost
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: engine.sheet)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: engine.view)
    }

    @ViewBuilder
    private var sheetHost: some View {
        switch engine.sheet {
        case .verdict:
            if let v = engine.verdict {
                VerdictSheetView(result: v, service: engine.verdictService,
                                 onClose: { engine.closeSheet() },
                                 onAdvocacy: { engine.buildAdvocacy() },
                                 onCall: { engine.callUnit() })
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
