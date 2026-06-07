//  OnDeviceFallback.swift
//  When there is no network: WhisperKit transcribes on device, and a cautious
//  local response is produced that always points her to her maternity unit,
//  using cached numbers. It never reassures away a red flag.

import Foundation

@MainActor
final class OnDeviceFallback {
    static let shared = OnDeviceFallback()

    /// Transcribe a recorded utterance on device with WhisperKit. Returns nil if
    /// WhisperKit is unavailable; callers then use Apple's on-device speech
    /// recogniser (also fully on device).
    func transcribe(fileURL: URL) async -> String? {
        #if canImport(WhisperKit)
        return await WhisperBox.shared.transcribe(path: fileURL.path)
        #else
        return nil
        #endif
    }

    /// A cautious offline reply. Grounds on the cached RedFlag snippet if one
    /// matches, otherwise signposts care. Never reassures away a red flag.
    func cautiousReply(to text: String) async -> String {
        let snippet = RedFlagIndex.shared.match(text)?.fallbackSnippet
        return await OnDeviceOrganizer.cautiousResponse(text, guidanceSnippet: snippet)
    }

    /// Offline triage: if a red flag matches the cached index, build a cautious
    /// verdict that points to the maternity unit. Never lowers the tier.
    func offlineTriage(for text: String) -> (TriageResult, RedFlagEntry)? {
        guard let entry = RedFlagIndex.shared.match(text) else { return nil }
        let tier = entry.defaultTier == .routine ? TriageTier.routine : TriageTier.higher(entry.defaultTier, .urgent)
        let result = TriageResult(
            tier: tier,
            spokenResponse: "I can't check the latest guidance while you're offline, so I won't take any chances. Please contact your maternity unit to be safe.",
            matchedCondition: entry.condition,
            redFlagsDetected: entry.redFlags,
            nhsSourceTitle: entry.citationTitle,
            nhsSourceURL: entry.citationURL,
            recommendedAction: "Call your maternity unit now. If symptoms worsen, call 999.",
            routeTo: entry.routeTo == .none ? .maternityTriage : entry.routeTo
        )
        return (result, entry)
    }
}

#if canImport(WhisperKit)
import WhisperKit

/// Loads the WhisperKit model once (downloads + caches on first use at runtime).
actor WhisperBox {
    static let shared = WhisperBox()
    private var pipe: WhisperKit?

    func transcribe(path: String) async -> String? {
        do {
            if pipe == nil { pipe = try await WhisperKit() }
            guard let pipe else { return nil }
            let results = try await pipe.transcribe(audioPath: path)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
#endif
