//  CrisisSupportView.swift
//  The gentle crisis path. No assessment questions, no methods. Samaritans
//  surfaced with a one-tap call, plus the option to keep talking. Never gated.

import SwiftUI

struct CrisisSheetView: View {
    let support: CrisisSupport
    var onClose: () -> Void
    var onCall: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        ArtemisSheet(tint: p.crisisBg, onClose: onClose) {
            VStack(spacing: 14) {
                Icon(name: "heart", size: 28).foregroundStyle(p.crisis)
                    .frame(width: 56, height: 56)
                    .background(p.surface, in: Circle())
                    .shadow(color: Color(hex: "3C3357").opacity(0.1), radius: 10, y: 3)
                    .padding(.top, 6)

                Text(support.spokenResponse)
                    .voiceStyle(21).multilineTextAlignment(.center)
                    .foregroundStyle(p.ink)
                    .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("You can talk to someone right now")
                        .font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(support.lineName).font(ArtemisFont.sans(22, .bold)).foregroundStyle(p.ink)
                            Text(support.sub).font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
                        }
                        Spacer()
                        Text(support.linePhone).font(ArtemisFont.sans(26, .heavy)).foregroundStyle(p.crisis)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 3)

                PillButton(title: "Call \(support.lineName) · \(support.linePhone)", tone: .crisis, icon: "phone", height: 60, action: onCall)

                Button(action: onClose) {
                    Text("I'd rather keep talking to you")
                        .font(ArtemisFont.sans(15.5, .semibold)).foregroundStyle(p.sage800)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.sage300, lineWidth: 1.5))
                }
                .buttonStyle(.plain)

                Text("You can also speak to your midwife, GP or call 111. None of this is ever locked or paid.")
                    .font(ArtemisFont.sans(12)).foregroundStyle(p.inkSoft)
                    .multilineTextAlignment(.center).padding(.horizontal, 8)
            }
            .padding(.horizontal, 24).padding(.top, 6).padding(.bottom, 30)
        }
    }
}
