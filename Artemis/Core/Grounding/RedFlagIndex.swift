//  RedFlagIndex.swift
//  Domain routing only: map a symptom to an NHS article, a default tier and a
//  route target. This does no clinical reasoning beyond routing; the verdict
//  is grounded in the article fetched through the Content client.

import Foundation

struct RedFlagEntry: Decodable, Equatable {
    let id: String
    let condition: String
    let keywords: [String]
    let articlePath: String
    let citationTitle: String
    let citationURL: String
    let fallbackSnippet: String
    let defaultTier: TriageTier
    let routeTo: RouteTarget
    let redFlags: [String]
}

struct GroundingHit: Equatable {
    let guidance: RetrievedGuidance
    let entry: RedFlagEntry
    let liveFetched: Bool
}

final class RedFlagIndex {
    static let shared = RedFlagIndex()
    let entries: [RedFlagEntry]

    private init() {
        guard let url = Bundle.main.url(forResource: "RedFlagIndex", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            self.entries = []
            return
        }
        struct Wrapper: Decodable { let entries: [RedFlagEntry] }
        self.entries = (try? JSONDecoder().decode(Wrapper.self, from: data))?.entries ?? []
    }

    /// Best match for free text. Score = number of distinct keywords present.
    /// Ties break to the HIGHER tier, so ambiguity always escalates upward.
    func match(_ query: String, suspectedTopics: [String] = []) -> RedFlagEntry? {
        let haystack = (query + " " + suspectedTopics.joined(separator: " ")).lowercased()
        var best: RedFlagEntry?
        var bestScore = 0
        for entry in entries {
            var score = 0
            for kw in entry.keywords where haystack.contains(kw.lowercased()) { score += 1 }
            // a direct hit on the condition name or id is a strong signal
            if haystack.contains(entry.condition.lowercased()) { score += 1 }
            if score == 0 { continue }
            if score > bestScore {
                best = entry; bestScore = score
            } else if score == bestScore, let current = best,
                      TriageTier.higher(entry.defaultTier, current.defaultTier) == entry.defaultTier,
                      entry.defaultTier != current.defaultTier {
                best = entry
            }
        }
        return best
    }
}
