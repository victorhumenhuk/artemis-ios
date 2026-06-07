//  Insights.swift
//  Client-side pattern detection over check-ins. Two jobs: give the model a
//  short, honest summary so it can name a genuine recurring pattern out loud,
//  and compute the simple trends the "Your week" screen draws.

import Foundation

struct SymptomTrend: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let days: Int        // out of 7
    let tone: Tone
    enum Tone: String { case calm, urgent, crisis }
}

struct WeekInsights: Equatable {
    var moodSeries: [Int]            // up to 7, oldest -> newest
    var dayLabels: [String]
    var moodLabel: String
    var symptoms: [SymptomTrend]
    var bp: [(day: String, value: String, raised: Bool)]
    var kicks: [(day: String, count: Int, low: Bool)]
    var watching: [String]

    static func == (lhs: WeekInsights, rhs: WeekInsights) -> Bool {
        lhs.moodSeries == rhs.moodSeries && lhs.symptoms == rhs.symptoms && lhs.watching == rhs.watching
    }
}

enum Insights {
    private static let toneByTheme: [String: SymptomTrend.Tone] = [
        "anxiety": .crisis, "anxious": .crisis, "low": .crisis, "depression": .crisis,
        "swelling": .urgent, "bleeding": .urgent, "headache": .urgent, "blood pressure": .urgent, "bp": .urgent,
    ]

    /// A short, factual recap the model reads to decide whether to name a
    /// pattern. Read-only, used by get_recent_checkins.
    static func recentSummary(_ entries: [CheckinEntry], limit: Int = 7) -> [CheckinLog] {
        Array(entries.prefix(limit)).map { $0.asLog }
    }

    /// The one true, gentle pattern to name, or nil if there isn't one. We only
    /// speak up when a theme genuinely recurs (3+ recent days), so it never
    /// feels like noise.
    static func namedPattern(_ entries: [CheckinEntry]) -> String? {
        let recent = Array(entries.prefix(7))
        guard recent.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        for e in recent {
            for t in Set(e.themes.map { $0.lowercased() }) { counts[t, default: 0] += 1 }
        }
        let sorted = counts.filter { $0.value >= 3 }.sorted { $0.value > $1.value }
        guard let top = sorted.first else { return nil }
        let theme = top.key
        let n = top.value
        // A neutral, factual data note. Passed to the model as context so it can
        // raise the pattern in its own words; also shown on the tracking screens.
        // It is never spoken as a stitched reply.
        switch theme {
        case "anxiety", "anxious": return "Anxiety in \(n) of the last \(recent.count) check-ins."
        case "swelling": return "Swelling in \(n) of the last \(recent.count) check-ins."
        case "sleep", "fatigue", "tired": return "Tiredness in \(n) of the last \(recent.count) check-ins."
        default: return "\(theme.capitalized) in \(n) of the last \(recent.count) check-ins."
        }
    }

    static func week(checkins: [CheckinEntry], bp: [BPReading], kicks: [KickSession], days: Int = 7) -> WeekInsights {
        let cal = Calendar.current
        let vitalWin = days <= 7 ? 4 : 14   // free shows a few vitals, premium more
        let ordered = checkins.sorted { $0.date < $1.date }.suffix(days)
        let mood = ordered.map { max(1, min(5, $0.moodScore)) }
        let labels = ordered.map { dayInitial($0.date, cal) }

        // symptom frequency across the week, from themes + physical signals
        var freq: [String: Int] = [:]
        for e in ordered {
            // "mood" is its own card, never a symptom. Strip it before counting.
            let tags = Set((e.themes + e.physicalSignals).map { normalise($0) })
                .filter { !$0.isEmpty && $0 != "mood" }
            for t in tags { freq[t, default: 0] += 1 }
        }
        let symptoms = freq.sorted { $0.value > $1.value }.prefix(4).map { (name, days) in
            SymptomTrend(name: name.capitalized, days: min(7, days), tone: tone(for: name))
        }

        let bpOrdered = bp.sorted { $0.date < $1.date }.suffix(vitalWin)
        let bpRows = bpOrdered.map { (day: dayInitial($0.date, cal), value: $0.display, raised: $0.systolic >= 140 || $0.diastolic >= 90) }
            .enumerated().map { idx, row in (day: row.day, value: row.value, raised: row.raised && idx == bpOrdered.count - 1 ? true : row.raised) }

        let kickOrdered = kicks.sorted { $0.date < $1.date }.suffix(vitalWin)
        let kickRows = kickOrdered.enumerated().map { idx, k in
            (day: dayInitial(k.date, cal), count: k.count, low: idx == kickOrdered.count - 1 && k.count <= 6)
        }

        // watching: flags that recur, plus raised BP
        var watching: [String] = []
        let flagCounts = ordered.flatMap { $0.flagsForFollowup }.reduce(into: [String: Int]()) { $0[normalise($1), default: 0] += 1 }
        if flagCounts.keys.contains(where: { $0.contains("swell") }) { watching.append("swelling") }
        if bpRows.last?.raised == true { watching.append("blood pressure") }

        return WeekInsights(
            moodSeries: Array(mood),
            dayLabels: Array(labels),
            moodLabel: moodLabel(for: mood.last ?? 3),
            symptoms: Array(symptoms),
            bp: Array(bpRows),
            kicks: Array(kickRows),
            watching: watching
        )
    }

    private static func normalise(_ s: String) -> String {
        var t = s.lowercased()
        for w in ["mild ", "a little ", "some ", "at night", "by evening"] { t = t.replacingOccurrences(of: w, with: "") }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.contains("swell") || t.contains("ankle") { return "swelling" }
        if t.contains("tired") || t.contains("fatigue") { return "fatigue" }
        if t.contains("anx") { return "anxiety" }
        if t.contains("heartburn") { return "heartburn" }
        return t
    }

    private static func tone(for name: String) -> SymptomTrend.Tone {
        let n = name.lowercased()
        for (k, v) in toneByTheme where n.contains(k) { return v }
        return .calm
    }

    private static func dayInitial(_ date: Date, _ cal: Calendar) -> String {
        let wd = cal.component(.weekday, from: date) // 1=Sun
        return ["S", "M", "T", "W", "T", "F", "S"][(wd - 1) % 7]
    }

    private static func moodLabel(for score: Int) -> String {
        switch score {
        case ...1: return "A hard day"
        case 2: return "A heavier day"
        case 3: return "Holding steady"
        case 4: return "A brighter day"
        default: return "A good day"
        }
    }
}
