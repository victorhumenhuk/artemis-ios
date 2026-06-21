# Decision Ledger — artemis-ios

Durable record of the significant decisions made in this repository and the reasoning behind them.

- **Confirmed** decisions are human-reviewed and binding. This section is maintained by the repository owner; the automated decision-ledger pass never edits it.
- **Inferred** decisions are hypotheses proposed automatically from the code, commit history, and any agent instructions (CLAUDE.md / AGENTS.md). They are **not binding** until the owner moves them into Confirmed.

## Confirmed

_None yet. Merge a proposal from Inferred to confirm it._

## Inferred (proposed — awaiting confirmation)

> Every item below is a hypothesis generated automatically on 2026-06-21. Where the rationale could not be recovered from the available evidence it is marked "rationale unknown — please supply".

### [hypothesis] Native SwiftUI + Swift Concurrency app targeting iOS 26
- **Decision:** Build Artemis as a native Swift / SwiftUI app using Swift Concurrency (async/await, actors), targeting iOS 26 exclusively.
- **Rationale (hypothesis):** iOS 26 is required to access the platform features the product depends on — Apple FoundationModels (on-device LLM) and the iOS 26 speech stack — and SwiftUI + structured concurrency is Apple's current-generation app model. README states the app is "Built with Swift, SwiftUI and Swift Concurrency, targeting iOS 26."
- **Evidence:** `README.md` lines 11, 17-18; `project.yml` (`deploymentTarget.iOS: "26.0"`); `Artemis/Core/State/ConversationEngine.swift`; initial commit `fb56ebe`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Swift 5 language mode with minimal strict concurrency (not Swift 6)
- **Decision:** Set `SWIFT_VERSION: "5.0"` and `SWIFT_STRICT_CONCURRENCY: minimal` rather than adopting Swift 6 strict data-race enforcement.
- **Rationale (hypothesis):** Stated inline in the spec — Swift 6 strict data-race enforcement "would otherwise drown an MVP in build errors"; Swift 5 mode keeps full async/await + actors without that cost.
- **Evidence:** `project.yml` settings comment and `SWIFT_VERSION` / `SWIFT_STRICT_CONCURRENCY` keys.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Every third-party SDK isolated behind `#if canImport(...)`
- **Decision:** Wrap every use of the pinned SDKs (Realtime voice, WhisperKit, RevenueCat) in `#if canImport(...)` so the app compiles and fully runs even with the packages block empty, and maintain two build specs: `project.yml` (real, with SDKs) and `project.core.yml` (packages-free, for fast iteration).
- **Rationale (hypothesis):** Enables fast core iteration without resolving heavy packages (the realtime SDK pulls a prebuilt WebRTC binary + swift-syntax macros, so first resolve takes minutes) and guarantees graceful degradation if any SDK is removed.
- **Evidence:** `README.md` lines 42-91; `project.yml` packages comment; `project.core.yml`; `canImport` guards across 5 source files.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Keys live only on a Cloudflare Worker token server; the app holds no secrets
- **Decision:** Put no OpenAI or NHS key in the iOS app. A Cloudflare Worker (`/server`) mints short-lived OpenAI Realtime ephemeral keys and proxies the NHS Content API, injecting secrets server-side. Secrets come from `.dev.vars` (gitignored) locally and `wrangler secret put` in production.
- **Rationale (hypothesis):** Shipping long-lived API keys inside a distributed client is a credential-exposure risk; minting ephemeral keys and proxying server-side keeps the secrets off the device.
- **Evidence:** `README.md` lines 95-164; `server/src/index.ts` (`/realtime/token`, `/nhs/content`); `.gitignore` (`server/.dev.vars`); initial commit message `fb56ebe`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] NHS proxy is an allow-list, not an open proxy
- **Decision:** The Worker only forwards NHS Content API paths that match a fixed exact-set plus a few wildcard roots, mirroring `specs/nhs-website-content.json`. A generator (`scripts/generate_nhs_client.py`) emits the allowed path set for the Swift client so client and server validate the same paths.
- **Rationale (hypothesis):** Prevents the token server from being abused as a general-purpose proxy and ensures the client can only call endpoints defined in the spec.
- **Evidence:** `server/src/index.ts` lines 113-141 (`NHS_EXACT`, `NHS_WILDCARD_ROOTS`, `nhsPathIsAllowed`); `README.md` lines 200-215; `scripts/generate_nhs_client.py`; `Artemis/Core/NHS/NHSContentGenerated.swift`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] OpenAI GA Realtime (`gpt-realtime-2`, voice `marin`) over WebRTC; no beta endpoints
- **Decision:** Use the OpenAI GA Realtime model `gpt-realtime-2` with voice `marin` over WebRTC, centralised in one config constant, and never use `gpt-4o-realtime-preview` or any beta endpoint. The app and Worker keep the model/voice constants in lockstep.
- **Rationale (hypothesis):** Stated in code — "The beta interface was removed on 12 May 2026, so we never use gpt-4o-realtime-preview or any beta endpoint." Single constant makes swapping the model trivial.
- **Evidence:** `Artemis/Core/Config/RealtimeConfig.swift` lines 8-17; `server/src/index.ts` lines 95-97, 221-251.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Vendor and patch `swift-realtime-openai` rather than depend on upstream directly
- **Decision:** Vendor `m1guelpf/swift-realtime-openai` into `ThirdParty/swift-realtime-openai` and reference it via a local `path:` in `project.yml`, applying a patch so `response.output_item.added` / `.done` events populate `entries`.
- **Rationale (hypothesis):** Upstream `Conversation.handleEvent` did not handle `response.output_item.added`, so for the GA `gpt-realtime-2` event stream the model's transcripts and tool calls were invisible (audio played but entries never populated). Vendoring lets the fix ship without waiting on upstream.
- **Evidence:** `README.md` lines 80-91; `project.yml` packages (`RealtimeOpenAI: path: ThirdParty/swift-realtime-openai`); `ThirdParty/swift-realtime-openai`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Voice and text share one engine; the home screen is a state machine
- **Decision:** Both voice and text input feed the same `ConversationEngine` and `ToolDispatcher` and produce identical results. The home screen is modelled as a four-state machine (listening, silentTyping, thinking, responding); tapping the text box atomically mutes the mic, raises the keyboard, and switches to text-only replies. Intent (check-in vs triage vs crisis) is inferred from what the user says, never from a button.
- **Rationale (hypothesis):** Keeps behaviour consistent across modalities and matches the product's voice-first design principle that "the home screen is a state machine." rationale beyond the stated design principle unknown — please supply.
- **Evidence:** `README.md` lines 8-9, 229-263; `Artemis/Core/State/ConversationStateMachine.swift`; `Artemis/Core/State/ConversationEngine.swift`; `Artemis/Core/Voice/Tools.swift`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Layered offline / on-device fallback, with no silent impersonation while online
- **Decision:** Provide a `RealtimeVoiceClient` protocol with two implementations: `OpenAIRealtimeClient` (preferred when online) and `LocalVoiceClient` (on-device SFSpeech + AVSpeech, plus WhisperKit and FoundationModels). The app falls back to on-device only when there is genuinely no network. If realtime cannot connect while online, it shows "I can't reach my voice" with Retry and does NOT silently fall back to on-device or templated text.
- **Rationale (hypothesis):** Keeps the app usable offline while avoiding misleading the user into thinking they are talking to the full model when they are not; on-device models also only run on capable physical hardware.
- **Evidence:** `README.md` lines 37-40, 141-142, 298-307; `Artemis/Core/Voice/RealtimeVoiceClient.swift`, `OpenAIRealtimeClient.swift`, `LocalVoiceClient.swift`; `Artemis/Core/Offline/OnDeviceFallback.swift`, `OnDeviceOrganizer.swift`, `Reachability.swift`; commit `f30e68a`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Safety-first triage: never diagnose, always escalate upward, NHS-grounded
- **Decision:** Treat every symptom as a triage with an explicit tier (reassuring / self_care / routine / urgent / emergency); never present output as a diagnosis; resolve uncertainty by escalating to the higher tier; require an NHS source for any red-flag guidance. A triage result without a valid, tappable NHS source is blocked and replaced with a safe NHS 111 escalation. The crisis/self-harm path is gentle, never gated, and surfaces Samaritans 116 123.
- **Rationale (hypothesis):** This is a maternity safety product where a falsely reassuring answer is the dangerous failure mode; the safety section codifies "uncertainty always escalates upward" and the red-flag matcher and dispatcher both refuse to drop below the routed tier.
- **Evidence:** `README.md` lines 267-276, 303-305; `Artemis/Core/Triage/SafeChecker.swift`; `Artemis/Core/Triage/LocalReasoner.swift`; `Artemis/Core/Grounding/RedFlagIndex.json`; `RealtimeConfig.systemPrompt` (rules 1-8) in `Artemis/Core/Config/RealtimeConfig.swift`; commits `953d597`, `883e39d`.
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Triage floor scans structured signals only, not free-text spoken replies
- **Decision:** Change the triage-floor over-escalation guard so it scans only the structured signals of what is present (`matched_condition` + `red_flags_detected`) with qualified phrasing, rather than scanning the model's free-text spoken response.
- **Rationale (hypothesis):** Stated in the commit — scanning the spoken reply caused educational reassurance ("…but if you get sudden swelling in your face, call your midwife") to force benign symptoms (mild ankle swelling, postural dizziness) to URGENT; structured-signal scanning fixes the false escalation while keeping genuine pre-eclampsia signs at EMERGENCY.
- **Evidence:** Commit `f30e68a` (Audit fixes: triage precision...); `Artemis/Core/Triage/SafeChecker.swift`.
- **First observed:** `f30e68a` (2026-06-10)

