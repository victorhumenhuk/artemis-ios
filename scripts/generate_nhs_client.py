#!/usr/bin/env python3
"""Generate a typed Swift surface from the NHS Website Content API OpenAPI spec.

Reads specs/nhs-website-content.json and emits:
  Artemis/Core/NHS/NHSContentGenerated.swift

This keeps the client honest: it can only target paths that are actually
defined in the spec, and the response model mirrors the documented schema.
Re-run after the spec changes:  python3 scripts/generate_nhs_client.py
(See README "NHS clients" for the swift-openapi-generator alternative.)
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, "specs", "nhs-website-content.json")
OUT = os.path.join(ROOT, "Artemis", "Core", "NHS", "NHSContentGenerated.swift")

spec = json.load(open(SPEC))
info = spec.get("info", {})
paths = list(spec.get("paths", {}).keys())
prod = next((s["url"] for s in spec.get("servers", []) if "api.service.nhs.uk" in s["url"] and "sandbox" not in s["url"] and "int." not in s["url"]), "")
integration = next((s["url"] for s in spec.get("servers", []) if "int." in s["url"]), "https://int.api.service.nhs.uk/nhs-website-content")

def case_name(p):
    n = p.strip("/")
    n = n.replace("/*", "Item").replace("*", "Item")
    parts = re.split(r"[/\-]", n)
    parts = [x for x in parts if x]
    if not parts:
        return "root"
    out = parts[0]
    for x in parts[1:]:
        out += x[:1].upper() + x[1:]
    out = re.sub(r"[^A-Za-z0-9]", "", out)
    return out or "root"

# wildcard section roots (e.g. /conditions/* -> /conditions)
wildcard_roots = sorted({p[:-2] for p in paths if p.endswith("/*")})
exact = sorted({p for p in paths if not p.endswith("/*")})

cases = []
seen = set()
for p in paths:
    cn = case_name(p)
    base = cn; i = 2
    while cn in seen:
        cn = f"{base}{i}"; i += 1
    seen.add(cn)
    cases.append((cn, p))

lines = []
lines.append("//  NHSContentGenerated.swift")
lines.append("//  GENERATED from specs/nhs-website-content.json by scripts/generate_nhs_client.py.")
lines.append("//  Do not edit by hand. Re-run the script after the spec changes.")
lines.append(f"//  Spec: {info.get('title','')} (openapi {spec.get('openapi','')})")
lines.append("")
lines.append("import Foundation")
lines.append("")
lines.append("/// Every path defined in the NHS Website Content API spec. The client can")
lines.append("/// only ever request one of these, so we never invent endpoints.")
lines.append("enum NHSContentPath: String, CaseIterable {")
for cn, p in cases:
    lines.append(f'    case {cn} = "{p}"')
lines.append("}")
lines.append("")
lines.append("enum NHSContentServer {")
lines.append(f'    static let integration = "{integration}"')
lines.append(f'    static let production = "{prod}"')
lines.append("}")
lines.append("")
lines.append("/// Section roots that have per-page sub-paths in the spec (e.g. /conditions/*).")
lines.append("let nhsWildcardSectionRoots: [String] = [")
for r in wildcard_roots:
    lines.append(f'    "{r}",')
lines.append("]")
lines.append("")
lines.append("/// Exact (non-wildcard) paths defined in the spec.")
lines.append("let nhsExactPaths: Set<String> = [")
for p in exact:
    lines.append(f'    "{p}",')
lines.append("]")
lines.append("")
lines.append("/// True if `path` is allowed by the spec: an exact defined path, or a")
lines.append("/// per-page sub-path under a documented wildcard section.")
lines.append("func nhsPathIsAllowed(_ path: String) -> Bool {")
lines.append("    let p = path.hasPrefix(\"/\") ? path : \"/\" + path")
lines.append("    if nhsExactPaths.contains(p) { return true }")
lines.append("    return nhsWildcardSectionRoots.contains { p.hasPrefix($0 + \"/\") }")
lines.append("}")
lines.append("")
lines.append("/// The documented article/page response (schema.org shaped). We decode the")
lines.append("/// fields needed for grounding and citation: name (title), description")
lines.append("/// (snippet) and url. Modular pages expose extra text under `hasPart`.")
lines.append("struct NHSContentPage: Decodable {")
lines.append("    let name: String?")
lines.append("    let description: String?")
lines.append("    let url: String?")
lines.append("    let type: String?")
lines.append("    let hasPart: [NHSContentPart]?")
lines.append("")
lines.append("    enum CodingKeys: String, CodingKey {")
lines.append("        case name, description, url, hasPart")
lines.append('        case type = "@type"')
lines.append("    }")
lines.append("}")
lines.append("")
lines.append("struct NHSContentPart: Decodable {")
lines.append("    let name: String?")
lines.append("    let text: String?")
lines.append("    let description: String?")
lines.append("}")
lines.append("")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w").write("\n".join(lines) + "\n")
print(f"wrote {OUT}")
print(f"  paths: {len(cases)}  wildcard roots: {len(wildcard_roots)}  exact: {len(exact)}")
