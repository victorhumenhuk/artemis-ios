//  PaywallView.swift
//  Cosmetic freemium. Safety is free forever and never gated. Built to the
//  PaywallSheet design. Prices shown: £8.99/mo or £49.99/yr, 7-day trial.

import SwiftUI

struct PaywallView: View {
    var onClose: () -> Void
    @State private var yearly = true
    @Environment(\.palette) private var p
    @Environment(Entitlements.self) private var entitlements

    private let plusFeatures = ["Full symptom & mood history", "Kick & blood-pressure tracking",
                                "Share with your partner", "Voice in every language"]

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.92, onClose: onClose) {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 2) {
                        ArtemisMark(size: 44)
                        HStack(spacing: 6) {
                            Text("Artemis").voiceStyle(31, weight: .medium).foregroundStyle(p.ink)
                            Text("Plus").voiceStyle(31, weight: .medium).foregroundStyle(p.sage600)
                        }
                        Text("Deeper tracking, for the long road ahead.")
                            .font(ArtemisFont.sans(14.5)).foregroundStyle(p.inkSoft)
                    }
                    .padding(.top, 6)

                    // safety reassurance
                    HStack(spacing: 12) {
                        Icon(name: "heart", size: 22).foregroundStyle(p.clay)
                        Text("Triage, signposting and your advocacy script are free forever. Safety is never paywalled.")
                            .font(ArtemisFont.sans(14.5, .medium)).foregroundStyle(p.ink)
                    }
                    .padding(16)
                    .background(p.blushSoft, in: RoundedRectangle(cornerRadius: 18))

                    // plus features
                    VStack(spacing: 0) {
                        ForEach(Array(plusFeatures.enumerated()), id: \.offset) { i, f in
                            HStack(spacing: 12) {
                                Icon(name: "check", size: 15).foregroundStyle(.white)
                                    .frame(width: 24, height: 24).background(p.sage600, in: Circle())
                                Text(f).font(ArtemisFont.sans(15.5, .medium)).foregroundStyle(p.ink)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            if i < plusFeatures.count - 1 { Divider().overlay(p.hairline2) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 3)

                    HStack(spacing: 10) {
                        planCard(isYearly: true, title: "Yearly", price: "£49.99", sub: "£4.16 / mo", save: "Save 54%")
                        planCard(isYearly: false, title: "Monthly", price: "£8.99", sub: "per month", save: nil)
                    }

                    PillButton(title: "Start 7-day free trial", tone: .sage, height: 58) {
                        entitlements.showPaywall() // RevenueCat purchase flow hook (cosmetic in MVP)
                    }
                    Text("No account needed. Cancel anytime. Health & Fitness, not Medical.")
                        .font(ArtemisFont.sans(12)).foregroundStyle(p.inkMute)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func planCard(isYearly: Bool, title: String, price: String, sub: String, save: String?) -> some View {
        Button { yearly = isYearly } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ArtemisFont.sans(14, .semibold)).foregroundStyle(p.inkSoft)
                Text(price).font(ArtemisFont.sans(24, .heavy)).foregroundStyle(p.ink)
                Text(sub).font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(yearly == isYearly ? p.sage100 : p.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(yearly == isYearly ? p.sage600 : p.hairline, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if let save {
                    Text(save).font(ArtemisFont.sans(10.5, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(p.sage600, in: Capsule())
                        .offset(x: -10, y: -10)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
