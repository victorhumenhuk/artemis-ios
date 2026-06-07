//  ConversationEngine.swift
//  The heart of Artemis. Owns the state machine, the transcript, the active
//  voice client, the tool dispatcher and (offline only) the local reasoner.
//
//  While ONLINE the realtime model is the only source of replies and audio.
//  There is no silent on-device impersonation: if realtime cannot connect we
//  show a visible failed state, never local speech or templated text. The
//  on-device path runs only when there is genuinely no network, clearly labelled.

import Foundation
import Observation
import SwiftUI
import AVFoundation

/// A tappable next step under an assistant message. Every assistant turn ends in
/// at least one of these, so there is never a bare text reply.
enum MessageAction: String, Identifiable, Equatable {
    case call999, call111, callMidwife, findNearestUnit, seeGuidance, checkWithPro, turnIntoScript, logThis, imOkay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .call999: return "Call 999"
        case .call111: return "Call 111"
        case .callMidwife: return "Call your midwife"
        case .findNearestUnit: return "Find nearest unit"
        case .seeGuidance: return "See NHS guidance"
        case .checkWithPro: return "Check with a pharmacist or midwife"
        case .turnIntoScript: return "Turn this into a script"
        case .logThis: return "Log this"
        case .imOkay: return "I'm okay for now"
        }
    }
    var icon: String {
        switch self {
        case .call999, .call111, .callMidwife, .checkWithPro: return "phone"
        case .findNearestUnit: return "location"
        case .seeGuidance: return "shield"
        case .turnIntoScript: return "person"
        case .logThis: return "heart"
        case .imOkay: return "check"
        }
    }
    /// Emergency/urgent actions get the saturated tone; the rest are calm.
    var urgent: Bool { self == .call999 || self == .call111 }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case her, artemis }
    let id = UUID()
    let role: Role
    var text: String
    var imageData: Data? = nil
    var date: Date = Date()
    var actions: [MessageAction] = []
    var nhsTitle: String? = nil   // NHS source shown under a clinical reply
    var nhsURL: String? = nil
}

enum ActiveSheet: Identifiable, Equatable {
    case verdict, advocacy, crisis, paywall
    var id: String { String(describing: self) }
}

enum AppView { case home, history, settings }

enum VoiceMode: String { case connecting, realtime, offline, failed }

/// The four failure modes, kept distinct so logs and the UI say WHY.
enum VoiceFailureReason: String {
    case none, offline, micDenied, audioUnavailable, tokenFailed, connectionFailed
}

@MainActor @Observable
final class ConversationEngine: NSObject {
    // visible state
    var messages: [ChatMessage] = []
    var interim: String = ""
    var view: AppView = .home
    var sheet: ActiveSheet?

    // verdict / advocacy / crisis payloads
    var verdict: TriageResult?
    var verdictService: NearestService?
    var verdictUnit: MaternityUnit?
    var verdictUncertain = false   // safe-check not found in guidance → chips say "check with a professional"
    var verdictIsSafeCheck = false // food/medicine safe-check → informational chips, not "call your midwife"
    var advocacy: AdvocacyScript?
    var crisis: CrisisSupport = .default

    // voice mode + live diagnostics (shown in the debug overlay)
    var voiceMode: VoiceMode = .connecting
    var voiceFailureReason: VoiceFailureReason = .none
    var realtimeState: String = "idle"          // from the real WebRTC status
    var lastReplySource: String = "—"           // "realtime" | "local-fallback"
    var lastTokenStatus: String = "—"           // HTTP status from the token server
    var didReceiveModelAudio = false            // audio deltas seen from the model
    var activeModel: String { RealtimeConfig.model }
    var activeVoice: String = RealtimeConfig.voice

    // dependencies
    let store: Store
    let entitlements: Entitlements
    let stateMachine = ConversationStateMachine()

    private let dispatcher: ToolDispatcher
    private let reasoner: LocalReasoner
    private var voiceClient: RealtimeVoiceClient?
    private var permissionsGranted = false
    private var turnBubbleID: UUID?                  // the ONE assistant bubble for the current turn
    private var persistedBubbleIDs = Set<UUID>()
    private var userBubbleMap: [String: UUID] = [:]  // transcription item id -> her live bubble
    private var persistedUserItems = Set<String>()
    private var isReturning = false

    /// True once she has engaged this session (typed, spoke, or tapped a chip).
    /// The thread is loaded on launch but only shown after engagement, so opening
    /// the app is a calm orb, not a wall of past text.
    var sessionEngaged = false
    private var idleTimer: Timer?
    private func engage() { sessionEngaged = true; bumpIdle() }

