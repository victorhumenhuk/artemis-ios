//  VerdictCardView.swift
//  The triage verdict, rendered from the structured TriageResult. Every card
//  cites NHS. Urgent and emergency show a one-tap call button. Built to the
//  VerdictSheet design.

import SwiftUI

private struct TierMeta {
    let label: String, icon: String, color: Color, bg: Color
}

struct VerdictSheetView: View {
    let result: TriageResult
    let service: NearestService?
    var onClose: () -> Void
    var onAdvocacy: () -> Void
    var onCall: () -> Void
    @Environment(\.palette) private var p

    private var meta: TierMeta {
        switch result.tier {
        case .reassuring: return TierMeta(label: "Reassuring", icon: "check", color: p.routine, bg: p.routineBg)
        case .selfCare: return TierMeta(label: "Self-care", icon: "leaf", color: p.routine, bg: p.routineBg)
        case .routine: return TierMeta(label: "Routine", icon: "leaf", color: p.routine, bg: p.routineBg)
        case .urgent: return TierMeta(label: "Urgent", icon: "bell", color: p.urgent, bg: p.urgentBg)
        case .emergency: return TierMeta(label: "Emergency", icon: "shield", color: p.emergency, bg: p.emergencyBg)
        }
    }

    var body: some View {
        ArtemisSheet(onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroCard
                    OverlineLabel(text: "What Artemis noticed").padding(.top, 20).padding(.bottom, 10)
                    flags
                    actionCard.padding(.top, 14)
                    NHSCitation(title: result.nhsSourceTitle, url: result.nhsSourceURL, sourceNote: result.sourceNote).padding(.top, 18)
                    if let service { callBlock(service).padding(.top, 12) }
                    advocacyButton.padding(.top, 12)
                    Text("Artemis never diagnoses. She checks NHS guidance and helps you be heard.")
                        .font(ArtemisFont.sans(11.5))
                        .foregroundStyle(p.inkMute)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12).padding(.top, 16)
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var heroCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Icon(name: meta.icon, size: 26).foregroundStyle(.white)
                    .frame(width: 52, height: 52).background(meta.color, in: Circle())
                    .shadow(color: meta.color.opacity(0.33), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(meta.label.uppercased())
                        .font(ArtemisFont.sans(11, .heavy)).tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 4)
                        .background(meta.color, in: Capsule())
                    Text(result.matchedCondition)
                        .font(ArtemisFont.sans(21, .bold)).foregroundStyle(p.ink)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 19).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(meta.bg)

            HStack(alignment: .top, spacing: 12) {
                ArtemisMark(size: 30).padding(.top, 2)
                Text(result.spokenResponse)
                    .voiceStyle(19).foregroundStyle(p.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(p.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color(hex: "3C3357").opacity(p.isDark ? 0.3 : 0.08), radius: 20, y: 10)
    }

    private var flags: some View {
        FlowLayout(spacing: 8) {
            ForEach(result.redFlagsDetected, id: \.self) { flag in
                HStack(spacing: 7) {
                    Circle().fill(meta.color).frame(width: 7, height: 7)
                    Text(flag).font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.ink)
                }
                .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 8)
                .background(p.surface, in: Capsule())
                .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 8, y: 2)
            }
        }
    }

    private var actionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Icon(name: "check", size: 20).foregroundStyle(meta.color).padding(.top, 1)
            Text(result.recommendedAction)
                .font(ArtemisFont.sans(15.5, .medium)).foregroundStyle(p.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 10, y: 2)
    }

    private func callBlock(_ service: NearestService) -> some View {
        VStack(spacing: 6) {
            PillButton(title: "Call \(service.name)", tone: tierTone, icon: "phone", height: 60, action: onCall)
            if let address = service.address, !address.isEmpty {
                Text(address)
                    .font(ArtemisFont.sans(13, .medium)).foregroundStyle(p.ink)
                    .multilineTextAlignment(.center)
            }
            Text("\(service.phone) · \(service.distanceKm > 0 ? String(format: "%.1f km away", service.distanceKm) : "nearest unit")")
                .font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkSoft)
        }
    }

    private var tierTone: PillButton.Tone {
        switch result.tier { case .emergency: return .emergency; case .urgent: return .urgent; case .routine, .selfCare, .reassuring: return .routine }
    }

    private var advocacyButton: some View {
        Button(action: onAdvocacy) {
            HStack(spacing: 9) {
                Icon(name: "sparkle", size: 19)
                Text("Turn this into a script for my midwife").font(ArtemisFont.sans(16, .semibold))
            }
            .foregroundStyle(p.lilac700)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(p.lilac50, in: Capsule())
            .overlay(Capsule().stroke(p.lilac300, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// Simple wrapping flow layout for the flag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.minX + maxW { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
