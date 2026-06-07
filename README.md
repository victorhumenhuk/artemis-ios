# Artemis

A voice-first maternity safety companion for the UK. Open the app and Artemis is
already listening. Speak a concerning symptom and she grounds her answer in NHS
guidance, returns a calm spoken verdict with a tier (routine, urgent, emergency),
shows a verdict card with the NHS citation and a one-tap call to the nearest
maternity unit, and can turn your logged history into an advocacy script for a
clinician. A text box is always present so you can type when you cannot talk.
Both voice and text feed the same engine and produce the same results.

Built with Swift, SwiftUI and Swift Concurrency, targeting **iOS 26**.

---

## Requirements

- macOS with **Xcode 26** (tested on Xcode 26.5).
- An **iOS 26 simulator** (e.g. iPhone 17 / 17 Pro on iOS 26.5) or a physical iPhone on iOS 26.
- **XcodeGen** to generate the project: `brew install xcodegen`.
- **Node + Wrangler** for the token server (Wrangler runs via `npx`, no global install needed).

---

## Quick start (90 seconds to the demo)

```bash
cd artemis-ios

# 1. Generate the Xcode project (with the pinned SDKs).
xcodegen generate            # reads project.yml

# 2. Open and run, or build from the CLI:
open Artemis.xcodeproj
#   in Xcode: pick an iPhone 17 (iOS 26) simulator and press Run.
```

The app runs **out of the box** with no server and no keys: it uses Apple's
on-device speech recognition and a local reasoning engine, grounded in the
cached NHS data. To enable the real OpenAI realtime voice, run the Worker (below)
and the app will use it automatically.

### Two project specs

- **`project.yml`** — the real spec. Adds the pinned SDKs (realtime voice,
  WhisperKit, RevenueCat).
- **`project.core.yml`** — a packages-free spec for fast iteration. The app
  compiles and runs identically because every SDK use is wrapped in
  `#if canImport(...)`. Generate it with
  `xcodegen generate --spec project.core.yml`.

CLI build (simulator):

```bash
xcodebuild build -project Artemis.xcodeproj -scheme Artemis \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation -skipMacroValidation
```

For a **physical device**: open the project, select the Artemis target → Signing
& Capabilities, set your Development Team, and run. The app needs mic, speech and
(for nearest-unit) location permission.

---

## Pinned SDKs

Declared in `project.yml`, each isolated behind `#if canImport(...)` so the app
still builds if any is removed:

| SDK | Package | Used for |
| --- | --- | --- |
| Realtime voice | `github.com/m1guelpf/swift-realtime-openai` (branch `main`) | OpenAI GA Realtime over WebRTC |
| On-device STT | `github.com/argmaxinc/argmax-oss-swift` (WhisperKit) | offline transcription |
| Paywall | `github.com/RevenueCat/purchases-ios-spm` | cosmetic freemium |
| On-device LLM | Apple **FoundationModels** (in the iOS 26 SDK, no SPM) | offline structuring + fallback |

`swift-realtime-openai` pulls a prebuilt WebRTC binary and swift-syntax macros,
so the first package resolve takes a few minutes.

### SDK patch (realtime voice)

`swift-realtime-openai` is **vendored** in `ThirdParty/swift-realtime-openai`
(from `m1guelpf/swift-realtime-openai`, branch `main`) with one small fix: its
`Conversation.handleEvent` did not handle `response.output_item.added`, so for
the GA `gpt-realtime-2` event stream the model's replies and tool calls never
populated `entries` (audio played, but transcripts and function calls were
invisible). The patch appends those items (and upserts `response.output_item.done`).
Two clearly-commented cases in `Sources/UI/Conversation.swift`. `project.yml`
references the local copy via `path:` instead of the GitHub URL. To re-apply on a
fresh clone of upstream, add the `responseOutputItemAdded`/`responseOutputItemDone`
handlers shown there.

---

## The keys (server only — never in the app)

The app target contains **no OpenAI or NHS key**. They live only on the server.

- `server/.dev.vars` holds the secrets for local `wrangler dev`. It is
  **gitignored**. A starter `server/.dev.vars` has been created with the OpenAI
  key you provided.
- **Rotate that OpenAI key.** It was shared in a plaintext file, so treat it as
  compromised: create a new key at platform.openai.com and replace it in
  `server/.dev.vars`.