    /// Reset the quiet-spell timer on any activity.
    private func bumpIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 110, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.returnToRest() }
        }
    }

    /// After a quiet spell, drift gently back to the calm orb home ("How are you
    /// feeling today?"), with the breathing lamp. Never interrupts an open sheet or
    /// a reply in progress.
    func returnToRest() {
        guard sheet == .none, activeChip == nil,
              stateMachine.state != .responding, stateMachine.state != .thinking else { bumpIdle(); return }
        interim = ""   // never leave a stale live caption behind when we settle to rest
        withAnimation(.easeInOut(duration: 0.7)) {
            sessionEngaged = false
            view = .home
        }
    }

    /// Observable onboarding gate. The store's `hasCompletedOnboarding` is not
    /// observed by SwiftUI, so the root view watches this instead. Without it,
    /// tapping Start saved the profile but never switched to the home (the hang).
    var onboarded = false

    /// Bumped on every profile change so SwiftUI views (which read the SwiftData
    /// profile via a non-observed fetch) re-render immediately. The single source
    /// of truth is the stored profile; this is the observation trigger.
    var profileRev = 0

    /// Change the profile and re-apply it everywhere: bumps profileRev so every
    /// screen refreshes immediately. When reconnect is true (stage, weeks,
    /// language, name, ethnicity) it also tears down + reopens the realtime
    /// session with the new instructions. Appearance/toggles pass reconnect=false.
    func applyProfileChange(reconnect: Bool = true, _ change: (UserProfile) -> Void) {
        guard let p = store.profile() else { return }
        change(p)
        do { try store.context.save() } catch { ArtemisLog.error("Profile save failed: \(error)") }
        profileRev += 1
        if reconnect { reconnectVoice() }
    }

    /// Her chosen interface language (drives on-screen strings + RTL).
    var uiLanguage: String { store.profile()?.language ?? "English" }

    var state: ConversationState { stateMachine.state }
    var isSilent: Bool { stateMachine.isSilent }
    /// She tapped the wave/orb to stop. The VAD poll must not re-arm listening
    /// until she explicitly starts again.
    private var micPaused = false
    /// On launch the mic is muted until the opening greeting finishes, so her
    /// first words are not captured mid-greeting.
    private var awaitingGreeting = false
    /// Auto-reconnect on a mid-session drop, so it never silently sticks on
    /// "Tap to reconnect".
    private var isReconnecting = false
    private var reconnectAttempt = 0
    /// Debounce token for the standalone nearest-unit card, so a red-flag verdict
    /// wins over a routine "nearest unit" card in the same turn.
    private var pendingNearestToken: UUID?
    var micHot: Bool { stateMachine.state.micHot && !stateMachine.micMuted && !micPaused }
    var usingRealtime: Bool { voiceMode == .realtime && voiceClient?.handlesReasoning == true }
    var connectionFailed: Bool { voiceMode == .failed }
    var voiceOffline: Bool { voiceMode == .offline }

    var voiceStatus: String {
        switch voiceMode {
        case .connecting: return "connecting…"
        case .realtime: return "OpenAI realtime, \(realtimeState)"
        case .offline: return "on-device (voice offline)"
        case .failed: return "connection failed"
        }
    }

    /// ONE honest status line for the conversation, stating the real reason
    /// when voice is off. Replaces the old competing banners.
    var statusLine: String {
        let lang = uiLanguage
        switch voiceMode {
        case .connecting: return L("connecting", lang)
        case .failed: return L("reconnect", lang)
        case .offline:
            return voiceFailureReason == .offline ? L("needConnStatus", lang) : L("reconnect", lang)
        case .realtime:
            if stateMachine.isSilent { return L("silent", lang) }
            switch stateMachine.state {
            case .responding: return L("speaking", lang)
            case .thinking: return L("checking", lang)
            default:
                return voiceFailureReason == .micDenied
                    ? L("silent", lang)
                    : L("listening", lang)
            }
        }
    }
    var statusIsLive: Bool {
        voiceMode == .realtime && voiceFailureReason != .micDenied
            && stateMachine.state.isLive && !stateMachine.isSilent
            && (stateMachine.state != .listening || micHot)   // not "live listening" if the mic is paused
    }
    var canRetryVoice: Bool {
        voiceMode == .offline || voiceMode == .failed   // always offer a way forward
    }

    init(store: Store, entitlements: Entitlements) {
        self.store = store
        self.entitlements = entitlements
        self.dispatcher = ToolDispatcher(store: store)
        self.reasoner = LocalReasoner(store: store, dispatcher: dispatcher)
        super.init()
        self.dispatcher.delegate = self
        self.onboarded = store.hasCompletedOnboarding
    }

    // MARK: session lifecycle

    func startSession() async {
        let profile = store.profile()
        let demoMode = ProcessInfo.processInfo.environment["ARTEMIS_DEMO"] != nil

        // Restore the persistent chat thread so the conversation survives relaunch.
        if messages.isEmpty {
            messages = store.recentThread(limit: 200).map {
                ChatMessage(role: $0.roleRaw == "her" ? .her : .artemis, text: $0.text, imageData: $0.imageData, date: $0.date)
            }
        }
        let returning = !messages.isEmpty   // don't re-greet someone she remembers
        isReturning = returning

        if !demoMode {
            permissionsGranted = await LocalVoiceClient.requestPermissions()
        }

        if profile?.startInSilentMode == true {
            stateMachine.lockSilent(true)
        } else if profile?.listenOnOpen == false {
            stateMachine.goIdle()
        } else {
            stateMachine.enterListening()
        }

        // Resolve her location BEFORE connecting, so the SINGLE session already has
        // it. The old design connected, then reconnected to inject location, which
        // re-greeted on launch (the duplication). One connection now → one greeting.
        await resolveLocationBeforeConnect()
        await connectVoice()

        if voiceMode == .realtime {
            if !isReturning {
                // A greeting is coming: keep the mic MUTED until it finishes, so her
                // first words are not captured mid-greeting (which caused the launch
                // "first hello ignored, then two replies" bug). Unmuted on greeting end.
                awaitingGreeting = true
                voiceClient?.setMuted(true)
                // Safety: never leave the mic muted if the greeting never lands.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    guard let self, self.awaitingGreeting else { return }
                    self.awaitingGreeting = false
                    if !self.micPaused, !self.stateMachine.isSilent {
                        self.stateMachine.enterListening()
                        self.voiceClient?.setMuted(false)
                        self.voiceClient?.startListening()
                    }
                }
            } else {
                // Keep the mic open on launch when listening so the model hears her.
                voiceClient?.setMuted(!(stateMachine.state == .listening && !stateMachine.isSilent))
            }
        } else {
            // Offline or unreachable: Artemis needs a connection. No on-device
            // voiceover, no impersonation. Sit calm, the status says why, and the
            // connect notice appears only if she sends something.
            stateMachine.goIdle()
        }
    }

    private var didInjectLocation = false
    /// Fetch her location, then reapply the session ONCE so the model has her
    /// coordinates and place name (and stops asking for a city or postcode).
    /// Resolve her coarse location with a short cap, so the FIRST session includes
    /// it. No post-connect reconnect (that re-greeted on launch). A slow GPS never
    /// stalls the connection: we connect after at most ~1.5s regardless.
    private func resolveLocationBeforeConnect() async {
        guard ProcessInfo.processInfo.environment["ARTEMIS_DEMO"] == nil,
              LocationProvider.shared.isAuthorized,
              LocationProvider.shared.lastKnown == nil else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await LocationProvider.shared.currentCoarseLocation() }
            group.addTask { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            _ = await group.next()   // whichever wins: a fix, or the 1.5s cap
            group.cancelAll()
        }
        didInjectLocation = true
    }

    private func connectVoice() async {
        voiceMode = .connecting
        realtimeState = "connecting"
        didReceiveModelAudio = false

        guard Reachability.shared.isOnline else {
            ArtemisLog.warn("Voice: no network. Artemis needs a connection.")
            setNeedsConnection(.offline, state: "offline")
            return
        }

        #if canImport(RealtimeAPI)
        if RealtimeConfig.realtimeEnabled {
            let client = OpenAIRealtimeClient()
            client.delegate = self
            client.preferredLanguage = store.profile()?.language   // on-device live caption locale
            client.sessionContext = modelContext()
            // Greet ONLY when there is no conversation yet. Basing this on the live
            // message state (not a stale isReturning flag) means a reconnect or a
            // manual retry never re-greets mid-conversation ("Hi Sarah, I'm Artemis…").
            client.greetOnConnect = messages.isEmpty
            do {
                try await client.connect()
                voiceClient = client
                voiceMode = .realtime
                activeVoice = client.acceptedVoice
                let micOK = AVAudioApplication.shared.recordPermission == .granted
                voiceFailureReason = micOK ? .none : .micDenied
                ArtemisLog.info("Voice: connected and responding. mic=\(micOK ? "on" : "off")")
                return
            } catch {
                let ns = error as NSError
                let reason: VoiceFailureReason
                switch (ns.domain, ns.code) {
                case ("Artemis.Token", _): reason = .tokenFailed
                case ("Artemis.Voice", 10): reason = .audioUnavailable
                default: reason = .connectionFailed
                }
                ArtemisLog.warn("Voice: realtime unreachable (\(reason.rawValue)). Artemis needs a connection.")
                setNeedsConnection(reason, state: reason.rawValue)
                return
            }
        }
        #endif
        setNeedsConnection(.offline, state: "offline")
    }

    /// No model reachable. We do not impersonate Artemis on device, online she is
    /// the only voice. The UI shows a clear "needs a connection" state.
    private func setNeedsConnection(_ reason: VoiceFailureReason, state: String) {
        voiceClient = nil
        voiceMode = .offline
        voiceFailureReason = reason
        realtimeState = state
    }

    /// Context handed to the model each session: her name (used naturally) plus
    /// the long-term memory she has built.
    private func modelContext() -> String? {
        var parts: [String] = []
        if let name = store.profile()?.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("Her name is \(name). Address her by name naturally and warmly, not in every line.")
        }
        let lang = store.profile()?.language ?? "English"
        parts.append("Speak and write in \(lang). Do not switch to another language unless she clearly does. Never default to Portuguese or any language she did not choose.")
        if let eth = store.profile()?.ethnicity, !eth.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("She is \(eth). Some groups face higher risks in UK maternity care, so keep a slightly lower threshold to escalate and gently encourage her to be heard and push for checks. Never stereotype, use this only to raise vigilance.")
        }
        if let loc = LocationProvider.shared.sessionLocationLine { parts.append(loc) }
        if let mem = store.memoryContext() ?? historyContext() { parts.append(mem) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Recent structured check-ins passed to the model as context, so drift
    /// observations come from the model reasoning over real logged data.
    private func historyContext() -> String? {
        let recent = store.recentCheckins(limit: 7)
        guard !recent.isEmpty else { return nil }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        let lines = recent.map { e -> String in
            let themes = e.themes.isEmpty ? "" : " themes: \(e.themes.joined(separator: ", "))."
            return "\(f.string(from: e.date)): mood \(e.moodScore)/5. \(e.summaryLine)\(themes)"
        }
        return "Her recent check-ins (most recent first), for when she asks how she has been or you notice a pattern. Only mention a pattern if it is genuinely there.\n" + lines.joined(separator: "\n")
    }

    func retryConnection() {
        Task { await connectVoice() }
    }

    /// Re-apply a profile change (name, stage, weeks, language) to the LIVE
    /// realtime session by tearing it down and reopening with the new context.
    /// This is why a language switch now actually changes her replies.
    func reconnectVoice() {
        Task {
            voiceClient?.disconnect()
            voiceClient = nil
            isReturning = !messages.isEmpty   // don't re-greet mid-session
            await connectVoice()
            if voiceMode == .realtime {
                voiceClient?.setMuted(!(stateMachine.state == .listening && !stateMachine.isSilent))
            }
        }
    }

    func finishOnboarding(_ profile: UserProfile) {
        store.saveProfile(profile)
        store.seedDemoDataIfEmpty()   // gentle realistic week-1 data, idempotent
        profileRev += 1
        onboarded = true            // flips the root view into the home (fixes the stuck Start)
        Task { await startSession() }
    }

    /// Re-run onboarding from Settings ("Edit your details"). The flow pre-fills
    /// from the current profile, so she can change name, stage, weeks, language
    /// and ethnicity. finishOnboarding then re-saves and reconnects.
    func restartOnboarding() {
        sheet = nil
        onboarded = false
    }

    // MARK: text input

    func send(_ text: String, imageData: Data? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || imageData != nil else { return }
        Haptics.tap()
        engage()
        appendHer(trimmed.isEmpty ? "Here's a photo I wanted to show you." : trimmed, imageData: imageData)
        interim = ""
        voiceClient?.stopSpeaking()
        stateMachine.enterThinking()
        // A photo is clinically relevant context, shared non-diagnostically.
        let toModel: String = {
            guard imageData != nil else { return trimmed }
            return trimmed.isEmpty ? "I'm sharing a photo with you for context."
                                   : trimmed + " (I'm also sharing a photo for context.)"
        }()
        Task {
            // An attached image goes to the vision model, grounded in the image
            // itself, never the realtime model (which cannot see it and would
            // guess from memory). This is the fix for the invented-symptom bug.
            if let img = imageData {
                guard Reachability.shared.isOnline else {
                    stateMachine.settleAfterResponse()
                    appendNotice(L("needConnection", uiLanguage))
                    return
                }
                let dataURL = "data:image/jpeg;base64," + img.base64EncodedString()
                let reply = await VisionClient.assess(dataURL: dataURL, prompt: trimmed)
                stateMachine.settleAfterResponse()
                confirmAndSpeak(reply)   // photo replies are spoken too, unless on silent
                return
            }
            if usingRealtime, let vc = voiceClient {
                try? await vc.sendText(toModel, silent: stateMachine.isSilent)
            } else {
                // No model reachable. Artemis needs a connection, she does not
                // answer on device and there is no voiceover. Honest notice only.
                appendNotice(L("needConnection", uiLanguage))
            }
        }
    }

    // MARK: suggestion chips -> focused sheets -> result cards

    var activeChip: ChipKind?
    func openChip(_ k: ChipKind) { Haptics.tap(); engage(); activeChip = k }

    /// Symptoms aren't a form — she just talks. Tapping the chip opens the
    /// conversation with a warm prompt and starts listening, so she describes it
    /// naturally and Artemis triages what she says.
    func talkAboutSymptoms() {
        Haptics.tap()
        view = .home
        closeChip()
        engage()
        appendArtemis("Tell me what you're feeling, where it is, and when it started. I'll help you work out what to do.")
        beginListening()
    }

    // MARK: tracking entries (mood, symptoms, kicks) — log to the profile

    func submitMood(_ score: Int) {
        activeChip = nil; engage()
        let line = ["Very low", "Low", "Okay", "Good", "Great"][max(0, min(4, score - 1))]
        _ = store.addCheckin(CheckinLog(physicalSignals: [], emotionalSignals: [line], concerns: [],
            themes: ["mood"], moodScore: score, reflectionSummary: "", flagsForFollowup: [],
            summaryLine: "Mood logged, \(line.lowercased())."))
        confirmAndSpeak("Logged your mood as \(line.lowercased()). I'll keep an eye on how it changes.")
        Haptics.tap()
    }

    func submitSymptom(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeChip = nil; engage(); guard !s.isEmpty else { return }
        _ = store.addCheckin(CheckinLog(physicalSignals: [s], emotionalSignals: [], concerns: [],
            themes: [s.lowercased()], moodScore: 3, reflectionSummary: "", flagsForFollowup: [],
            summaryLine: "Symptom logged, \(s)."))
        confirmAndSpeak("Noted, \(s). If it gets worse or worries you, tell me and we can check it against NHS guidance.")
        Haptics.tap()
    }

    func submitKicks(_ count: Int) {
        activeChip = nil; engage()
        store.addKick(count: count)
        if count < 10 {
            // Reduced fetal movement always prompts immediate contact (NHS).
            deliverResultCard(TriageResult(
                tier: .urgent,
                spokenResponse: "You felt \(count) movements. Reduced movements should always be checked.",
                matchedCondition: "Fetal movements: \(count)",
                redFlagsDetected: ["Fewer than 10 movements"],
                nhsSourceTitle: "Your baby's movements", nhsSourceURL: "https://www.nhs.uk/pregnancy/keeping-well/your-babys-movements/",
                recommendedAction: "Please contact your maternity unit now, day or night. Do not wait.",
                routeTo: .maternityTriage), escalate: true)
        } else {
            confirmAndSpeak("Logged \(count) movements. That's reassuring, keep counting daily and tell me if they slow down.")
        }
        Haptics.tap()
    }
    func closeChip() { activeChip = nil }

    /// One daily check-in: mood, blood pressure and movements together. Logs each
    /// value she gave, then escalates on the most urgent finding (raised BP first,
    /// then reduced movements), otherwise a single warm confirmation.
    func submitDailyCheckin(mood: Int, systolic: Int?, diastolic: Int?, kicks: Int) {
        activeChip = nil; engage()
        var parts: [String] = []
        let moodScore = mood >= 1 ? mood : 3
        if mood >= 1 {
            let line = ["Very low", "Low", "Okay", "Good", "Great"][max(0, min(4, mood - 1))]
            parts.append("mood \(line.lowercased())")
        }
        if mood >= 1 || kicks > 0 {
            _ = store.addCheckin(CheckinLog(physicalSignals: kicks > 0 ? ["\(kicks) movements"] : [], emotionalSignals: [],
                concerns: [], themes: ["check-in"], moodScore: moodScore, reflectionSummary: "",
                flagsForFollowup: [], summaryLine: "Daily check-in."))
        }
        if kicks > 0 { store.addKick(count: kicks); parts.append("\(kicks) movements") }
        if let s = systolic, let d = diastolic, s > 0, d > 0 { store.addBP(systolic: s, diastolic: d); parts.append("BP \(s)/\(d)") }

        if let s = systolic, let d = diastolic, s > 0, d > 0, (s >= 140 || d >= 90) {
            let tier: TriageTier = (s >= 160 || d >= 110) ? .emergency : .urgent
            deliverResultCard(TriageResult(tier: tier,
                spokenResponse: "Your reading was \(s) over \(d). That is higher than the usual range and should be checked.",
                matchedCondition: "Blood pressure \(s)/\(d)", redFlagsDetected: ["Raised blood pressure"],
                nhsSourceTitle: "High blood pressure in pregnancy",
                nhsSourceURL: "https://www.nhs.uk/conditions/high-blood-pressure-hypertension/",
                recommendedAction: tier == .emergency ? "Call your maternity unit now, or 999 if you feel very unwell." : "Call your maternity unit today for a check.",
                routeTo: .maternityTriage), escalate: true)
            return
        }
        if kicks > 0, kicks < 10 {
            deliverResultCard(TriageResult(tier: .urgent,
                spokenResponse: "You felt \(kicks) movements. Reduced movements should always be checked.",
                matchedCondition: "Fetal movements: \(kicks)", redFlagsDetected: ["Fewer than 10 movements"],
                nhsSourceTitle: "Your baby's movements",
                nhsSourceURL: "https://www.nhs.uk/pregnancy/keeping-well/your-babys-movements/",
                recommendedAction: "Please contact your maternity unit now, day or night.",
                routeTo: .maternityTriage), escalate: true)
            return
        }
        confirmAndSpeak("Logged your check-in: \(parts.isEmpty ? "all done" : parts.joined(separator: ", ")). I'll keep an eye on how things change.")
        Haptics.tap()
    }

    /// A blood-pressure self-check, interpreted against NHS thresholds. Flags and
    /// escalates, never diagnoses. Saves the reading and returns a tiered card.
    func submitBPCheck(systolic: Int, diastolic: Int) {
        activeChip = nil
        verdictUncertain = false; verdictIsSafeCheck = false
        store.addBP(systolic: systolic, diastolic: diastolic)
        let tier: TriageTier = (systolic >= 160 || diastolic >= 110) ? .emergency
                              : (systolic >= 140 || diastolic >= 90) ? .urgent : .routine
        let action: String = {
            switch tier {
            case .emergency: return "This is very high. Call your maternity triage unit now, or 999 if you feel unwell."
            case .urgent: return "This is raised. Please contact your maternity unit today so they can check you and your baby."
            case .routine, .selfCare, .reassuring: return "This is in the usual range. Keep logging it, and tell your midwife if it climbs."
            }
        }()
        let result = TriageResult(
            tier: tier,
            spokenResponse: tier == .routine
                ? "Your reading of \(systolic) over \(diastolic) looks to be in the usual range."
                : "Your reading of \(systolic) over \(diastolic) is \(tier == .emergency ? "very high" : "raised"), and that is worth checking.",
            matchedCondition: "Blood pressure \(systolic)/\(diastolic)",
            redFlagsDetected: tier == .routine ? ["In the usual range"] : ["At or above 140/90"],
            nhsSourceTitle: "High blood pressure (hypertension)",
            nhsSourceURL: "https://www.nhs.uk/conditions/high-blood-pressure-hypertension/",
            recommendedAction: action,
            routeTo: tier == .routine ? .none : .maternityTriage)
        deliverResultCard(result, escalate: tier != .routine)
    }

    /// "Is this safe?" grounded in NHS guidance, cited, non-diagnostic.
    func submitSafeCheck(_ query: String) {
        activeChip = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        engage()
        // SAFETY NET (P0): ambiguous or self-harm input is never a casual safe-check
        // and never ROUTINE. Respond with care and route to support.
        if SafeChecker.isConcerning(q) {
            crisis = .default
            appendArtemis(crisis.spokenResponse)
            sheet = .crisis
            Haptics.tap()
            return
        }
        Task {
            let r = SafeChecker.check(q)
            // P5: fire the NHS content fetch (it logs the status), fall back to cached.
            let hit = await NHSContentClient.shared.retrieve(query: q)
            let live = (hit?.liveFetched == true)
            verdictUncertain = r.uncertain
            verdictIsSafeCheck = true   // food/medicine question → informational chips
            let result = TriageResult(
                tier: r.tier, spokenResponse: r.answer,
                matchedCondition: r.topic,                          // neutral topic, NEVER the raw phrase
                redFlagsDetected: r.notes,
                nhsSourceTitle: live ? (hit?.guidance.title ?? r.sourceTitle) : r.sourceTitle,
                nhsSourceURL: live ? (hit?.guidance.url ?? r.sourceURL) : r.sourceURL,
                recommendedAction: r.action,
                routeTo: (r.tier == .routine || r.tier == .selfCare) ? .none : .gp,
                sourceNote: live ? "NHS.uk, live" : "Cached NHS guidance")
            deliverResultCard(result, escalate: r.tier != .routine && r.tier != .selfCare)
        }
    }

    private func deliverResultCard(_ result: TriageResult, escalate: Bool) {
        store.addSymptom(result)
        verdict = result; verdictService = nil; verdictUnit = nil
        if escalate {
            let coord = LocationProvider.shared.lastKnown
            if let found = ServiceLocator.shared.nearest(lat: coord?.latitude, lng: coord?.longitude) {
                verdictService = found.service; verdictUnit = found.unit
            }
        }
        appendArtemis(result.spokenResponse)
        sheet = .verdict
        Haptics.verdict(result.tier)
    }

    /// Tapping a reply re-opens the verdict card, if there is one.
    func reopenVerdict() {
        guard verdict != nil else { return }
        Haptics.tap()
        sheet = .verdict
    }

    // MARK: orb / mic controls

    /// Tapping the orb STOPS recording (and stops her speaking). From rest it
    /// begins listening. Simple: mic icon toggles, tap the orb to stop.
    func orbTapped() {
        if voiceMode == .offline { retryConnection(); return }
        Haptics.tap()
        if stateMachine.state == .responding { stopSpeaking(); return }   // tap orb → stop Artemis
        if micHot { stopListening(); return }                             // tap orb → stop listening
        engage(); beginListening()                                        // from rest → begin listening
    }

    func toggleMute() {
        stateMachine.toggleMute()
        let muted = stateMachine.micMuted
        voiceClient?.setMuted(muted)
        if !muted, stateMachine.state == .listening, !usingRealtime {
            voiceClient?.startListening()
        }
    }

    /// Stop listening: mute the mic and return to rest. Distinct from stopSpeaking.
    func stopListening() {
        Haptics.tap()
        micPaused = true                 // sticks until she taps to start again
        voiceClient?.setMuted(true)
        voiceClient?.stopListening()
        stateMachine.goIdle()
    }

    /// Begin (or resume) listening: clears the pause and opens the mic.
    private func beginListening() {
        micPaused = false
        if stateMachine.isSilent { stateMachine.lockSilent(false) }
        stateMachine.enterListening()
        voiceClient?.setMuted(false)
        if !usingRealtime { voiceClient?.startListening() }
    }

    /// Stop Artemis speaking immediately (cancels the in-flight response + audio),
    /// then return to listening. Speaking over her also interrupts (didChangeUserSpeaking).
    func stopSpeaking() {
        Haptics.tap()
        voiceClient?.interrupt()
        stateMachine.settleAfterResponse()
        if usingRealtime, !stateMachine.isSilent { stateMachine.enterListening() }
    }

    /// The mic icon TOGGLES recording: on -> muted, muted/idle -> on.
    func micButtonTapped() {
        if voiceMode == .offline { retryConnection(); return }
        Haptics.tap()
        engage()
        if stateMachine.state == .responding { voiceClient?.interrupt() }
        if micHot { stopListening() }   // on → stop listening
        else { beginListening() }       // off/paused → start listening
    }

    func enterSilentTyping() {
        guard !stateMachine.isSilent else { return }
        stateMachine.enterSilentTyping()
        voiceClient?.setMuted(true)
        voiceClient?.stopSpeaking()
    }

    func setSilentLocked(_ on: Bool) {
        stateMachine.lockSilent(on)
        voiceClient?.setMuted(stateMachine.micMuted)
        if !on, !usingRealtime, stateMachine.state == .listening { voiceClient?.startListening() }
    }

    // MARK: advocacy / navigation

    func buildAdvocacy() {
        engage()
        // Templated script first, so the sheet opens instantly and works offline.
        let templated = AdvocacyBuilder.build(
            profile: store.profile(),
            checkins: store.recentCheckins(limit: 7),
            latestSymptom: store.recentSymptoms(limit: 1).first,
            bp: store.recentBP(limit: 3))
        advocacy = templated
        sheet = .advocacy
        // Then upgrade it LIVE with an AI summary of her recent days + conversation,
        // written in HER language, if the server is reachable.
        let context = advocacyContext()
        let lang = store.profile()?.language ?? "English"
        Task { @MainActor in
            if let lines = await AppointmentPrepClient.generate(context: context, language: lang) {
                ArtemisLog.info("Advocacy: AI script applied (\(lines.count) lines).")
                advocacy = AdvocacyScript(title: templated.title, generated: templated.generated, body: lines)
            } else {
                ArtemisLog.warn("Advocacy: AI summary returned nil, keeping templated script.")
            }
        }
    }

    /// Plain-text notes about her recent days, for the AI appointment-prep summary.
    private func advocacyContext() -> String {
        var parts: [String] = []
        if let p = store.profile() {
            if p.stageEnum == .pregnant {
                parts.append("She is \(p.weeks) weeks pregnant, \(p.firstPregnancy ? "first baby" : "not her first").")
            } else {
                parts.append("She gave birth \(p.birthTiming ?? "recently").")
            }
            var hist: [String] = []
            if p.hasBPHistory { hist.append("high blood pressure history") }
            if p.hasMentalHealthHistory { hist.append("mental health history") }
            if !hist.isEmpty { parts.append("History: \(hist.joined(separator: ", ")).") }
        }
        let f = DateFormatter(); f.dateFormat = "d MMM"
        for c in store.recentCheckins(limit: 7).prefix(7) {
            var bits: [String] = ["mood \(c.moodScore)/5"]
            if !c.physicalSignals.isEmpty { bits.append("signs: \(c.physicalSignals.joined(separator: ", "))") }
            if !c.concerns.isEmpty { bits.append("worries: \(c.concerns.joined(separator: ", "))") }
            parts.append("\(f.string(from: c.date)): \(bits.joined(separator: "; ")).")
        }
        let bp = store.recentBP(limit: 3).sorted { $0.date < $1.date }
        if !bp.isEmpty { parts.append("Recent home blood pressure: \(bp.map { $0.display }.joined(separator: ", ")).") }
        if let s = store.recentSymptoms(limit: 1).first { parts.append("Latest concern: \(s.matchedCondition).") }
        // Her actual words from the recent conversation, so the script reflects what
        // she just told Artemis, not only the logged numbers.
        let chat = messages.suffix(8).filter { !$0.text.isEmpty }
            .map { ($0.role == .her ? "She said: " : "Artemis replied: ") + $0.text }
        if !chat.isEmpty { parts.append("Recent conversation:\n" + chat.joined(separator: "\n")) }
        return parts.isEmpty
            ? "She has not logged much yet. Write a short, gentle script inviting her to share whatever is on her mind with her midwife."
            : parts.joined(separator: "\n")
    }

    func callUnit() {
        let phone = verdictUnit?.phone ?? verdictService?.phone
        guard let phone, let url = URL(string: "tel://" + phone.filter { $0.isNumber }) else { return }
        Haptics.action()
        UIApplication.shared.open(url)
    }

    /// Open the unit in Apple Maps, by address if we have it, otherwise by name +
    /// coordinates, so she can get directions straight there.
    func openInMaps() {
        let name = verdictUnit?.name ?? verdictService?.name ?? "Maternity unit"
        let address = verdictUnit?.address ?? verdictService?.address
        let query = [name, address].compactMap { $0 }.joined(separator: ", ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        guard let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else { return }
        Haptics.tap()
        UIApplication.shared.open(url)
    }

    func callCrisisLine() {
        guard let url = URL(string: "tel://" + crisis.linePhone.filter { $0.isNumber }) else { return }
        Haptics.action()
        UIApplication.shared.open(url)
    }

    /// Dial the nearest maternity unit (used from the Movements detail page).
    func callNearestMaternityUnit() {
        let coord = LocationProvider.shared.lastKnown
        guard let found = ServiceLocator.shared.nearest(lat: coord?.latitude, lng: coord?.longitude),
              let url = URL(string: "tel://" + found.service.phone.filter { $0.isNumber }) else { return }
        Haptics.action()
        UIApplication.shared.open(url)
    }

    func closeSheet() { sheet = nil }
    func showPaywall() { sheet = .paywall }

    // MARK: action chips (P2) — every assistant message ends in a tappable step

    /// The next-step chips come STRICTLY from the model's structured verdict, so
    /// the badge and chips always agree with the clinical reasoning. No text
    /// heuristics guess urgency. With no verdict it is not a triage: a greeting
    /// gets nothing, anything else a single gentle, non-clinical prompt.
    func actionsFor(text: String) -> [MessageAction] {
        // An "already logged" confirmation never carries action chips, even if a
        // verdict from a previous turn is still set (it must not inherit those chips).
        let low = text.lowercased()
        if ["logged", "noted,"].contains(where: { low.hasPrefix($0) }) { return [] }
        if let v = verdict {
            if verdictUncertain { return cap([.checkWithPro, .turnIntoScript]) }
            switch v.tier {
            case .emergency:  return cap([.call999, .findNearestUnit])
            case .urgent:     return cap([.call111, .findNearestUnit])
            case .routine:    return verdictIsSafeCheck ? cap([.seeGuidance, .logThis]) : cap([.callMidwife, .seeGuidance])
            case .selfCare:   return cap([.seeGuidance, .logThis])
            case .reassuring: return cap([.logThis, .imOkay])
            }
        }
        return conversationalActions(text.lowercased())
    }

    /// Context-aware follow-ups for non-triage replies, so it is NOT always
    /// "Log this". Most conversational turns get no chip at all (clean), and the
    /// chip that does appear actually fits what was said.
    private func conversationalActions(_ lower: String) -> [MessageAction] {
        if isChitChat(lower) { return [] }                       // greeting / small talk → nothing
        if lower.contains("?") { return [] }                     // Artemis asked her something → let her answer
        // Already-logged confirmations ("Logged your mood…", "Noted, fever…") must NOT
        // offer "Log this" again, even though they contain loggable words.
        if ["logged", "noted,"].contains(where: { lower.hasPrefix($0) }) { return [] }
        if lower.contains("midwife") || lower.contains("gp ") || lower.contains("doctor") || lower.contains("111") {
            return [.checkWithPro]                                // pointed her to a professional
        }
        let loggable = ["feeling", "mood", "tired", "anxious", "worried", "sleep", "nausea", "sick", "ache", "pain"]
        if loggable.contains(where: { lower.contains($0) }) { return [.logThis] }   // something worth tracking
        return []                                                 // default: no clutter
    }

    /// At most two action chips per message.
    private func cap(_ a: [MessageAction]) -> [MessageAction] { Array(a.prefix(2)) }

    /// A warm opener or small talk, nothing to triage.
    private func isChitChat(_ l: String) -> Bool {
        let s = l.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count < 90 else { return false }
        if ["hi", "hey", "hello", "hiya"].contains(where: { s == $0 || s.hasPrefix($0 + " ") || s.hasPrefix($0 + ",") }) { return true }
        let cues = ["how are you", "good morning", "good afternoon", "good evening", "nice to", "lovely to",
                    "you're welcome", "welcome back", "i'm here for you", "i am here for you", "what can i help",
                    "how can i help", "glad you", "thanks for", "happy to"]
        return cues.contains { s.contains($0) }
    }

    func performAction(_ action: MessageAction) {
        Haptics.tap()
        switch action {
        case .call999: dial("999")
        case .call111: dial("111")
        case .callMidwife:
            if let phone = verdictUnit?.phone ?? verdictService?.phone { dial(phone) } else { findNearestUnitNow() }
        case .findNearestUnit: findNearestUnitNow()
        case .seeGuidance:
            if let v = verdict, let url = URL(string: v.nhsSourceURL) { UIApplication.shared.open(url) }
            else if verdict != nil { reopenVerdict() }
            else if let url = URL(string: "https://www.nhs.uk/pregnancy/") { UIApplication.shared.open(url) }
        case .checkWithPro:
            if let phone = verdictUnit?.phone ?? verdictService?.phone { dial(phone) } else { findNearestUnitNow() }
        case .turnIntoScript: buildAdvocacy()
        case .logThis: openChip(.symptoms)
        case .imOkay: break   // acknowledged, nothing to escalate
        }
    }

    private func dial(_ number: String) {
        guard let url = URL(string: "tel://" + number.filter { $0.isNumber }) else { return }
        Haptics.action(); UIApplication.shared.open(url)
    }

    /// Find the nearest unit from real location and render its card with one-tap call.
    func findNearestUnitNow() {
        // Resolve her REAL location first (London on the simulator), then compute,
        // so the distance is believable and never a default-coordinate 5704 km.
        Task {
            let coord = await LocationProvider.shared.currentCoarseLocation() ?? LocationProvider.shared.lastKnown
            // Live NHS Directory of Services when available, cached units otherwise.
            if let found = await DoSClient.nearest(lat: coord?.latitude, lng: coord?.longitude) {
                toolsDidLocateUnit(found.service, found.unit, live: found.live)
            }
        }
    }

    /// A follow-up tapped from a message's menu, sent as the next turn. The model
    /// already has the thread, so "that" refers to the message in context.
    enum FollowUp { case explain, whatToDo, simpler }
    func followUp(_ action: FollowUp, on message: ChatMessage) {
        switch action {
        case .explain:  send("Can you explain that a little more?")
        case .whatToDo: send("What should I do about that?")
        case .simpler:  send("Can you say that more simply?")
        }
    }

    /// Clearing what Artemis remembers clears the whole history: memory AND the
    /// chat thread are one history. Wipes the store and the on-screen messages.
    func eraseEverything() {
        store.deleteEverything()   // check-ins, symptoms, BP, kicks, and the chat thread
        messages.removeAll()
        turnBubbleID = nil
        persistedBubbleIDs.removeAll()
        userBubbleMap.removeAll()
        persistedUserItems.removeAll()
        sessionEngaged = false
        verdict = nil
        verdictService = nil
        verdictUnit = nil
    }

    // MARK: speaking a finished reply (on-device path only)

    private func handleLocalOutcome(_ outcome: LocalOutcome, spokenAllowed: Bool) {
        lastReplySource = "local-fallback"
        switch outcome {
        case .triage:
            break
        case .checkin(let spoken):
            appendArtemis(spoken)
            settleSpeaking(spoken, allowed: spokenAllowed)
        case .crisis(let support):
            crisis = support
            appendArtemis(support.spokenResponse)
            sheet = .crisis
            settleSpeaking(support.spokenResponse, allowed: spokenAllowed)
        case .chat(let spoken):
            appendArtemis(spoken)
            settleSpeaking(spoken, allowed: spokenAllowed)
        }
    }

    private func settleSpeaking(_ text: String, allowed: Bool) {
        if allowed && stateMachine.audioOn && !usingRealtime {
            stateMachine.enterResponding()
            voiceClient?.speak(text)
        } else {
            stateMachine.settleAfterResponse()
            if stateMachine.state == .listening, !usingRealtime { voiceClient?.startListening() }
        }
    }

    private func appendHer(_ text: String, imageData: Data? = nil) {
        beginAssistantTurn()   // her message → the reply starts a fresh single bubble
        messages.append(ChatMessage(role: .her, text: text, imageData: imageData))
        store.addChatTurn(role: "her", text: text, imageData: imageData)
    }
    /// Append a confirmation AND, unless she is on silent, say it aloud in Artemis's
    /// voice, so logging her mood / BP / kicks / check-in gives warm spoken feedback.
    private func confirmAndSpeak(_ text: String) {
        appendArtemis(text)
        if !stateMachine.isSilent { voiceClient?.speak(text) }
    }
    private func appendArtemis(_ text: String) {
        let clean = text.dashStripped
        if messages.last?.role == .artemis, messages.last?.text == clean { return }   // dedupe
        var msg = ChatMessage(role: .artemis, text: clean)
        msg.actions = actionsFor(text: clean)
        turnBubbleID = msg.id
        messages.append(msg)
        attachNHSSource()
        persistedBubbleIDs.insert(msg.id)   // so a realtime upsert never re-persists this bubble
        store.addChatTurn(role: "artemis", text: clean)
    }

    /// An ephemeral assistant notice (e.g. "needs a connection"), not persisted.
    /// Owns the turn bubble so a later realtime reply replaces it, never doubles it.
    func appendNotice(_ text: String) {
        if messages.last?.role == .artemis, messages.last?.text == text { return }
        var msg = ChatMessage(role: .artemis, text: text)
        msg.actions = [.imOkay]
        turnBubbleID = msg.id
        messages.append(msg)
    }
}

/// Sends an attached image to the server-side vision model and returns Artemis's
/// answer grounded in the actual image. Never invents a symptom.
enum VisionClient {
    static func assess(dataURL: String, prompt: String) async -> String {
        let url = RealtimeConfig.serverBaseURL.appendingPathComponent("vision")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["image": dataURL, "prompt": prompt])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
        } catch {}
        return "I cannot assess that photo here. If it is a food or medicine, tell me which and I will check NHS guidance, or show it to your midwife or pharmacist."
    }
}

