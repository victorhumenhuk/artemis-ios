//  SafeChecker.swift
//  "Is this safe in pregnancy?" grounded in NHS guidance, cited, non-diagnostic.
//  A small curated map over the NHS medicines / foods-to-avoid pages. When a
//  query is unknown it does not guess: it cites the relevant NHS hub and says
//  to check with a pharmacist or midwife.

import Foundation

enum SafeChecker {
    struct Result {
        var tier: TriageTier
        var answer: String
        var notes: [String]
        var action: String
        var sourceTitle: String
        var sourceURL: String
        var topic: String          // neutral card title, never the raw user phrase
        var uncertain: Bool        // true when not found in guidance, drives the chips + badge
    }

    /// Ambiguous or self-harm-adjacent input must never be treated as a casual
    /// safe-check or labelled ROUTINE. The engine routes these to care instead.
    static func isConcerning(_ query: String) -> Bool {
        let q = query.lowercased()
        // High-confidence direct cues: always route to care.
        let direct = ["kill myself", "killing myself", "end my life", "take my life", "suicide",
                      "suicidal", "harm myself", "hurt myself", "self harm", "self-harm",
                      "don't want to live", "do not want to live", "don't want to be here",
                      "not want to be here", "better off without me", "better off dead",
                      "want to die", "wish i was dead", "wish i were dead", "overdose", "take all my"]
        if direct.contains(where: { q.contains($0) }) { return true }
        // Ambiguous words ("dying", "end it") only concern us OUTSIDE common idioms,
        // so "dying for a cuppa" or "dying of embarrassment" is not flagged.
        let benignIdioms = ["dying to", "dying for", "to die for", "dying of laughter",
                            "dying of embarrassment", "dying of boredom", "dying of exhaustion",
                            "dying of hunger", "dying of thirst"]
        if benignIdioms.contains(where: { q.contains($0) }) { return false }
        let ambiguous = ["dying", "end it all", "end it"]
        return ambiguous.contains(where: { q.contains($0) })
    }

    private struct Entry {
        let keys: [String]; let tier: TriageTier; let answer: String
        let action: String; let title: String; let url: String
    }

    private static let medicinesURL = "https://www.nhs.uk/pregnancy/keeping-well/medicines/"
    private static let foodsURL = "https://www.nhs.uk/pregnancy/keeping-well/foods-to-avoid/"

    private static let entries: [Entry] = [
        Entry(keys: ["paracetamol"], tier: .routine,
              answer: "Paracetamol is generally considered safe in pregnancy at the usual dose. Take the lowest dose for the shortest time.",
              action: "Follow the packet dose. If you need it often, mention it to your midwife.", title: "Medicines in pregnancy", url: medicinesURL),
        Entry(keys: ["ibuprofen", "nurofen", "aspirin"], tier: .routine,
              answer: "Ibuprofen and similar anti-inflammatories are usually best avoided in pregnancy, especially after 30 weeks, unless a doctor has advised it. Low-dose aspirin is sometimes prescribed, only on advice.",
              action: "Check with your pharmacist or midwife before taking it.", title: "Medicines in pregnancy", url: medicinesURL),
        Entry(keys: ["alcohol", "wine", "beer"], tier: .routine,
              answer: "The safest approach is to avoid alcohol completely in pregnancy, as no level is known to be safe.",
              action: "If you are finding it hard to stop, your midwife can help without judgement.", title: "Drinking alcohol while pregnant", url: "https://www.nhs.uk/pregnancy/keeping-well/drinking-alcohol-while-pregnant/"),
        Entry(keys: ["coffee", "caffeine", "tea"], tier: .routine,
              answer: "Some caffeine is fine, but keep it under about 200mg a day, roughly two mugs of instant coffee.",
              action: "Count tea, cola and chocolate too. No action needed if you are under the limit.", title: "Foods to avoid in pregnancy", url: foodsURL),
        Entry(keys: ["soft cheese", "brie", "camembert", "blue cheese"], tier: .routine,
              answer: "Mould-ripened soft cheeses like brie and soft blue cheeses are best avoided unless cooked until steaming, because of a small listeria risk. It is not an emergency, just one to skip.",
              action: "Hard cheeses and processed soft cheeses are fine. Check the NHS list.", title: "Foods to avoid in pregnancy", url: foodsURL),
        Entry(keys: ["sushi", "raw fish", "shellfish", "prawns"], tier: .routine,
              answer: "Cooked fish and shellfish are fine. Avoid raw shellfish, and limit some fish like tuna. Cold smoked or cured fish is best avoided unless cooked.",
              action: "Check the NHS list for which fish and how much.", title: "Foods to avoid in pregnancy", url: foodsURL),
        Entry(keys: ["pate", "liver"], tier: .routine,
              answer: "Avoid all types of pate, and avoid liver and liver products, because of high vitamin A and a listeria risk.",
              action: "Check the NHS foods to avoid list.", title: "Foods to avoid in pregnancy", url: foodsURL),
        Entry(keys: ["hair dye", "dye", "dyeing", "highlights"], tier: .routine,
              answer: "Most hair dyes are considered low risk in pregnancy, and only a small amount is absorbed through the scalp. Many people wait until the second trimester to be extra cautious.",
              action: "If you'd like to be cautious, wait until after the first trimester, or try highlights so the dye touches less of your scalp.", title: "Hair dye in pregnancy", url: "https://www.nhs.uk/pregnancy/keeping-well/"),
        Entry(keys: ["exercise", "run", "running", "gym", "swim", "yoga"], tier: .routine,
              answer: "Staying active is good in pregnancy. Keep moving at a level where you can still hold a conversation, and avoid contact sports or anything with a fall risk.",
              action: "Stop and get checked if you have pain, bleeding or feel faint.", title: "Exercise in pregnancy", url: "https://www.nhs.uk/pregnancy/keeping-well/exercise/"),
    ]

    static func check(_ query: String) -> Result {
        let q = query.lowercased()
        if let e = entries.first(where: { $0.keys.contains(where: { q.contains($0) }) }) {
            let matched = e.keys.first(where: { q.contains($0) }) ?? e.keys.first ?? "this"
            return Result(tier: e.tier, answer: e.answer,
                          notes: [e.tier == .routine || e.tier == .selfCare ? "Worth knowing" : "Worth checking soon"],
                          action: e.action, sourceTitle: e.title, sourceURL: e.url,
                          topic: matched.prefix(1).uppercased() + matched.dropFirst() + " in pregnancy",
                          uncertain: false)
        }
        // Unknown: do NOT guess and do NOT label routine (green). Stay uncertain
        // and send her to a professional, with a neutral topic, never the raw phrase.
        return Result(tier: .urgent,
                      answer: "I am not certain about that one from the NHS guidance I have, and I would not want to guess on something that matters.",
                      notes: ["Not in the cached NHS guidance"],
                      action: "Please check with your pharmacist or midwife, they can advise on this safely.",
                      sourceTitle: "Medicines in pregnancy", sourceURL: medicinesURL,
                      topic: "Safety in pregnancy", uncertain: true)
    }
}
