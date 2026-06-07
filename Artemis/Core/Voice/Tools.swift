//  Tools.swift
//  The function/tool surface. One definition set is registered with the
//  realtime session AND used to document the contract. ToolDispatcher executes
//  a tool by name and produces both the JSON result the model needs and the UI
//  side effects (verdict card, persisted check-in). Text input runs through the
//  same dispatcher, so voice and text produce identical results.

import Foundation

// MARK: - Tool definitions (plain JSON so this file needs no SDK)

enum ArtemisTool: String, CaseIterable {
    case retrieveNHSGuidance = "retrieve_nhs_guidance"
    case assessSymptoms = "assess_symptoms"
    case findNearestService = "find_nearest_service"
    case logCheckin = "log_checkin"
    case getRecentCheckins = "get_recent_checkins"

    var toolDescription: String {
        switch self {
        case .retrieveNHSGuidance:
            return "Look up NHS guidance for a symptom before giving any red-flag advice. Returns the NHS article title, url and a snippet. Call this first, SILENTLY. Say NOTHING while calling it, no 'let me check', no narration."
        case .assessSymptoms:
            return "Give a structured verdict grounded in the retrieved NHS guidance. Choose the higher tier when in doubt. Never lower the tier to reassure. Call this SILENTLY, then speak ONLY the final answer once."
        case .findNearestService:
            return "Find the nearest NHS maternity unit and return its name and phone with a one-tap call button. Call this whenever she asks to find a clinic, hospital, maternity unit or urgent care near her, as well as for any urgent or emergency verdict. Never tell her to search elsewhere, call this instead. Call it SILENTLY, no 'checking the nearest clinic' narration."
        case .logCheckin:
            return "Organise a daily check-in into structured fields and save it. Use this once you have understood how she is, not for a raw transcript. Call SILENTLY."
        case .getRecentCheckins:
            return "Read recent check-in summaries so you can notice and gently name a genuine recurring pattern across days. Read only. Call SILENTLY."
        }
    }

    /// JSON Schema for the parameters. Plain dictionaries so this stays SDK-free.
    var parametersJSON: [String: Any] {
        switch self {
        case .retrieveNHSGuidance:
            return JS.object([
                "query": JS.string("What she described, in plain words."),
                "suspected_topics": JS.array(of: JS.string("A possible condition, e.g. pre-eclampsia."), "Conditions this might relate to."),
            ], required: ["query"])
        case .assessSymptoms:
            return JS.object([
                "tier": JS.enumStr(["reassuring", "self_care", "routine", "urgent", "emergency"], "The urgency tier."),
                "spoken_response": JS.string("A warm reply under three sentences."),
                "matched_condition": JS.string("The thing being checked, e.g. pre-eclampsia."),
                "red_flags_detected": JS.array(of: JS.string(nil), "The concerning signs noticed."),
                "nhs_source_title": JS.string("The NHS article title from the guidance."),
                "nhs_source_url": JS.string("The NHS article url from the guidance."),
                "recommended_action": JS.string("What she should do now."),
                "route_to": JS.enumStr(["maternity_triage", "nhs111", "emergency999", "gp", "none"], "Where to send her."),
            ], required: ["tier", "spoken_response", "matched_condition", "route_to"])
        case .findNearestService:
            return JS.object([
                "service_type": JS.string("e.g. maternity_unit."),
                "lat": JS.number("Latitude, if known."),
                "lng": JS.number("Longitude, if known."),
            ], required: ["service_type"])
        case .logCheckin:
            return JS.object([
                "physical_signals": JS.array(of: JS.string(nil), "Bodily signals, separated out."),
                "emotional_signals": JS.array(of: JS.string(nil), "Feelings, separated out."),
                "concerns": JS.array(of: JS.string(nil), "Her worries, in her words."),
                "themes": JS.array(of: JS.string(nil), "Recurring tags, e.g. sleep, anxiety."),
                "mood_score": JS.integer("Inferred mood, 1 to 5."),
                "reflection_summary": JS.string("A warm one or two sentence paraphrase back to her."),
                "flags_for_followup": JS.array(of: JS.string(nil), "Anything to keep an eye on."),
                "summary_line": JS.string("One line for the trend view."),
            ], required: ["mood_score", "reflection_summary", "summary_line"])
        case .getRecentCheckins:
            return JS.object([
                "limit": JS.integer("How many recent check-ins to read."),
            ], required: [])
        }
    }
}

