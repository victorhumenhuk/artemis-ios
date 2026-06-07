//  OnDeviceOrganizer.swift
//  Apple Foundation Models (on-device, no network, no key) used to organise a
//  rambling check-in into structured fields, and to produce a cautious offline
//  response. Gated on availability, so on the Simulator or a non-eligible
//  device the caller falls back to the heuristic organiser. Never reassures
//  away a red flag.

import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable
struct GeneratedCheckin {
    @Guide(description: "Bodily signals, each a short phrase, separated from feelings.")
    var physicalSignals: [String]
    @Guide(description: "Emotional signals, each a short phrase.")
    var emotionalSignals: [String]
    @Guide(description: "Her worries in her own words, cleaned up.")
    var concerns: [String]
    @Guide(description: "Recurring tags, e.g. sleep, anxiety, swelling.")
    var themes: [String]
    @Guide(description: "Inferred mood from 1 (very low) to 5 (good).")
    var moodScore: Int
    @Guide(description: "A warm one or two sentence reflection back to her. No dashes.")
    var reflectionSummary: String
    @Guide(description: "Anything worth keeping an eye on.")
    var flagsForFollowup: [String]
    @Guide(description: "One short line for a trend view.")
    var summaryLine: String
}
#endif

enum OnDeviceOrganizer {
    /// Returns a structured check-in if Foundation Models is available, else nil.
    static func organiseCheckin(_ text: String) async -> CheckinLog? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = LanguageModelSession(instructions: """
                You organise a pregnant or postnatal woman's check-in into structured fields.
                Separate physical signals from emotional ones, capture her concerns in her own words,
                infer a mood score from 1 to 5, name recurring themes, and write a warm, non-clinical
                reflection of one or two sentences. Never diagnose. Never use dashes.
                """)
                let result = try await session.respond(to: text, generating: GeneratedCheckin.self)
                let g = result.content
                return CheckinLog(
                    physicalSignals: g.physicalSignals,
                    emotionalSignals: g.emotionalSignals,
                    concerns: g.concerns,
                    themes: g.themes,
                    moodScore: max(1, min(5, g.moodScore)),
                    reflectionSummary: g.reflectionSummary,
                    flagsForFollowup: g.flagsForFollowup,
                    summaryLine: g.summaryLine
                )
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// A cautious offline reply that always points her toward care. Used by the
    /// offline fallback when there is no network. Never reassures away a red flag.
    static func cautiousResponse(_ text: String, guidanceSnippet: String?) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            let context = guidanceSnippet.map { "Relevant NHS guidance: \($0)" } ?? "No NHS guidance retrieved."
            let session = LanguageModelSession(instructions: """
            You are Artemis, offline. Be calm and warm. You cannot look things up right now, so never
            reassure away anything that could be serious. Always suggest she contact her maternity unit,
            midwife, GP or 111. Keep it under three sentences. Never use dashes. Never diagnose.
            """)
            if let out = try? await session.respond(to: "\(context)\n\nShe said: \(text)") {
                return out.content
            }
        }
        #endif
        // Deterministic offline reply (no model): cautious by default.
        if let snippet = guidanceSnippet, !snippet.isEmpty {
            return "I can't check the latest guidance while you're offline, so I won't take any chances. \(snippet) Please contact your maternity unit, midwife or 111 to be safe."
        }
        return "I can't check guidance while you're offline, so I won't take any chances. If you're worried about a symptom, please contact your maternity unit, your midwife, or call 111. They will want to hear from you."
    }
}