- `NHS_CONTENT_API_KEY` is a placeholder. Get a free key for the NHS Website
  Content API from the [NHS developer portal](https://digital.nhs.uk/developer),
  and put it in `server/.dev.vars`. Without it the app still works: NHS grounding
  falls back to the cached snippets in `RedFlagIndex.json`.

---

## Running the token server

```bash
cd server
npm install
# edit .dev.vars: set OPENAI_API_KEY (rotate it) and NHS_CONTENT_API_KEY
npm run dev          # wrangler dev, serves http://localhost:8787
```

Routes:

- `POST /realtime/token` → mints a short-lived OpenAI Realtime ephemeral key
  (`ek_...`) for a `gpt-realtime-2` session (voice `marin`). The app uses it for
  the WebRTC handshake.
- `GET /nhs/content?path=/conditions/pre-eclampsia` → proxies the NHS Website
  Content API, injecting the NHS key server-side. Only paths defined in the spec
  are forwarded.

### Point the app at the server

`RealtimeConfig.serverBaseURL` reads `ArtemisServerBaseURL` from `Info.plist`
(default `http://localhost:8787`).

- **Simulator**: `http://localhost:8787` works as-is.
- **Physical device**: change `ArtemisServerBaseURL` in
  `Artemis/Resources/Info.plist` to your Mac's LAN IP (e.g.
  `http://192.168.0.10:8787`, run `wrangler dev --ip 0.0.0.0`), or deploy with
  `npm run deploy` and use the `*.workers.dev` URL.

If the server is unreachable, the app automatically falls back to the on-device
voice path. To force on-device only, set `ArtemisUseRealtime` to `NO` in Info.plist.

The app allows plaintext HTTP to `localhost`/`.local` for the dev Worker
(`NSAllowsLocalNetworking` in Info.plist). A deployed `https://*.workers.dev`
URL needs no exception.

### Diagnostics screen

Triple-tap the version number at the bottom of Settings to open a hidden
diagnostics screen. It shows live status for the voice session, the token
server, the NHS content API and the last minted ephemeral key, with a
**Run checks** button and a **Disable NHS retrieval** switch that proves
Artemis refuses and escalates (to NHS 111) rather than guessing when no
grounding is available.

Deploy to production:

```bash
cd server
npx wrangler secret put OPENAI_API_KEY
npx wrangler secret put NHS_CONTENT_API_KEY
npm run deploy
```

---

## The demo path, end to end

1. Launch the app. After the ~40s first-run setup it opens straight into
   **listening** and plays one short greeting.
2. Say (or type): *"I've got a pounding headache and my hands are really puffy
   and I'm seeing flashing."*
3. Artemis retrieves NHS guidance, then returns an **emergency** verdict card:
   *Signs of pre-eclampsia*, the red flags she noticed, the recommended action,
   the **NHS citation** (tappable), and a one-tap **Call** to the nearest
   maternity unit.
4. Tap **Turn this into a script for my midwife** for the advocacy handover.
5. The chart icon opens **Your week** (mood, symptoms, BP, kicks). The gear opens
   Settings (the two session toggles, export, delete everything).
6. After dark, or in system dark mode, the whole app switches to **moonlit mode**
   and the orb becomes a glowing moon.

### QA / screenshot hooks (optional)

Launch env vars drive a scripted demo without touching the mic (handy for
screenshots and CI):

```bash
xcrun simctl launch <device> com.artemis.app   # normal

# scripted (typed input, on-device engine, no permission prompts):
SIMCTL_CHILD_ARTEMIS_DEMO=triage   SIMCTL_CHILD_ARTEMIS_FORCE_LOCAL=1 xcrun simctl launch <device> com.artemis.app
# ARTEMIS_DEMO = home | triage | checkin | crisis | trends | settings | paywall
# ARTEMIS_MOONLIT=1 forces the night palette.
```

---

## NHS clients, generated from the OpenAPI specs

The specs you provided are in `specs/`:

- `specs/nhs-website-content.json` — NHS Website Content API v2.
- `specs/nhs-dohs-v3.json` — Directory of Healthcare Services v3 (kept behind a
  feature flag; the demo uses the cached `maternity_units.json` as instructed).

`scripts/generate_nhs_client.py` reads the Content spec and emits
`Artemis/Core/NHS/NHSContentGenerated.swift` (the allowed path set + the typed
page model), so the client can only ever call endpoints defined in the spec, and
the Worker proxy validates the same path set. Re-run after the spec changes:

```bash
python3 scripts/generate_nhs_client.py
```

