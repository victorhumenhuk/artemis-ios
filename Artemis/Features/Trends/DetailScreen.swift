//  DetailScreen.swift
//  Each card on "Your week" opens its own detail page: Mood, Symptoms, Blood
//  pressure, Movements. Built to the Detail Cards design, from stored data.

import SwiftUI

enum DetailKind: String, Identifiable {
    case mood, symptoms, bp, movements
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mood: return "Mood"; case .symptoms: return "Symptoms"
        case .bp: return "Blood pressure"; case .movements: return "Movements"
        }
    }
    var icon: String {
        switch self {
        case .mood: return "heart"; case .symptoms: return "leaf"
        case .bp: return "drop"; case .movements: return "foot"
        }
    }
}

struct DetailScreen: View {
    let kind: DetailKind
    var onBack: () -> Void
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    private var week: WeekInsights {
        Insights.week(checkins: engine.store.recentCheckins(limit: 14),
                      bp: engine.store.recentBP(limit: 7),
                      kicks: engine.store.recentKicks(limit: 7))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch kind {
                    case .mood: moodBody
                    case .symptoms: symptomsBody
                    case .bp: bpBody
                    case .movements: movementsBody
                    }
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ArtemisCanvas().ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            GlassIcon(icon: "chevDown") { onBack() }
                .rotationEffect(.degrees(90))
            HStack(spacing: 8) {
                Icon(name: kind.icon, size: 18).foregroundStyle(p.sage600)
                Text(kind.title).font(ArtemisFont.sans(18, .bold)).foregroundStyle(p.ink)
            }
            Spacer()
            Text("Last 7 days").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 10)
    }

    private func reflection(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ArtemisMark(size: 28).padding(.top, 2)
            Text(text).voiceStyle(16.5).foregroundStyle(p.ink)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color(hex: "3C3357").opacity(0.07), radius: 12, y: 3)
    }

    // MARK: Mood

    private var moodBody: some View {
        let mood = week.moodSeries
        let avg = mood.isEmpty ? 0 : Double(mood.reduce(0, +)) / Double(mood.count)
        let brighter = mood.filter { $0 >= 4 }.count
        let recent = engine.store.recentCheckins(limit: 7)
        return Group {
            Card { MoodRibbon(values: mood, labels: week.dayLabels).frame(height: 120) }
            HStack(spacing: 14) {
                statTile(value: String(format: "%.1f", avg), unit: "/5", label: "Average mood", sub: "Gently up over the week")
                statTile(value: "\(brighter)", unit: brighter == 1 ? "day" : "days", label: "Brighter days", sub: "The lighter days lifted you")
            }
            reflection(Insights.namedPattern(recent) ?? "Your mood moved with how your body felt this week. Be kind to yourself, that is the most normal thing in the world.")
            OverlineLabel(text: "Day by day").padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(recent.prefix(7).enumerated()), id: \.offset) { i, e in
                    dayRow(e)
                    if i < min(6, recent.count - 1) { Divider().overlay(p.hairline2) }
                }
            }
            .padding(.horizontal, 16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(hex: "3C3357").opacity(0.07), radius: 12, y: 3)
        }
    }

    private func dayRow(_ e: CheckinEntry) -> some View {
        let f = DateFormatter(); f.dateFormat = "EEE"
        let label = e.moodScore >= 4 ? "A lighter day" : (e.moodScore <= 2 ? "A heavier day" : "Holding steady")
        return HStack(alignment: .top, spacing: 12) {
            Text(f.string(from: e.date)).font(ArtemisFont.sans(12.5, .semibold)).foregroundStyle(p.inkMute)
                .frame(width: 34, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(ArtemisFont.sans(15, .semibold)).foregroundStyle(p.ink)
                Text(e.reflectionSummary.isEmpty ? e.summaryLine : e.reflectionSummary)
                    .font(ArtemisFont.sans(13.5)).foregroundStyle(p.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
    }

    private func statTile(value: String, unit: String, label: String, sub: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).voiceStyle(34, weight: .medium).foregroundStyle(p.sage700)
                    Text(unit).font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
                }
                Text(label).font(ArtemisFont.sans(15, .bold)).foregroundStyle(p.ink)
                Text(sub).font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Symptoms

    private var symptomsBody: some View {
        let syms = week.symptoms
        let top = syms.first
        return Group {
            if let top {
                HStack(alignment: .top, spacing: 10) {
                    Icon(name: "leaf", size: 17).foregroundStyle(p.sage600).padding(.top, 2)
                    Text("\(top.name) is your most frequent symptom this week, \(top.days) of 7 days.\(top.tone == .urgent ? " Artemis is watching it with your blood pressure." : "")")
                        .font(ArtemisFont.sans(14.5, .medium)).foregroundStyle(p.ink)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 2)
            }
            ForEach(syms) { s in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(s.name).font(ArtemisFont.sans(16.5, .bold)).foregroundStyle(p.ink)
                            Spacer()
                            Text("\(s.days)/7 days").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkMute)
                        }
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { d in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(d < s.days ? toneColor(s.tone) : p.sage100)
                                    .frame(height: 9)
                                    .opacity(d < s.days ? (0.5 + 0.5 * Double(d) / 6) : 1)
                            }
                        }
                        Text(note(for: s.name)).font(ArtemisFont.sans(13.5)).foregroundStyle(p.inkSoft)
                    }
                }
            }
        }
    }

    private func note(for name: String) -> String {
        switch name.lowercased() {
        case "swelling": return "Worse in the evenings and in both ankles. Artemis is watching this alongside your blood pressure."
        case "anxiety": return "Mostly around appointments and the upcoming scan. It eased after talking it through."
        case "sleep": return "Broken sleep earlier in the week, mainly from heartburn and getting comfortable."
        case "fatigue": return "Some tiredness through the week. Gentle rest where you can."
        case "heartburn": return "Worse at night. Smaller meals and propping up can help."
        default: return "Noted across the week, so you can mention it at your next appointment."
        }
    }

    // MARK: Blood pressure

    private var bpBody: some View {
        let bp = engine.store.recentBP(limit: 7).sorted { $0.date < $1.date }
        let latest = bp.last
        let raised = latest.map { $0.systolic >= 140 || $0.diastolic >= 90 } ?? false
        let f = DateFormatter(); f.dateFormat = "EEE"
        return Group {
            if let latest {
                VStack(spacing: 4) {
                    Text(latest.display).voiceStyle(44, weight: .medium).foregroundStyle(raised ? p.emergency : p.ink)
                    Text("Latest reading, \(f.string(from: latest.date))").font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.ink)
                    Text("At or above 140/90, this should be checked").font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkSoft)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(raised ? p.emergencyBg : p.surface, in: RoundedRectangle(cornerRadius: 22))
            }
            Card { BPChart(readings: bp).frame(height: 140) }
            OverlineLabel(text: "Every reading").padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(bp.reversed().enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text(f.string(from: r.date)).font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.inkMute)
                            .frame(width: 44, alignment: .leading)
                        Text(r.display).font(ArtemisFont.sans(16, .bold)).foregroundStyle(p.ink)
                        Spacer()
                        bpTag(r)
                    }
                    .padding(.vertical, 12)
                    if i < bp.count - 1 { Divider().overlay(p.hairline2) }
                }
            }
            .padding(.horizontal, 16)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(hex: "3C3357").opacity(0.07), radius: 12, y: 3)
            reflection("Your blood pressure has climbed over the last few days. That is worth a call to your maternity unit so they can check you and your baby.")
        }
    }

    @ViewBuilder private func bpTag(_ r: BPReading) -> some View {
        let high = r.systolic >= 140 || r.diastolic >= 90
        let raised = r.systolic >= 135 || r.diastolic >= 85
        if high {
            tag("High", p.emergency, p.emergencyBg)
        } else if raised {
            tag("Raised", p.urgent, p.urgentBg)
        } else {
            tag("Normal", p.routine, p.routineBg)
        }
    }
    private func tag(_ s: String, _ c: Color, _ bg: Color) -> some View {
        Text(s).font(ArtemisFont.sans(11.5, .bold)).foregroundStyle(c)
            .padding(.horizontal, 9).padding(.vertical, 3).background(bg, in: Capsule())
    }

    // MARK: Movements

    private var movementsBody: some View {
        let kicks = engine.store.recentKicks(limit: 7).sorted { $0.date < $1.date }
        let today = kicks.last?.count ?? 0
        let first = kicks.first?.count ?? 0
        let down = today < first
        return Group {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(today)").voiceStyle(44, weight: .medium).foregroundStyle(down ? p.emergency : p.ink)
                    Text("today").font(ArtemisFont.sans(15, .semibold)).foregroundStyle(p.inkSoft)
                }
                Text("Movements counted").font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.ink)
                if down { Text("Down from \(first) on \(firstDay(kicks))").font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkSoft) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 18)
            .background(down ? p.emergencyBg : p.surface, in: RoundedRectangle(cornerRadius: 22))

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("This week").font(ArtemisFont.sans(15, .bold)).foregroundStyle(p.ink)
                        Spacer()
                        if down { Text("Trending down").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.emergency) }
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(Array(kicks.enumerated()), id: \.offset) { i, k in
                            let last = i == kicks.count - 1
                            VStack(spacing: 5) {
                                Text("\(k.count)").font(ArtemisFont.sans(11, .semibold)).foregroundStyle(p.inkMute)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(last && down ? p.emergency : p.sage300)
                                    .frame(height: max(8, CGFloat(k.count) / 10 * 70))
                                Text(dayInitial(k.date)).font(ArtemisFont.sans(11, .semibold)).foregroundStyle(p.inkMute)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 110)
                }
            }
            reflection("You know your baby's normal pattern best. Movements have dropped each day this week, and a reduction is always worth checking the same day. It is never a waste of anyone's time.")
            NHSCitation(title: "Your baby's movements", url: "https://www.nhs.uk/pregnancy/keeping-well/your-babys-movements/")
            PillButton(title: "Call your maternity unit", tone: .emergency, icon: "phone", height: 58) {
                engine.callNearestMaternityUnit()
            }
        }
    }

    private func firstDay(_ kicks: [KickSession]) -> String {
        guard let d = kicks.first?.date else { return "earlier" }
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: d)
    }
    private func dayInitial(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: date)
    }
    private func toneColor(_ tone: SymptomTrend.Tone) -> Color {
        switch tone { case .calm: return p.clay; case .urgent: return p.urgent; case .crisis: return p.crisis }
    }
}