/// Tiny JSON-Schema helpers (kept SDK-free).
enum JS {
    static func string(_ desc: String?) -> [String: Any] {
        var d: [String: Any] = ["type": "string"]; if let desc { d["description"] = desc }; return d
    }
    static func number(_ desc: String?) -> [String: Any] {
        var d: [String: Any] = ["type": "number"]; if let desc { d["description"] = desc }; return d
    }
    static func integer(_ desc: String?) -> [String: Any] {
        var d: [String: Any] = ["type": "integer"]; if let desc { d["description"] = desc }; return d
    }
    static func enumStr(_ cases: [String], _ desc: String?) -> [String: Any] {
        var d: [String: Any] = ["type": "string", "enum": cases]; if let desc { d["description"] = desc }; return d
    }
    static func array(of items: [String: Any], _ desc: String?) -> [String: Any] {
        var d: [String: Any] = ["type": "array", "items": items]; if let desc { d["description"] = desc }; return d
    }
    static func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
}

// MARK: - Dispatch

@MainActor
protocol ToolDispatcherDelegate: AnyObject {
    func toolsDidProduceTriage(_ result: TriageResult, nearest: NearestService?, unit: MaternityUnit?)
    func toolsDidUpdateNearest(_ nearest: NearestService?, unit: MaternityUnit?)
    func toolsDidLocateUnit(_ service: NearestService, _ unit: MaternityUnit, live: Bool)
    func toolsDidLogCheckin(_ log: CheckinLog)
    func toolsDidRequestCrisis()   // self-harm seen in a model tool call → care, never a card
}

@MainActor
final class ToolDispatcher {
    private let store: Store
    weak var delegate: ToolDispatcherDelegate?

    /// Set by retrieve_nhs_guidance so assess_symptoms stays consistent with it.
    private(set) var lastGuidance: GroundingHit?

    init(store: Store) {
        self.store = store
    }

    /// Execute by name; returns the JSON string result for the model.
    func dispatch(name: String, argumentsJSON: String) async -> String {
        let args = parse(argumentsJSON)
        guard let tool = ArtemisTool(rawValue: name) else { return jsonError("unknown tool") }
        switch tool {
        case .retrieveNHSGuidance: return await retrieve(args)
        case .assessSymptoms:      return await assess(args)
        case .findNearestService:  return await findNearest(args)
        case .logCheckin:          return logCheckin(args)
        case .getRecentCheckins:   return getRecent(args)
        }
    }

    // MARK: tools

    private func retrieve(_ args: [String: Any]) async -> String {
        let query = (args["query"] as? String) ?? ""
        let topics = (args["suspected_topics"] as? [String]) ?? []
        guard let hit = await NHSContentClient.shared.retrieve(query: query, suspectedTopics: topics) else {
            lastGuidance = nil
            return "{}"   // nothing relevant: the model should escalate and signpost
        }
        lastGuidance = hit
        return encode([
            "title": hit.guidance.title,
            "url": hit.guidance.url,
            "snippet": hit.guidance.snippet,
        ])
    }