/// Lightweight UI localisation for the core, always-visible strings. The
/// conversation itself is localised by the model (it replies in her language).
/// NOTE: the non-Latin translations are a first pass and should be reviewed by
/// native speakers before release.
func L(_ key: String, _ lang: String) -> String {
    LocalizedStrings.table[key]?[lang] ?? LocalizedStrings.table[key]?["English"] ?? key
}

enum LocalizedStrings {
    static let table: [String: [String: String]] = [
        "feeling": [
            "English": "How are you feeling today?", "Spanish": "¿Cómo te sientes hoy?",
            "French": "Comment te sens-tu aujourd'hui ?", "Romanian": "Cum te simți azi?",
            "Polish": "Jak się dziś czujesz?", "Turkish": "Bugün nasıl hissediyorsun?",
            "Arabic": "كيف تشعرين اليوم؟", "Urdu": "آج آپ کیسا محسوس کر رہی ہیں؟",
            "Bengali": "আজ আপনি কেমন অনুভব করছেন?", "Gujarati": "આજે તમે કેવું અનુભવો છો?",
            "Punjabi": "ਅੱਜ ਤੁਸੀਂ ਕਿਵੇਂ ਮਹਿਸੂਸ ਕਰ ਰਹੇ ਹੋ?"],
        "checkin": [
            "English": "Daily check-in", "Spanish": "Control diario", "French": "Point quotidien",
            "Romanian": "Verificare zilnică", "Polish": "Codzienne sprawdzenie", "Turkish": "Günlük kontrol",
            "Arabic": "تسجيل يومي", "Urdu": "روزانہ جائزہ", "Bengali": "দৈনিক চেক-ইন",
            "Gujarati": "દૈનિક ચેક-ઇન", "Punjabi": "ਰੋਜ਼ਾਨਾ ਚੈੱਕ-ਇਨ"],
        "safe": [
            "English": "Is this safe?", "Spanish": "¿Es seguro esto?", "French": "Est-ce sans danger ?",
            "Romanian": "Este sigur?", "Polish": "Czy to bezpieczne?", "Turkish": "Bu güvenli mi?",
            "Arabic": "هل هذا آمن؟", "Urdu": "کیا یہ محفوظ ہے؟", "Bengali": "এটা কি নিরাপদ?",
            "Gujarati": "શું આ સલામત છે?", "Punjabi": "ਕੀ ਇਹ ਸੁਰੱਖਿਅਤ ਹੈ?"],
        "bp": [
            "English": "Blood pressure", "Spanish": "Presión arterial", "French": "Tension artérielle",
            "Romanian": "Tensiune arterială", "Polish": "Ciśnienie krwi", "Turkish": "Tansiyon",
            "Arabic": "ضغط الدم", "Urdu": "بلڈ پریشر", "Bengali": "রক্তচাপ",
            "Gujarati": "બ્લડ પ્રેશર", "Punjabi": "ਬਲੱਡ ਪ੍ਰੈਸ਼ਰ"],
        "appointment": [
            "English": "Appointment prep", "Spanish": "Preparar tu cita", "French": "Préparer ton rendez-vous",
            "Romanian": "Pregătește programarea", "Polish": "Przygotuj się na wizytę", "Turkish": "Randevuna hazırlan",
            "Arabic": "التحضير لموعدك", "Urdu": "ملاقات کی تیاری", "Bengali": "অ্যাপয়েন্টমেন্টের প্রস্তুতি",
            "Gujarati": "મુલાકાતની તૈયારી", "Punjabi": "ਮੁਲਾਕਾਤ ਦੀ ਤਿਆਰੀ"],
        "mood": [
            "English": "Mood", "Spanish": "Ánimo", "French": "Humeur", "Romanian": "Dispoziție",
            "Polish": "Nastrój", "Turkish": "Ruh hâli", "Arabic": "المزاج", "Urdu": "موڈ",
            "Bengali": "মেজাজ", "Gujarati": "મિજાજ", "Punjabi": "ਮੂਡ"],
        "symptoms": [
            "English": "Symptoms", "Spanish": "Síntomas", "French": "Symptômes", "Romanian": "Simptome",
            "Polish": "Objawy", "Turkish": "Belirtiler", "Arabic": "الأعراض", "Urdu": "علامات",
            "Bengali": "উপসর্গ", "Gujarati": "લક્ષણો", "Punjabi": "ਲੱਛਣ"],
        "kicks": [
            "English": "Kicks", "Spanish": "Movimientos", "French": "Mouvements", "Romanian": "Mișcări",
            "Polish": "Ruchy", "Turkish": "Hareketler", "Arabic": "حركات", "Urdu": "حرکات",
            "Bengali": "নড়াচড়া", "Gujarati": "હલનચલન", "Punjabi": "ਹਰਕਤਾਂ"],
        "placeholder": [
            "English": "Message, or tap to speak", "Spanish": "Escribe, o toca para hablar",
            "French": "Écris, ou touche pour parler", "Romanian": "Scrie, sau atinge pentru a vorbi",
            "Polish": "Napisz lub dotknij, by mówić", "Turkish": "Yaz ya da konuşmak için dokun",
            "Arabic": "اكتبي، أو المسي للتحدث", "Urdu": "لکھیں، یا بولنے کے لیے چھوئیں",
            "Bengali": "লিখুন, বা কথা বলতে স্পর্শ করুন", "Gujarati": "લખો, અથવા બોલવા માટે સ્પર્શ કરો",
            "Punjabi": "ਲਿਖੋ, ਜਾਂ ਬੋਲਣ ਲਈ ਛੋਹੋ"],
        "listening": [
            "English": "LISTENING", "Spanish": "ESCUCHANDO", "French": "À L'ÉCOUTE", "Romanian": "ASCULT",
            "Polish": "SŁUCHAM", "Turkish": "DİNLİYORUM", "Arabic": "أستمع", "Urdu": "سن رہی ہوں",
            "Bengali": "শুনছি", "Gujarati": "સાંભળું છું", "Punjabi": "ਸੁਣ ਰਹੀ ਹਾਂ"],
        "speaking": [
            "English": "SPEAKING", "Spanish": "HABLANDO", "French": "JE PARLE", "Romanian": "VORBESC",
            "Polish": "MÓWIĘ", "Turkish": "KONUŞUYORUM", "Arabic": "أتحدث", "Urdu": "بول رہی ہوں",
            "Bengali": "বলছি", "Gujarati": "બોલું છું", "Punjabi": "ਬੋਲ ਰਹੀ ਹਾਂ"],
        "connecting": [
            "English": "Connecting to Artemis…", "Spanish": "Conectando con Artemis…", "French": "Connexion à Artemis…",
            "Romanian": "Mă conectez la Artemis…", "Polish": "Łączenie z Artemis…", "Turkish": "Artemis'e bağlanılıyor…",
            "Arabic": "جارٍ الاتصال بـ Artemis…", "Urdu": "آرٹیمس سے رابطہ ہو رہا ہے…", "Bengali": "Artemis-এর সাথে সংযোগ হচ্ছে…",
            "Gujarati": "Artemis સાથે જોડાઈ રહ્યું છે…", "Punjabi": "Artemis ਨਾਲ ਜੁੜ ਰਿਹਾ ਹੈ…"],
        "checking": [
            "English": "Checking NHS guidance…", "Spanish": "Consultando la guía del NHS…", "French": "Consultation des conseils du NHS…",
            "Romanian": "Verific ghidul NHS…", "Polish": "Sprawdzam wytyczne NHS…", "Turkish": "NHS rehberi kontrol ediliyor…",
            "Arabic": "جارٍ مراجعة إرشادات NHS…", "Urdu": "NHS رہنمائی دیکھی جا رہی ہے…", "Bengali": "NHS নির্দেশিকা দেখা হচ্ছে…",
            "Gujarati": "NHS માર્ગદર્શિકા તપાસાઈ રહી છે…", "Punjabi": "NHS ਮਾਰਗਦਰਸ਼ਨ ਚੈੱਕ ਕੀਤਾ ਜਾ ਰਿਹਾ ਹੈ…"],
        "silent": [
            "English": "Silent mode. Tap the mic to talk.", "Spanish": "Modo silencio. Toca el micrófono para hablar.",
            "French": "Mode silencieux. Touche le micro pour parler.", "Romanian": "Mod silențios. Atinge microfonul ca să vorbești.",
            "Polish": "Tryb cichy. Dotknij mikrofonu, by mówić.", "Turkish": "Sessiz mod. Konuşmak için mikrofona dokun.",
            "Arabic": "الوضع الصامت. المسي الميكروفون للتحدث.", "Urdu": "خاموش موڈ۔ بولنے کے لیے مائیک چھوئیں۔",
            "Bengali": "নীরব মোড। কথা বলতে মাইকে স্পর্শ করুন।", "Gujarati": "સાયલન્ટ મોડ. બોલવા માટે માઇક સ્પર્શ કરો.",
            "Punjabi": "ਚੁੱਪ ਮੋਡ। ਬੋਲਣ ਲਈ ਮਾਈਕ ਛੋਹੋ।"],
        "needConnStatus": [
            "English": "You need to be connected to talk with Artemis.", "Spanish": "Necesitas conexión para hablar con Artemis.",
            "French": "Tu dois être connectée pour parler à Artemis.", "Romanian": "Trebuie să fii conectată ca să vorbești cu Artemis.",
            "Polish": "Musisz mieć połączenie, aby rozmawiać z Artemis.", "Turkish": "Artemis ile konuşmak için bağlı olmalısın.",
            "Arabic": "تحتاجين إلى اتصال للتحدث مع Artemis.", "Urdu": "آرٹیمس سے بات کرنے کے لیے آپ کو کنکشن درکار ہے۔",
            "Bengali": "Artemis-এর সাথে কথা বলতে আপনার সংযোগ দরকার।", "Gujarati": "Artemis સાથે વાત કરવા તમારે કનેક્શન જોઈએ.",
            "Punjabi": "Artemis ਨਾਲ ਗੱਲ ਕਰਨ ਲਈ ਤੁਹਾਨੂੰ ਕਨੈਕਸ਼ਨ ਚਾਹੀਦਾ ਹੈ।"],
        "reconnect": [
            "English": "Artemis needs a connection. Tap to retry.", "Spanish": "Artemis necesita conexión. Toca para reintentar.",
            "French": "Artemis a besoin d'une connexion. Touche pour réessayer.", "Romanian": "Artemis are nevoie de conexiune. Atinge pentru a reîncerca.",
            "Polish": "Artemis potrzebuje połączenia. Dotknij, by spróbować ponownie.", "Turkish": "Artemis bağlantı gerektiriyor. Tekrar denemek için dokun.",
            "Arabic": "تحتاج Artemis إلى اتصال. المسي لإعادة المحاولة.", "Urdu": "آرٹیمس کو کنکشن چاہیے۔ دوبارہ کوشش کے لیے چھوئیں۔",
            "Bengali": "Artemis-এর সংযোগ দরকার। আবার চেষ্টা করতে স্পর্শ করুন।", "Gujarati": "Artemis ને કનેક્શન જોઈએ. ફરી પ્રયાસ કરવા સ્પર્શ કરો.",
            "Punjabi": "Artemis ਨੂੰ ਕਨੈਕਸ਼ਨ ਚਾਹੀਦਾ ਹੈ। ਮੁੜ ਕੋਸ਼ਿਸ਼ ਲਈ ਛੋਹੋ।"],
        "needConnection": [
            "English": "I need to be connected to talk with you. Please check your internet, and I will be right here.",
            "Spanish": "Necesito conexión para hablar contigo. Revisa tu internet y estaré aquí.",
            "French": "J'ai besoin d'une connexion pour te parler. Vérifie ton internet, je serai là.",
            "Romanian": "Am nevoie de conexiune ca să vorbesc cu tine. Verifică internetul, sunt aici.",
            "Polish": "Potrzebuję połączenia, aby z tobą rozmawiać. Sprawdź internet, będę tutaj.",
            "Turkish": "Seninle konuşmak için bağlantı gerekiyor. İnternetini kontrol et, buradayım.",
            "Arabic": "أحتاج إلى اتصال لأتحدث معك. تحققي من الإنترنت وسأكون هنا.",
            "Urdu": "آپ سے بات کرنے کے لیے مجھے کنکشن چاہیے۔ اپنا انٹرنیٹ چیک کریں، میں یہیں ہوں۔",
            "Bengali": "আপনার সাথে কথা বলতে আমার সংযোগ দরকার। ইন্টারনেট দেখুন, আমি এখানেই আছি।",
            "Gujarati": "તમારી સાથે વાત કરવા મને કનેક્શન જોઈએ. તમારું ઇન્ટરનેટ તપાસો, હું અહીં છું.",
            "Punjabi": "ਤੁਹਾਡੇ ਨਾਲ ਗੱਲ ਕਰਨ ਲਈ ਮੈਨੂੰ ਕਨੈਕਸ਼ਨ ਚਾਹੀਦਾ ਹੈ। ਆਪਣਾ ਇੰਟਰਨੈੱਟ ਚੈੱਕ ਕਰੋ, ਮੈਂ ਇੱਥੇ ਹਾਂ।"],
    ]
}

