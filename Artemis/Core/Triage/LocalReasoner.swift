//  LocalReasoner.swift
//  Artemis's brain when there is no live model: it drives the SAME ToolDispatcher
//  the realtime model would, so typed input and offline voice produce identical
//  results to the spoken path. Intent is inferred from what she says, never from
//  a button. When Apple Foundation Models is available it organises check-ins;
//  otherwise a careful heuristic does.

import Foundation

enum LocalOutcome {
    case triage                         // verdict delivered via ToolDispatcherDelegate
    case checkin(spoken: String)
    case crisis(CrisisSupport)
    case chat(spoken: String)
}

@MainActor
final class LocalReasoner {
    private let store: Store
    private let dispatcher: ToolDispatcher

    init(store: Store, dispatcher: ToolDispatcher) {
        self.store = store
        self.dispatcher = dispatcher
    }

    func handle(_ text: String) async -> LocalOutcome {
        let lower = text.lowercased()

        // 1. Crisis always first, and gently.
        if isCrisis(lower) {
            return .crisis(.default)
        }

        // 2. Serious symptoms always triage.
        let hit = RedFlagIndex.shared.match(text)
        if let hit, hit.defaultTier != .routine {
            await runTriage(query: text, topics: [hit.id, hit.condition])
            return .triage
        }

        // 3. A reflective braindump is a check-in.
        if looksLikeCheckin(lower) && !(hit != nil && isQuestion(lower)) {
            return await runCheckin(text)
        }

        // 4. A direct routine symptom question still triages.
        if let hit {
            await runTriage(query: text, topics: [hit.id, hit.condition])
            return .triage
        }

        // 5. Otherwise treat it as a gentle check-in / chat.
        if looksLikeCheckin(lower) {
            return await runCheckin(text)
        }
        return .chat(spoken: gentleReply(for: lower))
    }

    // MARK: flows

    private func runTriage(query: String, topics: [String]) async {
        _ = await dispatcher.dispatch(name: ArtemisTool.retrieveNHSGuidance.rawValue,
                                      argumentsJSON: encode(["query": query, "suspected_topics": topics]))
        // Empty args: the dispatcher grounds the verdict from the retrieved guidance.
        _ = await dispatcher.dispatch(name: ArtemisTool.assessSymptoms.rawValue, argumentsJSON: "{}")
    }

    private func runCheckin(_ text: String) async -> LocalOutcome {
        _ = await dispatcher.dispatch(name: ArtemisTool.getRecentCheckins.rawValue, argumentsJSON: encode(["limit": 7]))

        let (log, fromModel) = await organise(text)
        _ = await dispatcher.dispatch(name: ArtemisTool.logCheckin.rawValue, argumentsJSON: encodeLog(log))

        if fromModel {
            // Genuine on-device model output (Foundation Models), not a template.
            return .checkin(spoken: log.reflectionSummary)
        }
        // No model available offline: be honest, never fabricate a reflection.
        return .checkin(spoken: "I've saved how you're feeling. While we're offline I can't talk it through properly, but it's noted. If anything is worrying you, please contact your maternity unit or call 111.")
    }

    /// Foundation Models (real on-device generation) if available, else the
    /// heuristic structurer for the log only. The Bool is true when a model wrote it.
    private func organise(_ text: String) async -> (CheckinLog, Bool) {
        if let fm = await OnDeviceOrganizer.organiseCheckin(text) {
            return (fm, true)
        }
        return (HeuristicOrganizer.organise(text), false)
    }

    // MARK: intent heuristics

    private func isCrisis(_ t: String) -> Bool {
        let patterns = ["better off without", "can't do this", "cant do this", "can't go on",
                        "end it all", "kill myself", "don't want to be here", "dont want to be here",
                        "don't want to live", "hurt myself", "harm myself", "harm my baby",
                        "better off dead", "no point", "want to disappear", "can't cope anymore"]
        return patterns.contains { t.contains($0) }
    }