### [hypothesis] System prompt enforces strict spoken-audio and British-English rules
- **Decision:** Encode a large, explicit system prompt that forbids spoken reasoning/preamble/filler (one user turn → one short final spoken reply), mandates British English and NHS routing terms (999 / 111 / A&E, never US terms), forces voice/card route consistency, and constrains tool-calling behaviour.
- **Rationale (hypothesis):** The model otherwise spoke lead-ins, narrated tool calls, used American terminology, or let its spoken route diverge from the card's tier; the prompt rules were progressively hardened to make spoken output calm, consistent, and clinically safe.
- **Evidence:** `RealtimeConfig.systemPrompt` in `Artemis/Core/Config/RealtimeConfig.swift` lines 32-59; commits `bf4e055`, `a04486b`, `a416c16` (voice narration / echo rules).
- **First observed:** `fb56ebe` (2026-06-07); hardened through `f30e68a` (2026-06-10)

### [hypothesis] Local-only, privacy-minimal data storage via SwiftData
- **Decision:** Persist user data (check-ins, mood, BP, kicks) on device only via SwiftData. Store no raw audio (transcript text only), require no login, and exclude immigration data and GP Connect / PDS / e-Referral integrations.
- **Rationale (hypothesis):** Maternity health data is sensitive; an on-device-only, login-free, audio-free model minimises data exposure and regulatory surface for an MVP. Specific scope exclusions (immigration data, GP Connect) suggest deliberate privacy/compliance boundaries — exact rationale unknown — please supply.
- **Evidence:** `README.md` lines 275-276, 251; `Artemis/Core/Storage/Models.swift`, `Store.swift`; architecture note "Storage/Models, Store — SwiftData, on device only".
- **First observed:** `fb56ebe` (2026-06-07)