extension String {
    /// Defensive no-dash rule: replace em/en/figure dashes with plain punctuation
    /// so a model slip never reaches her eyes or ears. Standard hyphens (as in
    /// pre-eclampsia) are left untouched.
    var dashStripped: String {
        var s = self
        for d in ["—", "–", "―", "‒", "‐"] {
            s = s.replacingOccurrences(of: " \(d) ", with: ", ")
            s = s.replacingOccurrences(of: "\(d) ", with: ", ")
            s = s.replacingOccurrences(of: " \(d)", with: ", ")
            s = s.replacingOccurrences(of: d, with: ", ")
        }
        return s.replacingOccurrences(of: ", ,", with: ",")
                .replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: "  ", with: " ")
    }
}

// MARK: - ToolDispatcherDelegate (cards drawn from tool calls)

extension ConversationEngine: ToolDispatcherDelegate {
    func toolsDidRequestCrisis() {
        // Self-harm surfaced in a model tool call: replace any card with care.
        crisis = .default
        verdict = nil
        appendArtemis(crisis.spokenResponse)
        sheet = .crisis
        Haptics.tap()
    }

    func toolsDidProduceTriage(_ result: TriageResult, nearest: NearestService?, unit: MaternityUnit?) {
        // NO DOWNGRADE within a turn: a later routine/reassuring verdict must never
        // replace an urgent or emergency one already shown this turn (the "two
        // triages, first urgent then routine" bug). Keep the higher, attach the unit.
        if let existing = verdict, (existing.tier == .emergency || existing.tier == .urgent),
           result.tier != .emergency, result.tier != .urgent {
            if let nearest { verdictService = nearest }
            if let unit { verdictUnit = unit }
            sheet = .verdict
            return
        }
        verdict = result
        verdictUncertain = false; verdictIsSafeCheck = false
        verdictService = nearest
        verdictUnit = unit
        if !usingRealtime {
            // on-device path: Artemis voices the spoken_response herself
            appendArtemis(result.spokenResponse)
            if stateMachine.audioOn {
                stateMachine.enterResponding()
                voiceClient?.speak(result.spokenResponse)
            }
        } else {
            lastReplySource = "realtime"
        }
        sheet = .verdict
        Haptics.verdict(result.tier)
    }