// Dual-line systolic / diastolic chart.
struct BPChart: View {
    let readings: [BPReading]
    @Environment(\.palette) private var p

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height - 18, pad: CGFloat = 8
            let sys = readings.map { Double($0.systolic) }
            let dia = readings.map { Double($0.diastolic) }
            let allVals = sys + dia
            let lo = (allVals.min() ?? 70) - 8, hi = (allVals.max() ?? 160) + 8
            ZStack {
                line(values: sys, color: p.emergency, w: w, h: h, pad: pad, lo: lo, hi: hi)
                line(values: dia, color: p.sage500, w: w, h: h, pad: pad, lo: lo, hi: hi)
                HStack(spacing: 16) {
                    legend(p.emergency, "Systolic"); legend(p.sage500, "Diastolic")
                }
                .position(x: w / 2, y: h + 10)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 7, height: 7); Text(t).font(ArtemisFont.sans(11, .semibold)).foregroundStyle(p.inkMute) }
    }

    @ViewBuilder private func line(values: [Double], color: Color, w: CGFloat, h: CGFloat, pad: CGFloat, lo: Double, hi: Double) -> some View {
        if values.count > 1 {
            let step = (w - pad * 2) / CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v -> CGPoint in
                CGPoint(x: pad + CGFloat(i) * step, y: pad + (h - pad * 2) * (1 - CGFloat((v - lo) / (hi - lo))))
            }
            Path { path in
                path.move(to: pts[0])
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }.stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
                Circle().fill(p.surface).overlay(Circle().stroke(color, lineWidth: 2.5))
                    .frame(width: 7, height: 7).position(pt)
            }
        } else if let v = values.first {
            // A single reading shows as one dot, so the card isn't blank on day one.
            let yy = pad + (h - pad * 2) * (1 - CGFloat((v - lo) / (hi - lo)))
            Circle().fill(p.surface).overlay(Circle().stroke(color, lineWidth: 2.5))
                .frame(width: 8, height: 8).position(x: w / 2, y: yy)
        }
    }
}
