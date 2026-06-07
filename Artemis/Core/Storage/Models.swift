//  Models.swift
//  SwiftData @Model types. On-device only. We store transcript text, never raw
//  audio. No account, no login, no email, no immigration data.

import Foundation
import SwiftData

enum Stage: String, Codable, CaseIterable {
    case tryingToConceive, pregnant, postnatal
    // Architected so further stages (cycle, perimenopause, menopause) slot in
    // later without touching the home. Not built now.

    var label: String {
        switch self {
        case .tryingToConceive: return "Trying to conceive"
        case .pregnant: return "Pregnant"
        case .postnatal: return "After birth"
        }
    }
}

/// One turn in the persistent chat thread (same store as memory). Survives
/// relaunch. Stores text only, never raw audio.
@Model
final class ChatTurn {
    var date: Date
    var roleRaw: String      // "her" | "artemis"
    var text: String
    var imageData: Data?
    init(role: String, text: String, imageData: Data? = nil, date: Date = Date()) {
        self.roleRaw = role; self.text = text; self.imageData = imageData; self.date = date
    }
}

@Model
final class UserProfile {
    var name: String = ""             // her first name, used naturally by Artemis
    var stage: String                 // Stage raw value
    var weeks: Int                    // gestation weeks (pregnant)
    var birthTiming: String?          // postnatal, e.g. "2 weeks ago"
    var language: String
    var firstPregnancy: Bool
    var ageBand: String?
    var hasBPHistory: Bool
    var hasMentalHealthHistory: Bool
    var listenOnOpen: Bool
    var startInSilentMode: Bool
    var ethnicity: String = ""            // optional, tailors risk vigilance, never stereotyping
    var appearanceOverride: String = "System"   // System | Light | Dark
    var createdAt: Date

    init(name: String = "", stage: Stage = .pregnant, weeks: Int = 38, birthTiming: String? = nil,
         language: String = "English", firstPregnancy: Bool = true, ageBand: String? = nil,
         hasBPHistory: Bool = false, hasMentalHealthHistory: Bool = false,
         listenOnOpen: Bool = true, startInSilentMode: Bool = false,
         ethnicity: String = "", appearanceOverride: String = "System") {
        self.name = name
        self.ethnicity = ethnicity
        self.appearanceOverride = appearanceOverride
        self.stage = stage.rawValue
        self.weeks = weeks
        self.birthTiming = birthTiming
        self.language = language
        self.firstPregnancy = firstPregnancy
        self.ageBand = ageBand
        self.hasBPHistory = hasBPHistory
        self.hasMentalHealthHistory = hasMentalHealthHistory
        self.listenOnOpen = listenOnOpen
        self.startInSilentMode = startInSilentMode
        self.createdAt = Date()
    }

    var stageEnum: Stage { Stage(rawValue: stage) ?? .pregnant }

    /// "38 weeks pregnant" / "Baby arrived 2 weeks ago"
    var summaryLine: String {
        stageEnum == .pregnant ? "\(weeks) weeks pregnant"
                               : "Baby arrived \(birthTiming ?? "recently")"
    }
}

@Model
final class CheckinEntry {
    var date: Date
    var physicalSignals: [String]
    var emotionalSignals: [String]
    var concerns: [String]
    var themes: [String]
    var moodScore: Int
    var reflectionSummary: String
    var flagsForFollowup: [String]
    var summaryLine: String
    var rawTranscript: String        // text only, never audio

    init(log: CheckinLog, rawTranscript: String = "", date: Date = Date()) {
        self.date = date
        self.physicalSignals = log.physicalSignals
        self.emotionalSignals = log.emotionalSignals
        self.concerns = log.concerns
        self.themes = log.themes
        self.moodScore = log.moodScore
        self.reflectionSummary = log.reflectionSummary
        self.flagsForFollowup = log.flagsForFollowup
        self.summaryLine = log.summaryLine
        self.rawTranscript = rawTranscript
    }

    var asLog: CheckinLog {
        CheckinLog(physicalSignals: physicalSignals, emotionalSignals: emotionalSignals,
                   concerns: concerns, themes: themes, moodScore: moodScore,
                   reflectionSummary: reflectionSummary, flagsForFollowup: flagsForFollowup,
                   summaryLine: summaryLine)
    }
}

@Model
final class SymptomEntry {
    var date: Date
    var tier: String
    var matchedCondition: String
    var redFlags: [String]
    var nhsSourceTitle: String
    var nhsSourceURL: String
    var routeTo: String

    init(result: TriageResult, date: Date = Date()) {
        self.date = date
        self.tier = result.tier.rawValue
        self.matchedCondition = result.matchedCondition
        self.redFlags = result.redFlagsDetected
        self.nhsSourceTitle = result.nhsSourceTitle
        self.nhsSourceURL = result.nhsSourceURL
        self.routeTo = result.routeTo.rawValue
    }
}

@Model
final class BPReading {
    var date: Date
    var systolic: Int
    var diastolic: Int
    init(systolic: Int, diastolic: Int, date: Date = Date()) {
        self.date = date; self.systolic = systolic; self.diastolic = diastolic
    }
    var display: String { "\(systolic)/\(diastolic)" }
}

@Model
final class KickSession {
    var date: Date
    var count: Int
    var durationMinutes: Int
    init(count: Int, durationMinutes: Int = 0, date: Date = Date()) {
        self.date = date; self.count = count; self.durationMinutes = durationMinutes
    }
}
