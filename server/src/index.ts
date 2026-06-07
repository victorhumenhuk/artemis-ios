// Artemis token server (Cloudflare Worker).
//
// Two routes, and the app holds neither key:
//   POST /realtime/token     -> mints a short-lived OpenAI Realtime ephemeral
//                               key (ek_...) for a gpt-realtime-2 session.
//   GET  /nhs/content?path=  -> proxies the NHS Website Content API, injecting
//                               the NHS key server-side.
//
// Secrets come from env (.dev.vars locally, `wrangler secret put` in prod):
//   OPENAI_API_KEY, NHS_CONTENT_API_KEY
// Optional vars: NHS_BASE (defaults to the integration NHS base).

export interface Env {
  OPENAI_API_KEY: string;
  NHS_CONTENT_API_KEY: string;
  NHS_BASE?: string;
  // NHS Directory of Services (Private Key JWT auth).
  NHS_API_KEY?: string;        // the app's API key (consumer key); used as iss/sub
  NHS_PRIVATE_KEY?: string;    // PKCS8 RSA private key (PEM) — Worker secret, never committed
  DOS_SEARCH_BASE?: string;    // override the DoS Search base if the spec path differs
}

// ── NHS Directory of Services: signed-JWT auth ─────────────────────────────
const KID = "artemis-1";
const NHS_TOKEN_URL = "https://int.api.service.nhs.uk/oauth2/token";
// Public key as a JWK (RS512). The public key is not secret, so it is fine here.
// Generated from .keys/artemis_public.pem (see README "NHS DoS").
const JWK_N =
  "mbDIadGlnKh1Jn9NLes0CRBpTWAi1km9eN9xGwjBZiotGQ8HcX1ST6jcmCSgk_CeQWVM61j3d_TWusWUO2vPVuGB8n4objCdg09_lkZJc8URHxUfhz0AmLOqzb3xU3tWYRhC7ggUe6bwWYo3fg54btjLrEZBkqlbvfxC7QtCeLD0MEhvHyh1pARntNRTwSSIL0dpkBoQ21-VNQF-qxugf1jbL_ZuvQ6fjDX-L_emXDIffdOyooqwaLTYW_AKYdkeZFcb77NXJXTGJsUfu3ZOuPZQLfLocbpZSXb_CekVS4yxM7TkhP9xoZIqEQKzbByNwS11HaWDaMoPkowl2Cym9TiefC44d63dqtU36CV5YZTkEtOss9NOHAV7NM5MzLEe_2mBSES8XbiJE-JuiiYE5oq-WEgGDqoL3V1rAUfkhPBdetQTdHH7PDa5c3qxkRmTizz0hBIr8_dQPNWNX59c4F616TydcSy4oRlndD8vnqZ3lztd1-_uh1M3RGLejwEGyoYimjLYbFfc6xWKBKXQ1BBuvOMPcMXKLFQz_K3Wa9JJiv1UmcVzqxaUTYip03VEA-WtD1uSZCNfqEozwHzgTwaHrUZVkXISuCec3CQQG2bICZuFYtmLJaOpOAJr3_pCUYMaRFkqQUfLter8IQg2y4NtCVrtL8kHS--hy-SHRQk";

let tokenCache: { value: string; exp: number } = { value: "", exp: 0 };

function b64urlFromBytes(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlFromString(str: string): string {
  return b64urlFromBytes(new TextEncoder().encode(str));
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  // Tolerate both real newlines and literal "\n" (as stored in .dev.vars).
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" },   // RS512
    false,
    ["sign"],
  );
}