    private func assess(_ args: [String: Any]) async -> String {
        let entry = lastGuidance?.entry
        // SAFETY (P0): the realtime model could pass a self-harm phrase or echo her
        // raw words. Catch it here, never trust the prompt alone. Self-harm in the
        // title or spoken text routes to care, never a green triage card.
        let rawMatched = (args["matched_condition"] as? String) ?? ""
        let rawSpoken = (args["spoken_response"] as? String) ?? ""
        if SafeChecker.isConcerning(rawMatched) || SafeChecker.isConcerning(rawSpoken) {
            delegate?.toolsDidRequestCrisis()
            return encode(["routed_to": "crisis", "instruction": "Respond with care and warmth, do not produce a triage card, and point her to Samaritans 116 123 and a human."])
        }
        let tierStr = (args["tier"] as? String) ?? entry?.defaultTier.rawValue ?? "urgent"
        var tier = TriageTier(rawValue: tierStr) ?? .urgent
        // Safety net: never let the verdict fall below the routed default tier.
        if let def = entry?.defaultTier { tier = TriageTier.higher(tier, def) }
        // DETERMINISTIC RED-FLAG FLOOR: certain signs ALWAYS escalate, regardless of
        // the model's tier, so a pre-eclampsia or labour sign is never shown routine.
        let scan = (rawMatched + " " + rawSpoken + " " + ((args["red_flags_detected"] as? [String])?.joined(separator: " ") ?? "")).lowercased()
        let emergencyFlags = ["about to give birth", "giving birth", "in labour", "waters", "heavy bleeding", "collapse", "seizure", "fitting", "unconscious", "chest pain", "can't breathe", "cannot breathe"]
        let urgentFlags = ["blurred vision", "blurry vision", "vision has gone", "vision's gone", "severe headache", "bad headache", "pounding headache", "reduced movement", "fewer movement", "not moving", "stopped moving", "swollen", "swelling", "faint", "dizzy", "pre-eclampsia", "preeclampsia"]
        if emergencyFlags.contains(where: { scan.contains($0) }) { tier = .emergency }
        else if urgentFlags.contains(where: { scan.contains($0) }) { tier = TriageTier.higher(tier, .urgent) }
        ArtemisLog.info("Triage: tier=\(tier.rawValue) (model passed \(tierStr)).")

        let routeStr = (args["route_to"] as? String) ?? entry?.routeTo.rawValue ?? "maternity_triage"
        let route = RouteTarget(rawValue: routeStr) ?? .maternityTriage

        // The NHS source comes only from what retrieve_nhs_guidance actually
        // returned (or the model echoing it). We never fabricate a source.
        let srcTitle = (args["nhs_source_title"] as? String) ?? lastGuidance?.guidance.title ?? ""
        let srcURL = (args["nhs_source_url"] as? String) ?? lastGuidance?.guidance.url ?? ""

        var result = TriageResult(
            tier: tier,
            spokenResponse: (args["spoken_response"] as? String) ?? defaultSpoken(for: tier, condition: entry?.condition),
            matchedCondition: Self.neutralTitle(rawMatched, fallback: entry?.condition ?? "What you described"),
            redFlagsDetected: (args["red_flags_detected"] as? [String]) ?? entry?.redFlags ?? [],
            nhsSourceTitle: srcTitle,
            nhsSourceURL: srcURL,
            recommendedAction: (args["recommended_action"] as? String) ?? defaultAction(for: tier, route: route),
            routeTo: route
        )

        // SAFETY GUARD: an URGENT/EMERGENCY verdict must be grounded in a real NHS
        // source; if it is not, escalate to a safe, sourced fallback. But a
        // REASSURING / self-care / routine verdict (e.g. "I'm feeling good") must
        // NEVER be escalated for a missing source, that would alarm her for no reason.
        // We just attach the general NHS pregnancy hub so the card still cites NHS.
        if !NHSSourceGuard.isValid(title: result.nhsSourceTitle, url: result.nhsSourceURL) {
            if tier == .urgent || tier == .emergency {
                ArtemisLog.warn("Triage blocked: ungrounded \(tier.rawValue). Escalating.")
                result = NHSSourceGuard.safeEscalation(tier: tier, redFlags: entry?.redFlags ?? [])
            } else {
                result = TriageResult(
                    tier: result.tier,
                    spokenResponse: result.spokenResponse,
                    matchedCondition: result.matchedCondition,
                    redFlagsDetected: result.redFlagsDetected,
                    nhsSourceTitle: "NHS pregnancy advice",
                    nhsSourceURL: "https://www.nhs.uk/pregnancy/",
                    recommendedAction: result.recommendedAction,
                    routeTo: result.routeTo)
            }
        }

        store.addSymptom(result)

        var nearest: NearestService?
        var unit: MaternityUnit?
        let needsUnit = result.tier != .routine && result.tier != .reassuring && result.tier != .selfCare
            && (result.routeTo == .maternityTriage || result.routeTo == .emergency999)
        if needsUnit {
            // Resolve her REAL location FIRST (London on the simulator), so the card
            // shows a believable distance, never a default-coordinate 5704 km.
            let coord = await LocationProvider.shared.currentCoarseLocation() ?? LocationProvider.shared.lastKnown
            if let found = ServiceLocator.shared.nearest(lat: coord?.latitude, lng: coord?.longitude) {
                nearest = found.service; unit = found.unit
            }
        }
        delegate?.toolsDidProduceTriage(result, nearest: nearest, unit: unit)
        return encode(["ok": true, "tier": tier.rawValue])
    }

    private func findNearest(_ args: [String: Any]) async -> String {
        // ALWAYS use her real device location. Never trust model-supplied lat/lng,
        // the model hallucinated far-away coordinates (the 5704 km bug). On the
        // simulator currentCoarseLocation returns a London test fix.
        let coord = await LocationProvider.shared.currentCoarseLocation()
        let lat = coord?.latitude
        let lng = coord?.longitude
        let locationUsed = (lat != nil && lng != nil)   // true when her real location was available
        // Live NHS Directory of Services when available, cached units otherwise.
        guard let found = await DoSClient.nearest(lat: lat, lng: lng) else {
            return encode(["located": false, "location_used": false])
        }
        delegate?.toolsDidLocateUnit(found.service, found.unit, live: found.live)   // show a one-tap call card
        return encode([
            "located": true,
            "location_used": locationUsed,   // if false, the unit is a general fallback, not distance-sorted
            "name": found.service.name,
            "phone": found.service.phone,
            "distance_km": found.service.distanceKm,
        ])
    }