    func toolsDidUpdateNearest(_ nearest: NearestService?, unit: MaternityUnit?) {
        if let nearest { verdictService = nearest }
        if let unit { verdictUnit = unit }
    }

    /// She asked to find a clinic: show the nearest unit with a one-tap call.
    func toolsDidLocateUnit(_ service: NearestService, _ unit: MaternityUnit, live: Bool = false) {
        verdictService = service
        verdictUnit = unit
        // If there is already an urgent or emergency verdict, ATTACH this unit as the
        // call target and KEEP that verdict, so the nearest-unit lookup never downgrades
        // a red-flag to a routine "nearest unit" card (the triage inconsistency).
        if let v = verdict, v.tier == .urgent || v.tier == .emergency {
            sheet = .verdict
            Haptics.tap()
            return
        }
        // No verdict yet. A symptom turn usually fires assess_symptoms a moment after
        // find_nearest, so wait briefly: if a triage verdict (urgent/emergency) lands,
        // the unit just attaches to it. Only if NOTHING arrives do we show a standalone
        // routine nearest-unit card. This stops the routine card flashing before the
        // real verdict (the "starts routine then goes to emergency" bug).
        let token = UUID()
        pendingNearestToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self.pendingNearestToken == token else { return }   // superseded by a newer call
            if let v = self.verdict, v.tier == .urgent || v.tier == .emergency { self.sheet = .verdict; return }
            self.verdict = TriageResult(
                tier: .routine,
                spokenResponse: "Your nearest NHS maternity unit is \(unit.name).",
                matchedCondition: "Nearest maternity unit",
                redFlagsDetected: [],
                nhsSourceTitle: "Find maternity services, NHS",
                nhsSourceURL: "https://www.nhs.uk/service-search/maternity-services/",
                recommendedAction: "Tap below to call \(unit.name).",
                routeTo: .maternityTriage,
                sourceNote: live ? "NHS Directory of Services, live" : "Cached NHS list")
            self.sheet = .verdict
            Haptics.tap()
        }
    }

    func toolsDidLogCheckin(_ log: CheckinLog) {}
}

