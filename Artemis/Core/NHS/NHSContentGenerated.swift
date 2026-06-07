//  NHSContentGenerated.swift
//  GENERATED from specs/nhs-website-content.json by scripts/generate_nhs_client.py.
//  Do not edit by hand. Re-run the script after the spec changes.
//  Spec: NHS Website Content API v2 (openapi 3.0.0)

import Foundation

/// Every path defined in the NHS Website Content API spec. The client can
/// only ever request one of these, so we never invent endpoints.
enum NHSContentPath: String, CaseIterable {
    case manifestPages = "/manifest/pages"
    case healthAToZ = "/health-a-to-z"
    case healthAToZConditions = "/health-a-to-z/conditions"
    case conditions = "/conditions"
    case conditionsItem = "/conditions/*"
    case symptoms = "/symptoms"
    case testsAndTreatments = "/tests-and-treatments"
    case medicines = "/medicines"
    case medicinesItem = "/medicines/*"
    case mentalHealth = "/mental-health"
    case liveWell = "/live-well"
    case pregnancy = "/pregnancy"
    case nhsServices = "/nhs-services"
    case contraception = "/contraception"
    case vaccinations = "/vaccinations"
    case womensHealth = "/womens-health"
    case baby = "/baby"
    case socialCareAndSupport = "/social-care-and-support"
}

enum NHSContentServer {
    static let integration = "https://int.api.service.nhs.uk/nhs-website-content"
    static let production = "https://api.service.nhs.uk/nhs-website-content"
}

/// Section roots that have per-page sub-paths in the spec (e.g. /conditions/*).
let nhsWildcardSectionRoots: [String] = [
    "/conditions",
    "/medicines",
]

/// Exact (non-wildcard) paths defined in the spec.
let nhsExactPaths: Set<String> = [
    "/baby",
    "/conditions",
    "/contraception",
    "/health-a-to-z",
    "/health-a-to-z/conditions",
    "/live-well",
    "/manifest/pages",
    "/medicines",
    "/mental-health",
    "/nhs-services",
    "/pregnancy",
    "/social-care-and-support",
    "/symptoms",
    "/tests-and-treatments",
    "/vaccinations",
    "/womens-health",
]

/// True if `path` is allowed by the spec: an exact defined path, or a
/// per-page sub-path under a documented wildcard section.
func nhsPathIsAllowed(_ path: String) -> Bool {
    let p = path.hasPrefix("/") ? path : "/" + path
    if nhsExactPaths.contains(p) { return true }
    return nhsWildcardSectionRoots.contains { p.hasPrefix($0 + "/") }
}

/// The documented article/page response (schema.org shaped). We decode the
/// fields needed for grounding and citation: name (title), description
/// (snippet) and url. Modular pages expose extra text under `hasPart`.
struct NHSContentPage: Decodable {
    let name: String?
    let description: String?
    let url: String?
    let type: String?
    let hasPart: [NHSContentPart]?

    enum CodingKeys: String, CodingKey {
        case name, description, url, hasPart
        case type = "@type"
    }
}

struct NHSContentPart: Decodable {
    let name: String?
    let text: String?
    let description: String?
}

