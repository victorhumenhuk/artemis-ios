//  Store.swift
//  Thin wrapper over the SwiftData ModelContext. Everything stays on device.

import Foundation
import SwiftData

@MainActor
final class Store {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Save and LOG on failure, so a disk/iCloud write error is never swallowed
    /// silently (which would lose her check-ins without warning).
    private func persist() {
        do { try context.save() }
        catch { ArtemisLog.error("Store: save failed, data may not persist: \(error)") }
    }

    // MARK: Profile

    func profile() -> UserProfile? {
        (try? context.fetch(FetchDescriptor<UserProfile>()))?.first
    }

    func saveProfile(_ profile: UserProfile) {
        // single-profile app: clear any existing first
        if let existing = try? context.fetch(FetchDescriptor<UserProfile>()) {
            existing.forEach { context.delete($0) }
        }
        context.insert(profile)
        persist()
    }

    var hasCompletedOnboarding: Bool { profile() != nil }

    // MARK: Check-ins

    func recentCheckins(limit: Int = 14) -> [CheckinEntry] {
        var d = FetchDescriptor<CheckinEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    @discardableResult
    func addCheckin(_ log: CheckinLog, transcript: String = "") -> CheckinEntry {
        let entry = CheckinEntry(log: log, rawTranscript: transcript)
        context.insert(entry)
        persist()
        return entry
    }

    // MARK: Symptom verdicts

    func addSymptom(_ result: TriageResult) {
        context.insert(SymptomEntry(result: result))
        persist()
    }

    func recentSymptoms(limit: Int = 30) -> [SymptomEntry] {
        var d = FetchDescriptor<SymptomEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    // MARK: Vitals

    func addBP(systolic: Int, diastolic: Int) {
        context.insert(BPReading(systolic: systolic, diastolic: diastolic))
        persist()
    }

    func recentBP(limit: Int = 7) -> [BPReading] {
        var d = FetchDescriptor<BPReading>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    func addKick(count: Int, minutes: Int = 0) {
        context.insert(KickSession(count: count, durationMinutes: minutes))
        persist()
    }

    func recentKicks(limit: Int = 7) -> [KickSession] {
        var d = FetchDescriptor<KickSession>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    // MARK: Chat thread (persists across launches, same store as memory)

    func recentThread(limit: Int = 200) -> [ChatTurn] {
        var d = FetchDescriptor<ChatTurn>(sortBy: [SortDescriptor(\.date, order: .forward)])
        d.fetchLimit = limit
        return (try? context.fetch(d)) ?? []
    }

    func addChatTurn(role: String, text: String, imageData: Data? = nil) {
        context.insert(ChatTurn(role: role, text: text, imageData: imageData))
        persist()
    }

    func clearThread() {
        for t in recentThread(limit: 100000) { context.delete(t) }
        persist()
    }

    // MARK: Memory (what Artemis remembers) — derived from the same store

    struct Memory {
        var stage: String
        var weeks: Int
        var recurringThemes: [(String, Int)]
        var concerns: [String]
        var watching: [String]
        var moodTrend: [Int]
    }

    func memory() -> Memory {
        // Long-term: her history is never purged, so memory compounds. (The
        // 7-day refresh applies only to the NHS content cache, never to her data.)
        let checkins = recentCheckins(limit: 5000)
        var themeCounts: [String: Int] = [:]
        for c in checkins { for t in Set(c.themes.map { $0.lowercased() }) { themeCounts[t, default: 0] += 1 } }
        let themes = themeCounts.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
        let concerns = Array(Set(checkins.flatMap { $0.concerns })).prefix(6).map { $0 }
        let watching = Array(Set(checkins.flatMap { $0.flagsForFollowup })).prefix(4).map { $0 }
        let mood = checkins.sorted { $0.date < $1.date }.suffix(7).map { $0.moodScore }
        let p = profile()
        return Memory(stage: p?.stageEnum.label ?? "Pregnant", weeks: p?.weeks ?? 0,
                      recurringThemes: Array(themes), concerns: Array(concerns),
                      watching: Array(watching), moodTrend: Array(mood))
    }

    /// A compact memory block passed to the model as context each session, so
    /// Artemis genuinely recalls and reflects it back in her own words.
    func memoryContext() -> String? {
        let m = memory()
        var lines: [String] = []
        lines.append("Stage: \(m.stage)\(m.weeks > 0 ? ", \(m.weeks) weeks" : "").")
        if !m.recurringThemes.isEmpty {
            lines.append("Recurring themes: " + m.recurringThemes.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + ".")
        }
        if !m.concerns.isEmpty { lines.append("Worries she has raised: " + m.concerns.joined(separator: "; ") + ".") }
        if !m.watching.isEmpty { lines.append("Worth keeping an eye on: " + m.watching.joined(separator: ", ") + ".") }
        guard lines.count > 1 else { return nil }
        return "Background from PAST conversations, for warmth and continuity only. Do not assess, advise on, or escalate from any of this, and never raise a past symptom unless she brings it up now:\n" + lines.joined(separator: "\n")
    }

    // MARK: Data controls (shown in Settings)

    /// "Export my check-in log" — a plain, human-readable text export.
    func exportCheckinsText() -> String {
        let f = DateFormatter(); f.dateStyle = .medium
        var out = "Artemis check-in log\nStored only on your phone.\n\n"
        for c in recentCheckins(limit: 365).reversed() {
            out += "\(f.string(from: c.date))\n"
            out += "Mood: \(c.moodScore) of 5\n"
            if !c.physicalSignals.isEmpty { out += "Body: \(c.physicalSignals.joined(separator: ", "))\n" }
            if !c.emotionalSignals.isEmpty { out += "Feelings: \(c.emotionalSignals.joined(separator: ", "))\n" }
            if !c.concerns.isEmpty { out += "Worries: \(c.concerns.joined(separator: ", "))\n" }
            if !c.themes.isEmpty { out += "Themes: \(c.themes.joined(separator: ", "))\n" }
            out += "\(c.summaryLine)\n\n"
        }
        return out
    }

    /// "Delete everything."
    func deleteEverything() {
        for entry in recentCheckins(limit: 100000) { context.delete(entry) }
        for s in recentSymptoms(limit: 100000) { context.delete(s) }
        for b in recentBP(limit: 100000) { context.delete(b) }
        for k in recentKicks(limit: 100000) { context.delete(k) }
        for t in recentThread(limit: 100000) { context.delete(t) }
        persist()
    }

    // MARK: Demo seed

    /// Seeds a believable week so Trends and the advocacy script are populated
    /// for a first demo. Safe to call repeatedly; only seeds when empty.
    /// Seed a gentle, realistic last-7-days so Your week renders full from day one.
    /// Idempotent: only seeds when there are no check-ins yet. Calm, normal data,
    /// nausea and fatigue easing off, a steady mood, healthy vitals and movements.
    func seedDemoDataIfEmpty() {
        guard recentCheckins(limit: 1).isEmpty else { return }
        let cal = Calendar.current
        let now = Date()
        let days: [(Int, CheckinLog)] = [
            (6, CheckinLog(physicalSignals: ["Nausea", "Tired"], emotionalSignals: ["A bit flat"], concerns: [], themes: ["nausea", "fatigue"], moodScore: 3, reflectionSummary: "Some morning nausea and a tired day.", flagsForFollowup: [], summaryLine: "Nausea and tired.")),
            (5, CheckinLog(physicalSignals: ["Nausea"], emotionalSignals: ["Calm"], concerns: [], themes: ["nausea"], moodScore: 3, reflectionSummary: "Nausea eased after breakfast, a calmer day.", flagsForFollowup: [], summaryLine: "Calmer, mild nausea.")),
            (4, CheckinLog(physicalSignals: ["Tired"], emotionalSignals: ["Content"], concerns: [], themes: ["fatigue"], moodScore: 4, reflectionSummary: "A brighter day, just a little tired by evening.", flagsForFollowup: [], summaryLine: "Brighter, a little tired.")),
            (3, CheckinLog(physicalSignals: ["Tired"], emotionalSignals: ["Steady"], concerns: [], themes: ["fatigue"], moodScore: 4, reflectionSummary: "Steady and well, good energy in the morning.", flagsForFollowup: [], summaryLine: "Steady and well.")),
            (2, CheckinLog(physicalSignals: ["Mild nausea"], emotionalSignals: ["Happy"], concerns: [], themes: ["nausea"], moodScore: 4, reflectionSummary: "A happy day, only a little queasy first thing.", flagsForFollowup: [], summaryLine: "Happy, slightly queasy.")),
            (1, CheckinLog(physicalSignals: ["Tired"], emotionalSignals: ["Hopeful"], concerns: [], themes: ["fatigue"], moodScore: 4, reflectionSummary: "Looking forward to the week, a touch tired.", flagsForFollowup: [], summaryLine: "Hopeful, a touch tired.")),
            (0, CheckinLog(physicalSignals: ["Tired"], emotionalSignals: ["Calm"], concerns: [], themes: ["fatigue"], moodScore: 4, reflectionSummary: "A calm, steady day.", flagsForFollowup: [], summaryLine: "Calm and steady.")),
        ]
        for (ago, log) in days {
            let date = cal.date(byAdding: .day, value: -ago, to: now) ?? now
            context.insert(CheckinEntry(log: log, date: date))
        }
        // Believable, normal blood pressure for pregnancy.
        let bp = [(6, 118, 74), (4, 120, 78), (2, 116, 76), (0, 122, 80)]
        for (ago, s, d) in bp {
            let date = cal.date(byAdding: .day, value: -ago, to: now) ?? now
            context.insert(BPReading(systolic: s, diastolic: d, date: date))
        }
        // Healthy kick counts.
        let kicks = [(6, 11), (4, 10), (2, 12), (0, 10)]
        for (ago, n) in kicks {
            let date = cal.date(byAdding: .day, value: -ago, to: now) ?? now
            context.insert(KickSession(count: n, date: date))
        }
        persist()
    }

    static func makeContainer() -> ModelContainer {
        // On a fresh install the Application Support directory (SwiftData's default
        // store location) may not exist yet, which made CoreData fail + spam errors
        // before it recovered. Create it up front so the store opens cleanly.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        let schema = Schema([UserProfile.self, CheckinEntry.self, SymptomEntry.self, BPReading.self, KickSession.self, ChatTurn.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // A schema change can make the old store unreadable. Rather than silently
            // dropping to in-memory and losing the persistent store on every launch,
            // reset the on-disk store once and retry, so it keeps working afterwards.
            ArtemisLog.error("Store: persistent container failed (\(error)); resetting the on-disk store and retrying.")
            try? FileManager.default.removeItem(at: config.url)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                ArtemisLog.error("Store: persistent reset also failed (\(error)); falling back to in-memory.")
                let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                do {
                    return try ModelContainer(for: schema, configurations: [mem])
                } catch {
                    fatalError("Artemis could not create a data store (even in memory): \(error)")
                }
            }
        }
    }
}