// MARK: - RealtimeVoiceClientDelegate (voice transport events)

extension ConversationEngine: RealtimeVoiceClientDelegate {
    func voiceClientDidConnect(_ client: RealtimeVoiceClient) {}

    /// A bare filler/backchannel with no content ("hm", "uh", "um", "mm", "er").
    private func isBackchannel(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?…"))
        let fillers: Set<String> = ["hm", "hmm", "hmmm", "uh", "um", "umm", "mm", "mmm", "mhm", "uh huh", "er", "erm", "ahem"]
        return fillers.contains(t)
    }

    func voiceClient(_ client: RealtimeVoiceClient, didUpdateUserTranscript itemId: String, text: String, isFinal: Bool) {
        engage()   // she is speaking
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isFinal {
            // LIVE caption: her words build, word by word, in the interim bubble (a
            // right-aligned bubble with a typing cursor) AS she speaks. This is the
            // visible "live transcription". It commits to a real bubble on the final.
            interim = clean
            if stateMachine.state != .silentTyping { stateMachine.enterListening() }
            return
        }
        // FINAL: clear the live caption and commit her words to a real bubble.
        interim = ""
        guard !clean.isEmpty else { return }
        // A bare filler ("hm", "uh", "um") is not a message: don't persist a bubble or
        // start a thinking turn for it, so the thread stays clean.
        if isBackchannel(clean) { return }
        if let uuid = userBubbleMap[itemId], let idx = messages.firstIndex(where: { $0.id == uuid }) {
            messages[idx].text = clean
        } else if let last = messages.last, last.role == .her,
                  isContinuation(prev: last.text, next: clean),
                  let li = messages.firstIndex(where: { $0.id == last.id }) {
            // A pause split her sentence into a new item: merge rather than duplicate.
            messages[li].text = clean
            userBubbleMap[itemId] = messages[li].id
        } else {
            let msg = ChatMessage(role: .her, text: clean)
            userBubbleMap[itemId] = msg.id
            messages.append(msg)
        }
        // Persist once, then move to thinking.
        if !persistedUserItems.contains(itemId) {
            persistedUserItems.insert(itemId)
            store.addChatTurn(role: "her", text: clean)
        }
        stateMachine.enterThinking()
        if !client.handlesReasoning {
            Task {
                let outcome = await reasoner.handle(clean)
                handleLocalOutcome(outcome, spokenAllowed: true)
            }
        }
    }