    private func looksLikeCheckin(_ t: String) -> Bool {
        let feeling = ["feel", "feeling", "mood", "in myself", "okay", "ok", "fine", "tired",
                       "anxious", "worried", "happy", "sad", "low", "overwhelmed", "stressed",
                       "calm", "hopeful", "exhausted", "lonely", "scared", "today", "lately"]
        return feeling.contains { t.contains($0) }
    }

    private func isQuestion(_ t: String) -> Bool {
        t.contains("?") || t.contains("should i") || t.contains("is this normal") || t.contains("do i need")
    }

    private func gentleReply(for t: String) -> String {
        if t.contains("hello") || t.contains("hi ") || t.hasPrefix("hi") || t.contains("hey") {
            return "Hi, I'm Artemis. How are you feeling today?"
        }
        if t.contains("thank") { return "Anytime. I'm here whenever you need me." }
        return "I'm listening. Tell me a little more about how you're feeling, or what's on your mind."
    }

    private func encode(_ dict: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    private func encodeLog(_ log: CheckinLog) -> String {
        (try? JSONEncoder().encode(log)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

// MARK: - Heuristic check-in organiser (offline, no model)
//
// Turns a rambling braindump into short, canonical, categorised signals, never
// a verbatim transcript. Each rule maps keywords to one clean label.

enum HeuristicOrganizer {
    private struct Rule { let keys: [String]; let label: String; let theme: String; let positive: Bool? }

    // physical signals
    private static let physicalRules: [Rule] = [
        Rule(keys: ["swollen", "swelling", "ankle", "puffy feet", "puffy ankles"], label: "Ankle swelling", theme: "swelling", positive: nil),
        Rule(keys: ["tired", "exhausted", "shattered", "no energy", "worn out"], label: "Tired", theme: "fatigue", positive: false),
        Rule(keys: ["heartburn", "reflux", "indigestion", "acid"], label: "Heartburn", theme: "heartburn", positive: nil),
        Rule(keys: ["can't sleep", "cant sleep", "not sleeping", "trouble sleeping", "awake all night"], label: "Trouble sleeping", theme: "sleep", positive: false),
        Rule(keys: ["headache", "head is pounding", "head hurts"], label: "Headache", theme: "headache", positive: false),
        Rule(keys: ["sick", "nausea", "nauseous", "queasy", "throwing up", "vomit"], label: "Nausea", theme: "nausea", positive: false),
        Rule(keys: ["back ache", "backache", "back pain", "sore back"], label: "Backache", theme: "back", positive: false),
        Rule(keys: ["cramp", "tightening"], label: "Cramping", theme: "cramps", positive: false),
        Rule(keys: ["kick", "movement", "baby moving"], label: "Baby's movements", theme: "movements", positive: nil),
        Rule(keys: ["dizzy", "lightheaded", "light-headed"], label: "Dizziness", theme: "dizziness", positive: false),
    ]
    // emotional signals
    private static let emotionalRules: [Rule] = [
        Rule(keys: ["anxious", "anxiety", "on edge", "worried", "worry", "nervous"], label: "Anxious", theme: "anxiety", positive: false),
        Rule(keys: ["scared", "afraid", "frightened"], label: "Scared", theme: "anxiety", positive: false),
        Rule(keys: ["low", "down", "flat", "sad", "tearful", "crying"], label: "Low mood", theme: "low mood", positive: false),
        Rule(keys: ["overwhelmed", "too much", "can't cope", "cant cope"], label: "Overwhelmed", theme: "overwhelm", positive: false),
        Rule(keys: ["lonely", "alone"], label: "Lonely", theme: "loneliness", positive: false),
        Rule(keys: ["stressed", "stress"], label: "Stressed", theme: "stress", positive: false),
        Rule(keys: ["calm", "settled", "peaceful"], label: "Calm", theme: "calm", positive: true),
        Rule(keys: ["hopeful", "excited", "looking forward"], label: "Hopeful", theme: "hopeful", positive: true),
        Rule(keys: ["okay", "ok", "fine", "alright", "not bad", "good"], label: "Holding steady", theme: "steady", positive: true),
    ]

    static func organise(_ text: String) -> CheckinLog {
        let lower = text.lowercased()
        var phys: [String] = [], emo: [String] = [], themes: [String] = []
        var mood = 3

        for r in physicalRules where r.keys.contains(where: { lower.contains($0) }) {
            phys.append(r.label); themes.append(r.theme)
            if r.positive == false { mood -= 1 } else if r.positive == true { mood += 1 }
        }
        for r in emotionalRules where r.keys.contains(where: { lower.contains($0) }) {
            // don't let a bare "okay" override a clear negative also present
            emo.append(r.label); if !themes.contains(r.theme) { themes.append(r.theme) }
            if r.positive == false { mood -= 1 } else if r.positive == true { mood += 1 }
        }
        phys = dedup(phys); emo = dedup(emo); themes = dedup(themes)

        // "Holding steady" only stands alone; drop it if other feelings exist
        if emo.count > 1 { emo.removeAll { $0 == "Holding steady" } }

        let concerns = extractConcerns(lower)
        mood = max(1, min(5, mood))

        var flags: [String] = []
        if themes.contains("swelling") { flags.append("Swelling, watch") }
        if themes.contains("anxiety") || themes.contains("low mood") { flags.append("Mood, check in") }

        return CheckinLog(
            physicalSignals: phys,
            emotionalSignals: emo,
            concerns: concerns,
            themes: themes,
            moodScore: mood,
            reflectionSummary: reflection(phys: phys, emo: emo, concerns: concerns, mood: mood),
            flagsForFollowup: flags,
            summaryLine: summary(phys: phys, emo: emo, mood: mood)
        )
    }

    private static func extractConcerns(_ lower: String) -> [String] {
        var out: [String] = []
        if lower.contains("scan") { out.append("The upcoming scan") }
        if lower.contains("birth") || lower.contains("labour") || lower.contains("labor") { out.append("The birth") }
        for marker in ["worried about", "anxious about", "scared about", "nervous about"] {
            if let r = lower.range(of: marker) {
                var tail = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                tail = tail.split(whereSeparator: { ".,!?;".contains($0) }).first.map(String.init) ?? tail
                if !tail.isEmpty && tail.count < 60 { out.append(tail.prefix(1).capitalized + tail.dropFirst()) }
            }
        }
        return dedup(out)
    }

    // A neutral, factual recap stored on the entry and shown on the tracking
    // screens. It is NOT a conversational reply, and no longer carries any
    // template scaffolding. The model writes every spoken/typed reply.
    private static func reflection(phys: [String], emo: [String], concerns: [String], mood: Int) -> String {
        let signals = emo + phys
        var line = ""
        if !signals.isEmpty {
            let joined = joinLower(signals)
            line = joined.prefix(1).uppercased() + joined.dropFirst() + "."
        }
        if let c = concerns.first { line += (line.isEmpty ? "" : " ") + c + "." }
        return line.isEmpty ? "Checked in." : line
    }

    private static func summary(phys: [String], emo: [String], mood: Int) -> String {
        let e = emo.first ?? ""
        let p = phys.first ?? ""
        if !e.isEmpty && !p.isEmpty { return "\(e), and \(p.lowercased())." }
        if !p.isEmpty { return p + "." }
        if !e.isEmpty { return e + "." }
        return mood >= 4 ? "A good day." : "Checked in."
    }

    private static func dedup(_ items: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for i in items where !seen.contains(i.lowercased()) { seen.insert(i.lowercased()); out.append(i) }
        return Array(out.prefix(5))
    }

    private static func joinLower(_ items: [String]) -> String {
        let l = items.map { $0.lowercased() }
        switch l.count {
        case 0: return ""
        case 1: return l[0]
        case 2: return "\(l[0]) and \(l[1])"
        default: return l.dropLast().joined(separator: ", ") + " and " + l.last!
        }
    }
}