    private func logCheckin(_ args: [String: Any]) -> String {
        let log = CheckinLog(
            physicalSignals: (args["physical_signals"] as? [String]) ?? [],
            emotionalSignals: (args["emotional_signals"] as? [String]) ?? [],
            concerns: (args["concerns"] as? [String]) ?? [],
            themes: (args["themes"] as? [String]) ?? [],
            moodScore: (args["mood_score"] as? Int) ?? Int((args["mood_score"] as? Double) ?? 3),
            reflectionSummary: (args["reflection_summary"] as? String) ?? "Checked in.",
            flagsForFollowup: (args["flags_for_followup"] as? [String]) ?? [],
            summaryLine: (args["summary_line"] as? String) ?? "Checked in."
        )
        store.addCheckin(log)
        delegate?.toolsDidLogCheckin(log)
        return encode(["ok": true])
    }

    private func getRecent(_ args: [String: Any]) -> String {
        let limit = (args["limit"] as? Int) ?? 7
        let entries = store.recentCheckins(limit: limit)
        let summaries = entries.map { e -> [String: Any] in
            ["date": ISO8601DateFormatter().string(from: e.date),
             "mood_score": e.moodScore,
             "themes": e.themes,
             "summary_line": e.summaryLine]
        }
        var payload: [String: Any] = ["checkins": summaries]
        if let pattern = Insights.namedPattern(entries) { payload["pattern"] = pattern }
        return encode(payload)
    }

    // MARK: helpers

    /// The card title must be a neutral topic, never the woman's raw words or an
    /// echoed question. If the model's matched_condition looks like a question or
    /// is empty, fall back to a neutral phrase.
    static func neutralTitle(_ raw: String, fallback: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = t.lowercased()
        let echoey = t.isEmpty || t.contains("?")
            || ["is ", "are ", "can i", "should i", "do i", "will ", "am i", "would ", "could ", "what if"].contains { l.hasPrefix($0) }
        return echoey ? fallback : t
    }

    func defaultSpoken(for tier: TriageTier, condition: String?) -> String {
        let what = condition?.lowercased() ?? "what you described"
        switch tier {
        case .emergency: return "This needs checking right now. Call 999 or your maternity unit straight away. \(what.prefix(1).uppercased() + what.dropFirst()) can change quickly, and you should be seen."
        case .urgent: return "This is worth getting checked today. Call your maternity team and they'll see you soon to make sure all is well. You're not making a fuss."
        case .routine: return "This one's worth mentioning at your next appointment. Keep an eye on it, and tell me straight away if it changes suddenly."
        case .selfCare: return "You can look after this at home. Rest, be kind to yourself, and tell me if anything shifts."
        case .reassuring: return "That all sounds reassuring. There's nothing here that needs action right now."
        }
    }

    private func defaultAction(for tier: TriageTier, route: RouteTarget) -> String {
        switch (tier, route) {
        case (.emergency, .emergency999): return "Call 999 now, or go straight to your nearest emergency department."
        case (.emergency, _): return "Call your maternity triage unit now. If symptoms worsen, call 999."
        case (.urgent, _): return "Call your maternity unit today. They will likely ask you to come in for monitoring."
        case (.routine, _): return "Rest and keep an eye on it. Mention it at your next appointment, and call sooner if it changes suddenly."
        case (.selfCare, _): return "You can look after this at home. Rest and be kind to yourself, and tell me if anything changes."
        case (.reassuring, _): return "Keep doing what you are doing, and tell me if anything changes."
        }
    }

    private func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
    private func encode(_ dict: [String: Any]) -> String {
        // Sanitise any non-finite Double (NaN/inf): JSONSerialization throws an
        // UNCATCHABLE NSException on those, which would crash the app.
        var safe = dict
        for (k, v) in dict { if let d = v as? Double, !d.isFinite { safe[k] = 0 } }
        guard let data = try? JSONSerialization.data(withJSONObject: safe),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
    private func jsonError(_ msg: String) -> String { "{\"error\":\"\(msg)\"}" }
}