    /// True when `next` extends or restates `prev` (a pause split one utterance),
    /// so the two transcription items render as a single bubble, never duplicated.
    private func isContinuation(prev: String, next: String) -> Bool {
        let p = prev.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !n.isEmpty else { return false }
        if p == n { return true }
        // Prefix-only: a true continuation extends the start ("I have a little bit"
        // -> "I have a little bit of fever"). NOT arbitrary containment, so two
        // different short utterances ("fever" vs "...of fever") stay separate.
        return n.hasPrefix(p) || p.hasPrefix(n)
    }

    func voiceClient(_ client: RealtimeVoiceClient, didUpsertAssistantMessage id: String, text: String, isFinal: Bool) {
        guard client.handlesReasoning else { return }
        // Drop pure process narration ("I am going to lean on NHS guidance…").
        if isNarration(text) { return }
        let clean = text.dashStripped
        guard !clean.isEmpty else { return }
        lastReplySource = "realtime"
        // EXACTLY ONE assistant bubble per user turn. Whatever item or response
        // this text comes from, it updates the single turn bubble in place, so a
        // preamble item is simply replaced by the final answer. Never a second bubble.
        if let uuid = turnBubbleID, let idx = messages.firstIndex(where: { $0.id == uuid }) {
            messages[idx].text = clean
            messages[idx].actions = actionsFor(text: clean)
        } else if let last = messages.last, last.role == .artemis,
                  (clean.hasPrefix(last.text) || last.text.hasPrefix(clean) || isContinuation(prev: last.text, next: clean)),
                  let li = messages.firstIndex(where: { $0.id == last.id }) {
            // A continuation/restatement of the previous reply (a partial then its
            // completion): same bubble, never a second one. Even if turnBubbleID was
            // lost, prefix-overlap re-merges into the existing bubble.
            messages[li].text = clean
            messages[li].actions = actionsFor(text: clean)
            turnBubbleID = last.id
        } else {
            var msg = ChatMessage(role: .artemis, text: clean)
            msg.actions = actionsFor(text: clean)
            turnBubbleID = msg.id
            messages.append(msg)
        }
        attachNHSSource()
        if isFinal, let bid = turnBubbleID, !persistedBubbleIDs.contains(bid), looksComplete(clean) {
            persistedBubbleIDs.insert(bid)
            store.addChatTurn(role: "artemis", text: clean)
        }
    }

