//  DebugFlags.swift
//  Runtime switches for the hidden debug screen (triple-tap the version in
//  Settings) and for tests. None of these affect a normal launch.

import Foundation
import Observation

@Observable
final class DebugFlags {
    static let shared = DebugFlags()

    /// When true, retrieve_nhs_guidance returns nothing, so we can prove that
    /// Artemis refuses to give clinical guidance and escalates instead of guessing.
    var retrievalDisabled: Bool

    /// Temporary live connection overlay on the conversation. Off by default.
    var showConnectionOverlay: Bool

    private init() {
        let env = ProcessInfo.processInfo.environment
        retrievalDisabled = env["ARTEMIS_NO_RETRIEVAL"] == "1"
        showConnectionOverlay = env["ARTEMIS_OVERLAY"] == "1"
    }
}

/// A verdict may only be shown if it carries a real, tappable NHS source. This
/// is the app-side safety guard: no guidance without a source.
enum NHSSourceGuard {
    static func isValid(title: String, url: String) -> Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let u = URL(string: url), u.scheme == "https", let host = u.host else { return false }
        return host.hasSuffix("nhs.uk")
    }

    /// The safe escalation shown when a result has no valid NHS source. It still
    /// carries a source (NHS 111) and never reassures.
    static func safeEscalation(tier: TriageTier, redFlags: [String]) -> TriageResult {
        let t = TriageTier.higher(tier, .urgent)
        if t == .emergency {
            return TriageResult(
                tier: .emergency,
                spokenResponse: "This needs checking right now. Call 999, or go straight to A and E if you can get there safely. I would rather we were certain than wait.",
                matchedCondition: "Let's get you checked",
                redFlagsDetected: redFlags,
                nhsSourceTitle: "When to call 999",
                nhsSourceURL: "https://111.nhs.uk/",
                recommendedAction: "Call 999 now, or go to A and E. If you can, contact your maternity unit too, but do not wait.",
                routeTo: .emergency999)
        }
        return TriageResult(
            tier: .urgent,
            spokenResponse: "I can't be sure about this from the guidance I have, and I don't want to take any chances. Please contact your maternity unit, or call 111, so a person can check you.",
            matchedCondition: "Let's get you checked",
            redFlagsDetected: redFlags,
            nhsSourceTitle: "NHS 111",
            nhsSourceURL: "https://111.nhs.uk/",
            recommendedAction: "Call your maternity unit now, or call 111 if you cannot reach them. If symptoms feel severe, call 999.",
            routeTo: .maternityTriage)
    }
}
