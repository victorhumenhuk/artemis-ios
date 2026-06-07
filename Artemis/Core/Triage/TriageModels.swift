//  TriageModels.swift
//  The data contracts. These Swift types are mirrored exactly by the tool JSON
//  schemas in Tools.swift, so voice (model tool calls) and text (local engine)
//  produce the same structures. JSON uses snake_case to match the model's output.

import Foundation

enum TriageTier: String, Codable, CaseIterable, Sendable {
    // Order defines rank (lowest first) for escalation:
    // reassuring < self-care < routine < urgent < emergency.
    case reassuring, selfCare = "self_care", routine, urgent, emergency
}

enum RouteTarget: String, Codable, Sendable {
    case maternityTriage = "maternity_triage"
    case nhs111 = "nhs111"
    case emergency999 = "emergency999"
    case gp
    case none
}

/// The verdict card is rendered from this.
struct TriageResult: Codable, Equatable, Sendable {
    var tier: TriageTier
    var spokenResponse: String          // under 3 sentences, warm
    var matchedCondition: String        // e.g. "pre-eclampsia"
    var redFlagsDetected: [String]
    var nhsSourceTitle: String
    var nhsSourceURL: String
    var recommendedAction: String
    var routeTo: RouteTarget
    /// Provenance note under the NHS citation (set in-app, not from the model).
    var sourceNote: String = "Cached NHS guidance"

    enum CodingKeys: String, CodingKey {
        case tier
        case spokenResponse = "spoken_response"
        case matchedCondition = "matched_condition"
        case redFlagsDetected = "red_flags_detected"
        case nhsSourceTitle = "nhs_source_title"
        case nhsSourceURL = "nhs_source_url"
        case recommendedAction = "recommended_action"
        case routeTo = "route_to"
    }
}

/// The AI organises rambling input into this. Persisted as a CheckinEntry.
struct CheckinLog: Codable, Equatable, Sendable {
    var physicalSignals: [String]
    var emotionalSignals: [String]
    var concerns: [String]              // her worries, cleaned up, in her words
    var themes: [String]                // recurring tags: "sleep", "anxiety", "swelling"
    var moodScore: Int                  // 1...5, inferred
    var reflectionSummary: String       // warm 1-2 sentence paraphrase back to her
    var flagsForFollowup: [String]
    var summaryLine: String             // one line for the trend view

    enum CodingKeys: String, CodingKey {
        case physicalSignals = "physical_signals"
        case emotionalSignals = "emotional_signals"
        case concerns
        case themes
        case moodScore = "mood_score"
        case reflectionSummary = "reflection_summary"
        case flagsForFollowup = "flags_for_followup"
        case summaryLine = "summary_line"
    }
}

struct NearestService: Codable, Equatable, Sendable {
    var name: String
    var phone: String
    var distanceKm: Double
    var address: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, phone, address
        case distanceKm = "distance_km"
    }
}

/// What retrieve_nhs_guidance returns, used to ground a verdict and cite it.
struct RetrievedGuidance: Codable, Equatable, Sendable {
    var title: String
    var url: String
    var snippet: String
}

/// Gentle crisis support content (never gated).
struct CrisisSupport: Equatable, Sendable {
    var spokenResponse: String
    var lineName: String
    var linePhone: String
    var sub: String

    static let `default` = CrisisSupport(
        spokenResponse: "I'm really glad you told me. You don't have to carry this on your own, and feeling this way during pregnancy is more common than people say.",
        lineName: "Samaritans",
        linePhone: "116 123",
        sub: "Free, 24/7, and they won't judge you."
    )
}

extension TriageTier {
    var label: String {
        switch self {
        case .reassuring: return "Reassuring"
        case .selfCare: return "Self-care"
        case .routine: return "Routine"
        case .urgent: return "Urgent"
        case .emergency: return "Emergency"
        }
    }
    var word: String {
        switch self {
        case .reassuring: return "All is well"
        case .selfCare: return "Manage at home"
        case .routine: return "Usually normal"
        case .urgent: return "Check this soon"
        case .emergency: return "Get reviewed now"
        }
    }
    /// Higher tier wins. Used so uncertainty always escalates upward.
    var rank: Int { TriageTier.allCases.firstIndex(of: self)! }
    static func higher(_ a: TriageTier, _ b: TriageTier) -> TriageTier { a.rank >= b.rank ? a : b }
}