async function mintJWT(env: Env): Promise<string> {
  const apikey = env.NHS_API_KEY || "";
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS512", typ: "JWT", kid: KID };
  const claims = {
    iss: apikey, sub: apikey,
    aud: NHS_TOKEN_URL,
    jti: crypto.randomUUID(),
    iat: now,
    exp: now + 240,   // 4 minutes, within the 5-minute cap
  };
  const signingInput = `${b64urlFromString(JSON.stringify(header))}.${b64urlFromString(JSON.stringify(claims))}`;
  const key = await importPrivateKey(env.NHS_PRIVATE_KEY || "");
  const sig = await crypto.subtle.sign({ name: "RSASSA-PKCS1-v1_5" }, key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${b64urlFromBytes(new Uint8Array(sig))}`;
}

/// Mint+exchange a JWT for an access token, cached in memory until ~30s before exp.
async function getAccessToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (tokenCache.value && tokenCache.exp - 30 > now) return tokenCache.value;
  const jwt = await mintJWT(env);
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
    client_assertion: jwt,
  });
  const resp = await fetch(NHS_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  const data: any = await resp.json().catch(() => ({}));
  if (!resp.ok || !data.access_token) {
    throw new Error(`token ${resp.status}: ${JSON.stringify(data).slice(0, 300)}`);
  }
  tokenCache = { value: data.access_token, exp: now + (Number(data.expires_in) || 300) };
  return tokenCache.value;
}

// Keep these in lockstep with RealtimeConfig in the app.
const REALTIME_MODEL = "gpt-realtime-2";
const REALTIME_VOICE = "marin";

// Artemis identity for image assessment. Grounds the answer in the actual image,
// never invents a symptom, never diagnoses, no dashes.
const VISION_SYSTEM = [
  "You are Artemis, a calm, warm UK maternity companion. You are not a doctor and you never diagnose.",
  "First, briefly say what the image actually shows. Then answer her question grounded in what is in the image.",
  "If the image is not something you can assess for pregnancy safety (for example a photo of flowers), say so plainly and suggest the right source, her midwife, pharmacist, or asking about the specific food or medicine by name.",
  "Never invent a symptom she has not shown. Never escalate unless the image itself shows something urgent.",
  "For foods and medicines, base safety on NHS guidance. Keep it to two or three short sentences, plain British English, warm, non-judgemental.",
  "Never use dashes, use full stops and commas.",
].join(" ");

// Integration test environment. Auth is the `apikey` header (key only).
const NHS_INTEGRATION = "https://int.api.service.nhs.uk/nhs-website-content";

// Paths the proxy will forward. Mirrors specs/nhs-website-content.json so the
// server is not an open proxy. Exact paths plus per-page sub-paths under the
// documented wildcard sections.
const NHS_EXACT = new Set<string>([
  "/manifest/pages", "/health-a-to-z", "/health-a-to-z/conditions", "/conditions",
  "/symptoms", "/tests-and-treatments", "/medicines", "/mental-health", "/live-well",
  "/pregnancy", "/nhs-services", "/contraception", "/vaccinations", "/womens-health",
  "/baby", "/social-care-and-support",
]);
const NHS_WILDCARD_ROOTS = ["/conditions", "/medicines", "/pregnancy", "/baby", "/mental-health"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function nhsPathIsAllowed(path: string): boolean {
  const p = path.startsWith("/") ? path : "/" + path;
  if (NHS_EXACT.has(p)) return true;
  return NHS_WILDCARD_ROOTS.some((root) => p.startsWith(root + "/"));
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    // ── JWKS: public key for NHS to verify our signed JWT (no auth, https) ──
    if (url.pathname === "/jwks.json") {
      return json({ keys: [{ kty: "RSA", use: "sig", alg: "RS512", kid: KID, n: JWK_N, e: "AQAB" }] });
    }

    // ── Token milestone check: confirms the signed-JWT exchange works ───────
    // Returns the status WITHOUT exposing the access token.
    if (url.pathname === "/dos/token-check") {
      if (!env.NHS_API_KEY || !env.NHS_PRIVATE_KEY) return json({ ok: false, error: "NHS_API_KEY / NHS_PRIVATE_KEY not set" }, 500);
      try {
        const t = await getAccessToken(env);
        return json({ ok: true, has_token: t.length > 0, token_preview: t.slice(0, 6) + "…", expires_at: tokenCache.exp });
      } catch (e) {
        return json({ ok: false, error: String(e) }, 502);
      }
    }

    // ── Live nearest maternity unit via the Directory of Services ──────────
    // Always returns a usable answer: live when auth + DoS succeed, otherwise a
    // cached-fallback signal the app honours with its bundled units.
    if (url.pathname === "/dos/nearest") {
      const lat = url.searchParams.get("lat");
      const lng = url.searchParams.get("lng");
      const postcode = url.searchParams.get("postcode") || "";
      if (!env.NHS_API_KEY) return json({ source: "cached", fallback: true, reason: "DoS not configured" });
      try {
        // The Service Search API uses apikey auth, so no token is needed here.
        const unit = await dosNearestMaternity(env, "", { lat, lng, postcode });
        if (unit) return json({ source: "live", unit });
        return json({ source: "cached", fallback: true, reason: "no DoS match" });
      } catch (e) {
        // DoS failed (e.g. not subscribed): the app falls back to its cached lookup.
        return json({ source: "cached", fallback: true, reason: String(e).slice(0, 200) });
      }
    }

    // ── AI appointment prep: summarise her recent days into a midwife script ──
    if (url.pathname === "/summary" && request.method === "POST") {
      if (!env.OPENAI_API_KEY) return json({ error: "OPENAI_API_KEY not set" }, 500);
      try {
        const { context, language } = (await request.json()) as { context?: string; language?: string };
        if (!context) return json({ error: "missing context" }, 400);
        const lang = (language && language.trim()) || "English";
        const system = [
          "You are Artemis, a calm UK maternity companion. Write a short, FIRST-PERSON script she can read aloud to her midwife or maternity unit, summarising her last few days from the notes provided.",
          `Write the ENTIRE script in ${lang}. Warm, factual, concise. You never diagnose. Do not invent anything not in the notes.`,
          "Structure as 4 to 6 short sentences: how far along she is, why she is here, what she has noticed, any home readings, and that she would like to be assessed.",
          "NEVER use placeholders such as [Name], [date], or square brackets of any kind. If her name is not given, do not mention a name, just start with how far along she is.",
          "Put EACH sentence on its OWN line with a newline between them. Return ONLY the script sentences, no headings, no bullet points, no dashes.",
        ].join(" ");
        const resp = await fetch("https://api.openai.com/v1/chat/completions", {
          method: "POST",
          headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            model: "gpt-4o",
            max_tokens: 320,
            messages: [{ role: "system", content: system }, { role: "user", content: context }],
          }),
        });
        const data: any = await resp.json().catch(() => ({}));
        // On an OpenAI error, return empty text so the app falls back gracefully
        // rather than seeing a raw upstream error status.
        if (!resp.ok) return json({ text: "" });
        const text = data?.choices?.[0]?.message?.content ?? "";
        return json({ text });
      } catch (e) {
        return json({ error: "summary failed", detail: String(e) }, 502);
      }
    }

    // ── Mint an OpenAI Realtime ephemeral key ──────────────────────────────
    if (url.pathname === "/realtime/token" && request.method === "POST") {
      if (!env.OPENAI_API_KEY) return json({ error: "OPENAI_API_KEY not set" }, 500);
      try {
        const resp = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.OPENAI_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            session: {
              type: "realtime",
              model: REALTIME_MODEL,
              audio: { output: { voice: REALTIME_VOICE } },
            },
            expires_after: { anchor: "created_at", seconds: 600 },
          }),
        });
        const data = await resp.json();
        // The app reads the top-level `value` (GA) or client_secret.value (older).
        return json(data, resp.status);
      } catch (e) {
        return json({ error: "token mint failed", detail: String(e) }, 502);
      }
    }

    // ── Vision: assess an attached image, grounded in the image itself ─────
    if (url.pathname === "/vision" && request.method === "POST") {
      if (!env.OPENAI_API_KEY) return json({ error: "OPENAI_API_KEY not set" }, 500);
      try {
        const { image, prompt } = (await request.json()) as { image?: string; prompt?: string };
        if (!image) return json({ error: "missing image" }, 400);
        const resp = await fetch("https://api.openai.com/v1/chat/completions", {
          method: "POST",
          headers: { Authorization: `Bearer ${env.OPENAI_API_KEY}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            model: "gpt-4o",
            max_tokens: 240,
            messages: [
              { role: "system", content: VISION_SYSTEM },
              {
                role: "user",
                content: [
                  { type: "text", text: prompt && prompt.length > 0 ? prompt : "Is this safe in pregnancy?" },
                  { type: "image_url", image_url: { url: image } },
                ],
              },
            ],
          }),
        });
        const data: any = await resp.json().catch(() => ({}));
        // On an OpenAI error, return empty text so the app falls back gracefully
        // rather than seeing a raw upstream error status.
        if (!resp.ok) return json({ text: "" });
        const text = data?.choices?.[0]?.message?.content ?? "";
        return json({ text });
      } catch (e) {
        return json({ error: "vision failed", detail: String(e) }, 502);
      }
    }

    // ── Proxy the NHS Website Content API ──────────────────────────────────
    if (url.pathname === "/nhs/content" && request.method === "GET") {
      const path = url.searchParams.get("path") || "";
      if (!path) return json({ error: "missing path" }, 400);
      if (!nhsPathIsAllowed(path)) return json({ error: "path not allowed by spec" }, 400);

      const base = env.NHS_BASE || NHS_INTEGRATION;
      const target = base + (path.startsWith("/") ? path : "/" + path);

      // Cache successful responses at the edge.
      const cache = caches.default;
      const cacheKey = new Request(target, { method: "GET" });
      const cached = await cache.match(cacheKey);
      if (cached) return withCors(cached);

      try {
        const resp = await fetch(target, {
          headers: {
            apikey: env.NHS_CONTENT_API_KEY || "",
            Accept: "application/json",
          },
        });
        const body = await resp.text();
        const out = new Response(body, {
          status: resp.status,
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "public, max-age=3600",
            ...CORS,
          },
        });
        if (resp.ok) ctx.waitUntil(cache.put(cacheKey, out.clone()));
        return out;
      } catch (e) {
        return json({ error: "nhs proxy failed", detail: String(e) }, 502);
      }
    }

    if (url.pathname === "/" || url.pathname === "/health") {
      return json({ ok: true, service: "artemis-token-server", model: REALTIME_MODEL });
    }

    return json({ error: "not found" }, 404);
  },
};

