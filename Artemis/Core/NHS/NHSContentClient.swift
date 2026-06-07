//  NHSContentClient.swift
//  Grounds a verdict in NHS content. Uses RedFlagIndex to map the query to an
//  NHS.uk article, then fetches the live article through the Worker proxy
//  (GET /nhs/content?path=...) for the current title and snippet. The proxy
//  injects the NHS key server-side, so no key ever lives in the app.
//
//  Only paths defined in the spec (nhsPathIsAllowed) are ever requested.

import Foundation

actor NHSContentClient {
    static let shared = NHSContentClient()

    private var cache: [String: RetrievedGuidance] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Implements the retrieve_nhs_guidance tool. Returns nil when nothing
    /// matches, so the model escalates and signposts rather than guessing.
    func retrieve(query: String, suspectedTopics: [String] = []) async -> GroundingHit? {
        // Debug / test switch: prove Artemis refuses and escalates when retrieval
        // returns nothing, rather than guessing.
        if DebugFlags.shared.retrievalDisabled { return nil }
        guard let entry = RedFlagIndex.shared.match(query, suspectedTopics: suspectedTopics) else {
            return nil
        }
        guard nhsPathIsAllowed(entry.articlePath) else {
            // Should never happen with the curated index, but never invent endpoints.
            return GroundingHit(
                guidance: RetrievedGuidance(title: entry.citationTitle, url: entry.citationURL, snippet: entry.fallbackSnippet),
                entry: entry, liveFetched: false)
        }

        if let cached = cache[entry.articlePath] {
            return GroundingHit(guidance: cached, entry: entry, liveFetched: true)
        }

        // Is this a specific page (under a wildcard section) where the live
        // title/snippet will be page-accurate, or a section hub (generic)?
        let isSpecificPage = nhsWildcardSectionRoots.contains { entry.articlePath.hasPrefix($0 + "/") }

        if let page = await fetchPage(path: entry.articlePath), isSpecificPage,
           let desc = page.description, !desc.isEmpty {
            let guidance = RetrievedGuidance(
                title: page.name ?? entry.citationTitle,
                url: entry.citationURL,            // always the real nhs.uk page
                snippet: cleanSnippet(desc))
            cache[entry.articlePath] = guidance
            ArtemisLog.info("NHS: live content for \(entry.articlePath).")
            return GroundingHit(guidance: guidance, entry: entry, liveFetched: true)
        }
        ArtemisLog.info("NHS: cached snippet for \(entry.id) (live fetch unavailable).")

        // Section hubs and any fetch failure fall back to the curated snippet,
        // which is still grounded in the same NHS page. Keeps triage working
        // offline.
        let guidance = RetrievedGuidance(title: entry.citationTitle, url: entry.citationURL, snippet: entry.fallbackSnippet)
        return GroundingHit(guidance: guidance, entry: entry, liveFetched: false)
    }

    private func fetchPage(path: String) async -> NHSContentPage? {
        var comps = URLComponents(url: RealtimeConfig.serverBaseURL.appendingPathComponent("nhs/content"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try JSONDecoder().decode(NHSContentPage.self, from: data)
        } catch {
            return nil
        }
    }

    private func cleanSnippet(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 220 { return trimmed }
        let cut = trimmed.prefix(217)
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }
}
