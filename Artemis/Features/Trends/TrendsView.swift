//  TrendsView.swift  (HistoryView)
//  "Your week": mood, symptoms, BP and kicks, computed from stored check-ins.
//  Stored only on device. Safety is never paywalled; deeper history is the
//  cosmetic upsell. Built to the History design.

import SwiftUI

struct HistoryView: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(Entitlements.self) private var entitlements
    @Environment(\.palette) private var p
    @State private var week: WeekInsights?
    @State private var detail: DetailKind?
    @State private var rangeDays = 7   // her chosen history window (7 free; 30/90 premium)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                rangeSelector
                if let week {
                    if !week.watching.isEmpty { watchingFlag(week.watching) }
                    openCard(.mood) { moodCard(week) }
                    openCard(.symptoms) { symptomsCard(week) }
                    HStack(spacing: 14) {
                        openCard(.bp) { bpCard(week) }
                        openCard(.movements) { kicksCard(week) }
                    }
                    if !isPremium { upsell }   // hidden once unlocked
                    privacyLine
                } else {
                    Text("Your check-ins will appear here.")
                        .font(ArtemisFont.sans(15)).foregroundStyle(p.inkMute)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.clear)
        .task {
            recompute()
            if let d = ProcessInfo.processInfo.environment["ARTEMIS_DETAIL"], let k = DetailKind(rawValue: d) { detail = k }
        }
        .overlay {
            if let detail {
                DetailScreen(kind: detail) { self.detail = nil }
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: detail)
    }

    /// Wrap a card so the whole tile opens its detail page.
    private func openCard<C: View>(_ kind: DetailKind, @ViewBuilder _ content: () -> C) -> some View {
        Button { detail = kind } label: { content() }
            .buttonStyle(PressButtonStyle())
    }

    /// Premium unlocks months of history; safety + the 7-day window stay free.
    private var isPremium: Bool { entitlements.isUnlocked(.fullHistory) }

    private func recompute() {
        // Free is always capped at 7 days; premium honours her chosen range.
        let days = isPremium ? rangeDays : 7
        week = Insights.week(
            checkins: engine.store.recentCheckins(limit: max(days * 2, 14)),
            bp: engine.store.recentBP(limit: max(days, 7)),
            kicks: engine.store.recentKicks(limit: max(days, 7)),
            days: days)
    }

    /// A choosable history window. Week is free; Month and 3 Months are premium.
    private var rangeSelector: some View {
        HStack(spacing: 8) {
            ForEach([(7, "Week"), (30, "Month"), (90, "3 Months")], id: \.0) { value, label in
                let locked = value > 7 && !isPremium
                let selected = rangeDays == value
                Button {
                    if locked { engine.showPaywall() }
                    else { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { rangeDays = value }; recompute() }
                } label: {
                    HStack(spacing: 4) {
                        Text(label).font(ArtemisFont.sans(13.5, .semibold))
                        if locked { Icon(name: "lock", size: 11) }
                    }
                    .foregroundStyle(selected ? Color.white : p.inkSoft)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(selected ? p.sage600 : p.surface, in: Capsule())
                    .overlay(Capsule().stroke(p.hairline, lineWidth: selected ? 0 : 1))
                }
                .buttonStyle(PressButtonStyle())
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                GlassIcon(icon: "chevDown") { engine.view = .home }   // chevron rotated visually as back
                Spacer()
                Text("Last \(isPremium ? rangeDays : 7) days").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            Text("Your week").voiceStyle(32, weight: .medium).foregroundStyle(p.ink).padding(.top, 4)
            Text("Everything you told Artemis, gently tracked.")
                .font(ArtemisFont.sans(14.5)).foregroundStyle(p.inkSoft)
        }
        .padding(.top, 6).padding(.bottom, 6)
    }

    private func watchingFlag(_ items: [String]) -> some View {
        HStack(spacing: 12) {
            Icon(name: "bell", size: 20).foregroundStyle(p.urgent)
            Text("Artemis is keeping an eye on your \(items.joined(separator: " and ")) this week.")
                .font(ArtemisFont.sans(14.5, .medium)).foregroundStyle(p.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(p.urgentBg, in: RoundedRectangle(cornerRadius: 18))
    }

    private func moodCard(_ w: WeekInsights) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                cardHead("heart", "Mood", trailing: w.moodLabel)
                MoodRibbon(values: w.moodSeries, labels: w.dayLabels)
                    .frame(height: 120)
            }
        }
    }

    private func symptomsCard(_ w: WeekInsights) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                cardHead("leaf", "Symptoms", trailing: nil)
                ForEach(w.symptoms) { s in
                    HStack(spacing: 12) {
                        Text(s.name).font(ArtemisFont.sans(14.5, .medium)).foregroundStyle(p.ink)
                            .frame(width: 82, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { d in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(d < s.days ? toneColor(s.tone) : p.sage100)
                                    .frame(height: 9)
                                    .opacity(d < s.days ? (0.5 + 0.5 * Double(d) / 6) : 1)
                            }
                        }
                        Text("\(s.days)/7").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func bpCard(_ w: WeekInsights) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                cardHead("drop", "BP", trailing: nil)
                ForEach(Array(w.bp.enumerated()), id: \.offset) { _, b in
                    HStack {
                        Text(b.day).font(ArtemisFont.sans(12.5, .semibold)).foregroundStyle(p.inkMute)
                        Spacer()
                        Text(b.value).font(ArtemisFont.sans(15, .bold)).foregroundStyle(b.raised ? p.urgent : p.ink)
                    }
                }
            }
        }
    }

    private func kicksCard(_ w: WeekInsights) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                cardHead("foot", "Kicks", trailing: nil)
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(Array(w.kicks.enumerated()), id: \.offset) { _, k in
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(k.low ? p.urgent : p.sage300)
                                .frame(height: min(56, max(6, CGFloat(k.count) / 10 * 56)))
                            Text(k.day).font(ArtemisFont.sans(11, .semibold)).foregroundStyle(p.inkMute)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 78)
            }
        }
    }

    private var upsell: some View {
        Button { engine.showPaywall() } label: {
            HStack(spacing: 14) {
                ArtemisMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("See your full history").font(ArtemisFont.sans(16, .bold)).foregroundStyle(.white)
                    Text("Months of trends, partner sharing & more").font(ArtemisFont.sans(13)).foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Icon(name: "chevRight", size: 20).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            // Fixed deep purple in BOTH light and dark, so the white title/subtitle
            // always have strong contrast (the palette sage inverts to light lilac
            // in dark mode, which left white text unreadable).
            .background(LinearGradient(colors: [Color(hex: "6C5796"), Color(hex: "4F4179")], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var privacyLine: some View {
        HStack(spacing: 6) {
            Icon(name: "lock", size: 14)
            Text("Stored only on your phone. Never uploaded.")
        }
        .font(ArtemisFont.sans(12)).foregroundStyle(p.inkMute)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func cardHead(_ icon: String, _ title: String, trailing: String?) -> some View {
        HStack {
            HStack(spacing: 9) {
                Icon(name: icon, size: 19).foregroundStyle(p.sage600)
                Text(title).font(ArtemisFont.sans(16.5, .bold)).foregroundStyle(p.ink)
            }
            Spacer()
            if let trailing { Text(trailing).font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.clay) }
        }
    }

    private func toneColor(_ tone: SymptomTrend.Tone) -> Color {
        switch tone { case .calm: return p.clay; case .urgent: return p.urgent; case .crisis: return p.crisis }
    }
}

// MARK: - Mood ribbon (smooth line + gradient fill)

struct MoodRibbon: View {
    let values: [Int]
    let labels: [String]
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height - 18
            let pad: CGFloat = 6
            let pts = points(in: CGSize(width: w, height: h), pad: pad)
            ZStack {
                if pts.count >= 2 {
                    let line = smoothPath(pts)
                    line.fill(.clear)
                    (line.appending(closing: pts, height: h))
                        .fill(LinearGradient(colors: [p.blush.opacity(0.55), p.sage300.opacity(0.06)],
                                             startPoint: .top, endPoint: .bottom))
                    line.stroke(p.clay, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    ForEach(Array(pts.enumerated()), id: \.offset) { i, pt in
                        Circle().fill(p.surface).overlay(Circle().stroke(p.clay, lineWidth: 2.5))
                            .frame(width: i == pts.count - 1 ? 10 : 7, height: i == pts.count - 1 ? 10 : 7)
                            .position(pt)
                    }
                } else if let pt = pts.first {
                    // A single check-in shows as one dot, so day-one isn't blank.
                    Circle().fill(p.surface).overlay(Circle().stroke(p.clay, lineWidth: 2.5))
                        .frame(width: 11, height: 11).position(pt)
                }
                ForEach(Array(labels.enumerated()), id: \.offset) { i, l in
                    if i < pts.count {
                        Text(l).font(ArtemisFont.sans(11, .semibold)).foregroundStyle(p.inkMute)
                            .position(x: pts[i].x, y: h + 10)
                    }
                }
            }
        }
    }

    private func points(in size: CGSize, pad: CGFloat) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        func y(_ v: Int) -> CGFloat { pad + (size.height - pad * 2) * (1 - CGFloat(v - 1) / 4) }
        if values.count == 1 { return [CGPoint(x: size.width / 2, y: y(values[0]))] }
        let step = (size.width - pad * 2) / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in CGPoint(x: pad + CGFloat(i) * step, y: y(v)) }
    }

    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        path.move(to: pts[0])
        for i in 0..<pts.count - 1 {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

private extension Path {
    func appending(closing pts: [CGPoint], height: CGFloat) -> Path {
        var p = self
        if let last = pts.last, let first = pts.first {
            p.addLine(to: CGPoint(x: last.x, y: height))
            p.addLine(to: CGPoint(x: first.x, y: height))
            p.closeSubpath()
        }
        return p
    }
}
