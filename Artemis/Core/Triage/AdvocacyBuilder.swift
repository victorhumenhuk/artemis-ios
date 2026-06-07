//  AdvocacyBuilder.swift
//  Turns the stored log into a structured script she can read or show to a
//  clinician. Deterministic and client-side, so it works offline. The model
//  may optionally rephrase it, but this is the default path.

import Foundation

struct AdvocacyScript: Equatable {
    var title: String
    var generated: String
    var body: [String]

    var plainText: String {
        body.joined(separator: "\n")
    }
}

enum AdvocacyBuilder {
    static func build(profile: UserProfile?,
                      checkins: [CheckinEntry],
                      latestSymptom: SymptomEntry?,
                      bp: [BPReading]) -> AdvocacyScript {
        var lines: [String] = []

        // who she is
        if let p = profile {
            if p.stageEnum == .pregnant {
                let first = p.firstPregnancy ? "first baby" : "not my first baby"
                lines.append("I am \(p.weeks) weeks pregnant, \(first).")
            } else {
                lines.append("I gave birth \(p.birthTiming ?? "recently").")
            }
            var history: [String] = []
            if p.hasBPHistory { history.append("high blood pressure") }
            if p.hasMentalHealthHistory { history.append("a mental health history") }
            if !history.isEmpty { lines.append("My history includes \(history.joined(separator: " and ")).") }
        }

        // the concern that brought her in
        if let s = latestSymptom {
            lines.append("I am here about \(s.matchedCondition.lowercased()).")
            if !s.redFlags.isEmpty {
                lines.append("What I have noticed: \(joinNaturally(s.redFlags.map { $0.lowercased() })).")
            }
        }

        // home blood pressure trend, if she has logged it
        let recentBP = bp.sorted { $0.date < $1.date }.suffix(3)
        if recentBP.count >= 2 {
            let values = recentBP.map { $0.display }.joined(separator: ", ")
            lines.append("My blood pressure at home over the last few days was \(values).")
        }

        // recurring themes and worries from her check-ins
        let recent = Array(checkins.prefix(7))
        let concerns = recent.flatMap { $0.concerns }
        if let topConcern = concerns.first {
            lines.append("My main worry is \(topConcern.lowercased()).")
        }
        let signals = Array(Set(recent.flatMap { $0.physicalSignals })).prefix(3)
        if !signals.isEmpty && latestSymptom == nil {
            lines.append("Over the past week I have had \(joinNaturally(signals.map { $0.lowercased() })).")
        }

        lines.append("I would like to be assessed today.")

        let f = DateFormatter(); f.dateStyle = .medium
        let generated = recent.isEmpty ? "Generated from your details"
                                       : "Generated from your last \(min(7, recent.count)) days"
        return AdvocacyScript(title: "For your midwife", generated: generated, body: lines)
    }

    private static func joinNaturally(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