    /// Surface the current verdict's NHS source under the turn's assistant bubble, so
    /// the grounding is visible in the chat itself, not only on the verdict card.
    private func attachNHSSource() {
        guard let v = verdict, NHSSourceGuard.isValid(title: v.nhsSourceTitle, url: v.nhsSourceURL),
              let bid = turnBubbleID, let i = messages.firstIndex(where: { $0.id == bid }) else { return }
        // A logging confirmation ("Logged your mood…") is not a clinical reply, so it
        // must never inherit a stale verdict's NHS pill from a previous turn.
        let low = messages[i].text.lowercased()
        if ["logged", "noted,"].contains(where: { low.hasPrefix($0) }) { return }
        messages[i].nhsTitle = v.nhsSourceTitle
        messages[i].nhsURL = v.nhsSourceURL
    }

    /// New user turn: the next assistant text starts a fresh single bubble.
    private func beginAssistantTurn() {
        turnBubbleID = nil
        pendingNearestToken = nil   // cancel any pending standalone nearest-unit card
        // Clear the verdict at the turn boundary so a fresh reply (e.g. a greeting
        // after an urgent card) never inherits the previous turn's urgency/chips.
        verdict = nil; verdictService = nil; verdictUnit = nil
        verdictUncertain = false; verdictIsSafeCheck = false
    }

    private func looksComplete(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count >= 20 || s.hasSuffix(".") || s.hasSuffix("?") || s.hasSuffix("!")
    }

    /// A short process-narration fragment ("I'm checking NHS guidance…") that
    /// should never be shown or spoken. Belt to the system-prompt rule.
    private func isNarration(_ text: String) -> Bool {
        // Normalise curly apostrophes so "I’m checking" matches "i'm checking".
        let s = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strong preamble phrases are narration at ANY length (they padded a long
        // sentence like "I'm just going to think this through so we can keep you safe").
        let strong = ["going to think this through", "think this through so", "just going to think",
                      "going to work through this", "keep you safe and clear on what to do",
                      "let me think this through", "going to figure out the safest"]
        if strong.contains(where: { s.contains($0) }) { return true }
        guard s.count < 90 else { return false }   // real answers are longer
        let cues = ["i'm checking", "i am checking", "let me check", "let me look",
                    "i'm looking", "i am looking", "checking the", "checking nhs",
                    "one moment", "pulling up", "let me see", "i'll check", "i will check",
                    "give me a moment", "hold on", "looking that up", "let me find",
                    "let me think", "let me support", "let me figure", "let me work out",
                    "i'll figure", "i'll think", "i will think",
                    // the exact preamble variants seen in the wild:
                    "i am going to", "i'm going to", "i am using nhs", "i'm using nhs",
                    "i am going to lean", "i'm going to lean", "i am going to base", "i'm going to base",
                    "i am using nhs guidance", "i'm using nhs guidance", "let me think this through",
                    "i am finding", "i'm finding", "i am consulting", "i'm consulting",
                    "based on nhs guidance, let me", "using nhs guidance"]
        // Catch the preamble at the start and after a short empathy opener.
        return cues.contains { s.hasPrefix($0) || s == $0 || s.contains(". \($0)") }
    }

    func voiceClient(_ client: RealtimeVoiceClient, didChangeUserSpeaking speaking: Bool) {
        // She tapped to stop: ignore the VAD until she starts again, otherwise the
        // 200ms poll re-arms listening and the tap appears to do nothing.
        guard !micPaused else { return }
        if speaking {
            engage()
            beginAssistantTurn()   // her new turn → the next reply starts a fresh single bubble
            // Barge-in: if she speaks while Artemis is talking, stop Artemis and listen.
            if stateMachine.state == .responding { client.interrupt() }
            if stateMachine.state != .silentTyping { stateMachine.enterListening() }
        }
    }

    func voiceClient(_ client: RealtimeVoiceClient, didChangeModelSpeaking speaking: Bool) {
        if speaking {
            interim = ""   // her turn is over; clear the live caption as Artemis takes over
            if stateMachine.state != .silentTyping { stateMachine.enterResponding() }
        } else {
            stateMachine.settleAfterResponse()
            // The opening greeting just finished: now open the mic for her first turn.
            if awaitingGreeting {
                awaitingGreeting = false
                if !micPaused, !stateMachine.isSilent {
                    stateMachine.enterListening()
                    voiceClient?.setMuted(false)
                    if !client.handlesReasoning { voiceClient?.startListening() }
                }
                return
            }
            // She tapped the wave to stop: stay stopped after the reply.
            if micPaused {
                stateMachine.goIdle()
                voiceClient?.setMuted(true)
                return
            }
            if stateMachine.state == .listening, !client.handlesReasoning {
                voiceClient?.startListening()
            }
        }
    }

    func voiceClient(_ client: RealtimeVoiceClient, requestsTool name: String, callId: String, argumentsJSON: String) async -> String {
        await dispatcher.dispatch(name: name, argumentsJSON: argumentsJSON)
    }

    func voiceClient(_ client: RealtimeVoiceClient, didError error: Error) {}

    // Diagnostics for the overlay
    func voiceClient(_ client: RealtimeVoiceClient, didChangeConnectionState state: String) {
        realtimeState = state
        // Auto-recover from a mid-session drop instead of silently sticking.
        let dropped = (state == "disconnected" || state == "closed" || state == "failed")
        if state == "connected" {
            reconnectAttempt = 0
            isReconnecting = false
        } else if dropped, voiceMode == .realtime, !isReconnecting {
            scheduleAutoReconnect()
        }
    }

    /// Reconnect with exponential backoff (1, 2, 4, 8, 16s) up to 5 tries, waiting
    /// for the network if she is offline. After that, fall back to the manual
    /// "Tap to reconnect" so she is never stuck without an option.
    private func scheduleAutoReconnect() {
        guard reconnectAttempt < 5 else {
            setNeedsConnection(.connectionFailed, state: "failed")
            isReconnecting = false
            return
        }
        isReconnecting = true
        let delay = min(pow(2.0, Double(reconnectAttempt)), 16)
        reconnectAttempt += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard isReconnecting else { return }
            if !Reachability.shared.isOnline {
                isReconnecting = false
                scheduleAutoReconnect()   // retry the same attempt once back online-ish
                return
            }
            ArtemisLog.info("Realtime: auto-reconnecting (attempt \(reconnectAttempt))…")
            reconnectVoice()
            isReconnecting = false
        }
    }
    func voiceClientDidReceiveAudio(_ client: RealtimeVoiceClient) {
        didReceiveModelAudio = true
    }
    func voiceClient(_ client: RealtimeVoiceClient, didReportTokenStatus status: String) {
        lastTokenStatus = status
    }
}