**Alternative (Apple's generator):** to use `apple/swift-openapi-generator`
instead, copy `specs/nhs-website-content.json` to the target as `openapi.json`,
add an `openapi-generator-config.yaml` (`generate: [types, client]`), add the
`OpenAPIGenerator` build-tool plugin plus `swift-openapi-runtime` and
`swift-openapi-urlsession`, and trust the plugin. The hand-rolled generated
client is used by default because the build-tool plugin needs interactive trust
(or `-skipPackagePluginValidation`) under headless `xcodebuild`.

---

## Architecture

```
Artemis/
  ArtemisApp.swift                  app entry, moonlit palette resolution, router
  Core/
    State/ConversationStateMachine  the four states (listening, silentTyping, thinking, responding) + idle
    State/ConversationEngine        the brain: owns state, voice client, tools, transcript
    Voice/RealtimeVoiceClient       protocol isolating the voice transport
    Voice/OpenAIRealtimeClient      OpenAI GA Realtime over WebRTC (gpt-realtime-2, marin), behind canImport
    Voice/LocalVoiceClient          on-device SFSpeech + AVSpeech (always available)
    Voice/Tools                     tool schemas + ToolDispatcher (voice and text share this)
    Voice/AudioSessionManager
    Triage/TriageModels             the data contracts (TriageResult, CheckinLog, ...)
    Triage/LocalReasoner            offline brain; drives the same tools as the model
    Triage/AdvocacyBuilder          deterministic advocacy script from the log
    Grounding/RedFlagIndex(.json)   symptom -> NHS article routing (~16 conditions)
    Grounding/Insights              pattern detection + the "Your week" trends
    NHS/NHSContentClient            calls the Worker proxy, caches, returns citations
    NHS/NHSContentGenerated         GENERATED from specs/nhs-website-content.json
    Services/ServiceLocator(.json)  nearest maternity unit (cached list) + CoreLocation
    Offline/OnDeviceFallback        WhisperKit + cautious offline response
    Offline/OnDeviceOrganizer       FoundationModels @Generable check-in structuring
    Storage/Models, Store           SwiftData, on device only
    Paywall/Entitlements            RevenueCat wrapper (cosmetic)
    Config/RealtimeConfig           model string, voice, server URL, system prompt
    Theme/                          design tokens (light + moonlit), fonts
  Features/                         every screen, built to the attached designs
server/                             Cloudflare Worker (token + NHS proxy)
specs/                              the NHS OpenAPI specs you provided
scripts/generate_nhs_client.py
```

The design principle: the home screen **is** a state machine. Tapping the text
box atomically mutes the mic, raises the keyboard, and switches to text-only
replies. A mic toggle is reachable in every state. Intent (check-in vs triage vs
crisis) is inferred from what she says, never from a button.

---

## Safety

- Never presents output as a diagnosis; signposts and triages only.
- Uncertainty always escalates upward (the red-flag matcher and the dispatcher
  both refuse to drop below the routed tier).
- Crisis language follows a gentle support path: no assessment questions, no
  methods, Samaritans 116 123 surfaced with one-tap call. Never gated.
- No raw audio is ever stored (transcript text only). No login. No immigration
  data. No GP Connect / PDS / e-Referral.

---

## Known limitations / what was verified

- **Verified on the iOS 26.5 simulator**: both build specs compile clean, the
  app launches, and the whole on-device path works end to end (onboarding,
  listening, triage verdict with NHS citation + nearest-unit call, crisis,
  structured check-in with cross-day pattern, trends, settings, paywall, moonlit
  auto-switch). Screenshots are in `docs/screenshots/`.
- **Token server verified live**: running the Worker, `POST /realtime/token`
  mints a real OpenAI ephemeral key (`ek_...`) for a `gpt-realtime-2` session,
  confirmed in the diagnostics screen. The NHS proxy reaches the NHS API and
  injects the key; with the placeholder NHS key it returns HTTP 401 and the app
  falls back to the real cached nhs.uk citations.
- **OpenAI GA Realtime verified live on the simulator** (with the Worker
  running and mic permission granted): the session connects over WebRTC with
  `model=gpt-realtime-2` and `voice=marin`, audio deltas stream back (the model
  speaks), the model's transcript renders as bubbles, and it calls
  `retrieve_nhs_guidance` to ground its answer. Confirmed in the logs and the
  connection overlay. A spoken mic round-trip (talking, not typing) still wants a
  real device, but typed turns drive the full model pipeline on the sim.
- **No silent impersonation while online.** If realtime cannot connect (e.g. the
  Worker is not running), the app shows "I can't reach my voice" with Retry and
  does NOT fall back to on-device speech or templated text. On-device runs only
  when there is genuinely no network, shown as a "Voice offline" state. Toggle
  the live connection overlay in Settings → Developer.
- **Safety guard**: a triage result without a valid, tappable NHS source is
  blocked and replaced with a safe NHS 111 escalation (verified with retrieval
  disabled).
- **FoundationModels** and **WhisperKit** only run on a capable physical device
  (not the Simulator); the app gates on availability and falls back gracefully.
- The maternity unit phone numbers in `maternity_units.json` are switchboard
  lines and **must be verified** against current NHS listings before real use.
- The paywall is cosmetic: no feature is actually locked, and safety is never
  gated.
```