### [hypothesis] Live caption built without contending for the mic against WebRTC
- **Decision:** Implement live captioning in a way that does not fight WebRTC for the microphone, after reverting an earlier voice-processing approach that broke on-device transcription.
- **Rationale (hypothesis):** Earlier attempts that enabled voice-processing or ran a conflicting on-device mic broke transcription and caused the voice to cut out; the caption was reworked to coexist with the WebRTC audio path.
- **Evidence:** Commit `fcefe28` (Live caption without fighting WebRTC for the mic); commit `a416c16` ("Live caption: revert voice-processing (it broke on-device transcription)"); commit `14734ac` (drop conflicting on-device mic); `Artemis/Core/Voice/LiveTranscriber.swift`.
- **First observed:** `14734ac` (2026-06-07); finalised `fcefe28` (2026-06-10)

### [hypothesis] RevenueCat paywall is cosmetic; no feature or safety path is gated
- **Decision:** Integrate RevenueCat for a freemium paywall, but make it cosmetic — no feature is actually locked and safety is never gated.
- **Rationale (hypothesis):** Demonstrates a monetisation surface for an MVP while preserving the safety guarantee that critical guidance is never paywalled. rationale unknown — please supply.
- **Evidence:** `README.md` lines 74, 311; `Artemis/Core/Paywall/Entitlements.swift`; `Artemis/Features/Paywall/PaywallView.swift`; `project.yml` (RevenueCat package).
- **First observed:** `fb56ebe` (2026-06-07)

---
*Decision-ledger automated pass. Operation: Bootstrap. Last reflection: commit `f30e68a` (2026-06-21). Decisions above are AI-inferred hypotheses; nothing is binding until merged into Confirmed.*