function withCors(resp: Response): Response {
  const r = new Response(resp.body, resp);
  for (const [k, v] of Object.entries(CORS)) r.headers.set(k, v);
  return r;
}

interface NearestUnit { name: string; address: string; phone: string; distanceKm: number | null; }

/// Call the NHS Directory of Services Search API for the nearest maternity unit.
/// The search base is env-tunable (DOS_SEARCH_BASE) so the exact spec path can be
/// adjusted without a code change. Returns null on no match (caller falls back).
async function dosNearestMaternity(
  env: Env,
  token: string,
  loc: { lat: string | null; lng: string | null; postcode: string },
): Promise<NearestUnit | null> {
  // NHS Directory of Healthcare Services (Service Search) v3 — Azure Search.
  // Base = .../service-search-api, GET / with api-version=3, ordered by distance.
  const base = env.DOS_SEARCH_BASE || "https://int.api.service.nhs.uk/service-search-api";
  const params = new URLSearchParams({ "api-version": "3", search: "maternity", $top: "5" });
  if (loc.lat && loc.lng) {
    params.set("$orderby", `geo.distance(Geocode, geography'POINT(${loc.lng} ${loc.lat})') asc`);
  } else if (loc.postcode) {
    params.set("search", `maternity ${loc.postcode}`);
  }
  const target = `${base}/?${params.toString()}`;
  // The Service Search REST API uses API-KEY auth (apikey header), not the OAuth
  // token. (The signed-JWT token is kept for the JWT-authed DoS API.)
  void token;
  const resp = await fetch(target, {
    headers: { apikey: env.NHS_API_KEY || "", Accept: "application/json" },
  });
  if (!resp.ok) throw new Error(`dos ${resp.status}: ${(await resp.text()).slice(0, 120)}`);
  const data: any = await resp.json().catch(() => null);
  const items: any[] = data?.value ?? data?.results ?? [];
  if (!items.length) return null;
  const top = items[0];
  // Phone: prefer a Telephone contact.
  const contacts: any[] = top.Contacts ?? [];
  const tel = contacts.find((c) => String(c.ContactMethodType ?? "").toLowerCase().includes("tele"));
  const phone = tel?.ContactValue ?? contacts[0]?.ContactValue ?? "";
  // Distance: haversine from her point to the unit's coordinates.
  let distanceKm: number | null = null;
  if (loc.lat && loc.lng && top.Latitude != null && top.Longitude != null) {
    distanceKm = haversineKm(Number(loc.lat), Number(loc.lng), Number(top.Latitude), Number(top.Longitude));
  }
  return {
    name: top.OrganisationName ?? "NHS maternity unit",
    address: [top.Address1, top.Address2, top.City, top.Postcode].filter(Boolean).join(", "),
    phone,
    distanceKm,
  };
}

function haversineKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const R = 6371, toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return Math.round(R * 2 * Math.asin(Math.sqrt(a)) * 10) / 10;
}
