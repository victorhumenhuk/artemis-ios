//  OpenAIRealtimeClient.swift
//  The OpenAI GA Realtime path over WebRTC, using the pinned swift-realtime-openai
//  SDK. The model is gpt-realtime-2, the voice is marin, and we connect with an
//  ephemeral key minted by the Worker, so no OpenAI key ever lives in the app.
//
//  While online this is the ONLY source of replies. There is no on-device
//  text-to-speech here: the model speaks its own audio. Behind canImport(RealtimeAPI).

import Foundation

#if canImport(RealtimeAPI)
import RealtimeAPI
import AVFoundation

@MainActor
final class OpenAIRealtimeClient: NSObject, RealtimeVoiceClient {
    weak var delegate: RealtimeVoiceClientDelegate?
    private(set) var isConnected = false
    let handlesReasoning = true     // the model reasons (tools) and speaks audio
    /// The raw-mic on-device captioner conflicts with WebRTC on device (echo, mic
    /// starvation, voice cutting out). Off by default; the realtime transcript drives
    /// her words instead.
    static let useOnDeviceCaption = false

    /// Recent check-in context, set by the engine before connect, so the model
    /// can reason over real logged data (drift observations come from the model).
    var sessionContext: String?

    /// Greet on connect only for a new thread; returning users aren't re-greeted.
    var greetOnConnect = true

    /// The female voice we require: marin (female). coral and shimmer are the
    /// female fallbacks. marin compiles and is accepted by the API, so it's used.
    private(set) var acceptedVoice = "marin"

    private var conversation: Conversation?
    private var processedCallIds = Set<String>()
    private var lastUserText = ""
    private var lastUserItemID = ""

    // On-device LIVE caption (words as she speaks), running alongside realtime.
    var preferredLanguage: String?
    private let liveTranscriber = LiveTranscriber()
    private var liveCount = 0
    private var liveProducedAnything = false   // did on-device capture actually yield words?
    private var liveItemID: String { "live-\(liveCount)" }
    private var lastAssistantText = ""
    private var lastAssistantItemID = ""
    private var wasUserSpeaking = false
    private var didGreet = false
    private var sawAudio = false
    private var pollTimer: Timer?
    // Edge-detection for the 0.2s poll: only fire delegate callbacks on an ACTUAL
    // state change, never on every stable tick (which re-ran beginAssistantTurn and
    // wiped partial responses).
    private var lastSentConnState: String?
    private var lastSentUserSpeaking: Bool?
    private var lastSentModelSpeaking: Bool?

    // MARK: connect

    func connect() async throws {
        delegate?.voiceClient(self, didChangeConnectionState: "connecting")
        ArtemisLog.info("Realtime: connecting… [build LOCFIX-OK]")

        // playAndRecord + defaultToSpeaker, activated, so the model's remote audio
        // track is AUDIBLE (output works on the simulator even though mic capture
        // is unreliable there) and is not silenced by the ring/mute switch.
        AudioSessionManager.configureForConversation()

        let ephemeralKey = try await fetchEphemeralKey()

        let instructions = sessionContext.map { RealtimeConfig.systemPrompt + "\n\n" + $0 } ?? RealtimeConfig.systemPrompt
        self.fullInstructions = instructions

        // The configuring closure is applied when the session is created, so the
        // voice and instructions are set BEFORE any audio plays (voice is then
        // immutable for the session).
        let convo = try Conversation { session in
            session.instructions = instructions
            session.audio.output.voice = .marin            // female; set before any audio
            // GA schema: output_modalities (voice experience). The spoken-word
            // transcript still comes back via audio input transcription below.
            session.outputModalities = [.audio]
            // STREAMING transcription model: gpt-4o-mini-transcribe emits delta
            // events DURING speech, so her words appear live. The .gpt4o case maps
            // to "gpt-4o-transcribe-latest", which the GA realtime API does not
            // accept, so transcription silently never turned on (the recurring bug).
            session.audio.input.transcription = .init(model: .gpt4oMini)
            // Short silence window so Artemis responds promptly once she finishes.
            // Longer silence window so a brief pause mid-sentence does not split her
            // utterance into two turns (which caused the duplicate "...twice" bubble
            // and a double reply). One natural pause stays one turn.
            // Higher threshold + a touch longer silence, so background noise and the
            // loudspeaker echoing Artemis's own voice do NOT trip the VAD. interruptResponse
            // false means detected speech (including her own voice echoing from the
            // speaker) can NOT cut off and restart her reply, which is what made her
            // answer over and over. prefixPadding keeps her first words.
            session.audio.input.turnDetection = .serverVad(createResponse: true, interruptResponse: true, prefixPaddingMs: 300, silenceDurationMs: 1000, threshold: 0.62)
            session.tools = OpenAIRealtimeClient.makeTools()
            session.toolChoice = .auto
        }
        self.conversation = convo
        // Tap the raw JSON at the receive/send boundary (before decode), and
        // surface decode failures, for the developer console.
        RealtimeRawTap.inbound = { raw in Task { @MainActor in RealtimeEventLog.shared.record(raw) } }
        RealtimeRawTap.outbound = { raw in Task { @MainActor in RealtimeEventLog.shared.record(raw, outbound: true) } }
        RealtimeRawTap.decodeFailure = { raw, err in
            Task { @MainActor in RealtimeEventLog.shared.record(raw + " | " + String(describing: err), decodeError: true) }
        }

        do {
            try await convo.connect(ephemeralKey: ephemeralKey, model: .custom(RealtimeConfig.model))
        } catch {
            // Classify so the engine can state the real reason.
            let desc = "\(error)".lowercased()
            if desc.contains("permission") || desc.contains("audio") {
                throw NSError(domain: "Artemis.Voice", code: 10, userInfo: [NSLocalizedDescriptionKey: "microphone or audio capture unavailable"])
            }
            throw NSError(domain: "Artemis.Voice", code: 20, userInfo: [NSLocalizedDescriptionKey: "data channel / connection failed"])
        }

        isConnected = true
        delegate?.voiceClient(self, didChangeConnectionState: "connected")
        ArtemisLog.info("Realtime: connected. model=\(RealtimeConfig.model) voice=\(acceptedVoice)")
        print("[Artemis] Realtime connected. model=\(RealtimeConfig.model) voice=\(acceptedVoice)")
        delegate?.voiceClientDidConnect(self)
        observe()
        startLiveCaption()

        // Greet ONLY after the session is created and the Artemis instructions
        // have been applied, otherwise the model greets as a default assistant.
        Task { @MainActor [weak self] in
            for _ in 0..<60 where convo.session == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            if self?.greetOnConnect == true { self?.greetFromModel() }
        }
    }

    private var fullInstructions = RealtimeConfig.systemPrompt

    /// The opening greeting is spoken by the model itself, never synthesised.
    private func greetFromModel() {
        guard !didGreet, let convo = conversation else { return }
        didGreet = true
        // Re-assert the Artemis instructions, then greet, so she never greets as
        // a generic assistant if the initial session.update was still in flight.
        try? convo.updateSession { session in
            session.instructions = self.fullInstructions
        }
        // send(from:text:) ALREADY triggers one response.create. A second explicit
        // createResponse here is what produced the double/triple greeting + voice.
        // One turn, one response. Server VAD creates the response for spoken turns.
        try? convo.send(from: .system, text: "The app just opened and she can hear you. Greet her warmly in one short sentence as Artemis, then listen.")
    }

    /// Start the on-device live caption so her words appear AS she speaks. The
    /// realtime API's own transcript arrives only after the turn, so this drives
    /// the live bubble; if it cannot run, the realtime transcript is the fallback.
    private func startLiveCaption() {
        // The raw-mic AVAudioEngine captioner fights WebRTC for the microphone on a
        // real device: it breaks echo cancellation (she replies many times), starves
        // the mic so the voice cuts out, and itself produces nothing. We rely on the
        // realtime transcript for her words instead, which is reliable. Flip this to
        // true only to experiment with the on-device live captioner.
        guard Self.useOnDeviceCaption else {
            ArtemisLog.info("LIVECAP: on-device caption disabled; realtime transcript drives her words.")
            return
        }
        liveProducedAnything = false
        conversation?.onLocalAudioBuffer = nil
        liveTranscriber.configure(languageName: preferredLanguage)
        liveTranscriber.onText = { [weak self] text, final in
            guard let self else { return }
            self.liveProducedAnything = true
            self.delegate?.voiceClient(self, didUpdateUserTranscript: self.liveItemID, text: text, isFinal: final)
            if final { self.liveCount += 1 }
        }
        liveTranscriber.start()
        ArtemisLog.info("LIVECAP: on-device live caption started (raw mic), running=\(liveTranscriber.isRunning)")
    }

    func disconnect() {
        pollTimer?.invalidate(); pollTimer = nil
        liveTranscriber.stop()
        conversation = nil
        isConnected = false
        delegate?.voiceClient(self, didChangeConnectionState: "idle")
    }

    func setMuted(_ muted: Bool) {
        conversation?.muted = muted   // muted ONLY when she pauses; never auto-muted mid-turn
        if muted { liveTranscriber.stop(); liveProducedAnything = false } else if isConnected { startLiveCaption() }
    }
    func startListening() { conversation?.muted = false; if isConnected, !liveTranscriber.isRunning { startLiveCaption() } }
    func stopListening() { liveTranscriber.stop() }   // tapping the wave / orb stops the live caption too

    func sendText(_ text: String, silent: Bool) async throws {
        guard let convo = conversation else { return }
        try convo.send(from: .user, text: text)
    }

    /// Say a short app-authored line (e.g. a logging confirmation) in Artemis's own
    /// voice, plainly and once. send(from:.system) triggers exactly one spoken response.
    func speak(_ text: String) {
        guard isConnected, let convo = conversation else { return }
        try? convo.send(from: .system, text: "Now say this to her out loud, warmly and once, and add nothing else: \"\(text)\"")
    }
    func stopSpeaking() {}

    func interrupt() {
        try? conversation?.send(event: .cancelResponse())
        try? conversation?.send(event: .outputAudioBufferClear())
    }

    // MARK: observation

    private func observe() {
        // Poll the @Observable Conversation on the main run loop. This is robust
        // against the high-frequency transcript/tool-call stream (the
        // withObservationTracking re-register pattern drops rapid updates).
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleChange() }
        }
    }

    private func handleChange() {
        guard let convo = conversation else { return }

        let st = statusText(convo.status)
        RealtimeEventLog.shared.connectionState = st
        RealtimeEventLog.shared.dataChannelState = (st == "connected") ? "open" : "closed"
        // Fire ONLY on real transitions, so a stable multi-second utterance does not
        // re-trigger beginAssistantTurn() every tick and erase the streaming reply.
        let userSpeaking = convo.isUserSpeaking
        let modelSpeaking = convo.isModelSpeaking
        // NO app-level half-duplex muting. WebRTC's own echo cancellation handles the
        // speaker bleed; muting the mic here was what made her voice cut out between
        // turns. interruptResponse=false in the VAD config stops echo from restarting a
        // reply. The mic is muted only when SHE pauses (setMuted), never automatically.
        liveTranscriber.setPaused(modelSpeaking)
        if st != lastSentConnState {
            lastSentConnState = st
            delegate?.voiceClient(self, didChangeConnectionState: st)
        }
        if userSpeaking != lastSentUserSpeaking {
            lastSentUserSpeaking = userSpeaking
            delegate?.voiceClient(self, didChangeUserSpeaking: userSpeaking)
        }
        if modelSpeaking != lastSentModelSpeaking {
            lastSentModelSpeaking = modelSpeaking
            delegate?.voiceClient(self, didChangeModelSpeaking: modelSpeaking)
        }

        // Audio flowing back from the model (the high-level SDK plays audio deltas
        // automatically; model-speaking reflects that they are arriving).
        if convo.isModelSpeaking, !sawAudio {
            sawAudio = true
            ArtemisLog.info("Realtime: receiving model audio.")
            print("[Artemis] Realtime: receiving model audio (response.output_audio.delta).")
            delegate?.voiceClientDidReceiveAudio(self)
        }

        // Live transcription of HER speech: stream the input-transcription as it
        // grows (isFinal=false), and commit once when speech stops (isFinal=true),
        // even if the last tick's text was unchanged.
        let speaking = convo.isUserSpeaking
        // The on-device live caption is the source of HER bubble once it has
        // produced words, so skip the realtime transcript to avoid a second bubble.
        // If the on-device capture yields nothing (mic owned by WebRTC), fall back
        // to the realtime transcript so a bubble still appears.
        // The on-device caption owns her transcript once it has produced words. If it
        // yields nothing (silence, or a device where the recogniser is unavailable),
        // the realtime transcript feeds the SAME live interim caption as a fallback,
        // so there is always a live transcription and never a duplicate.
        let liveOwnsBubble = Self.useOnDeviceCaption && liveTranscriber.isRunning && liveProducedAnything
        // Drive the on-device caption's turn boundary off the realtime VAD: when
        // she stops, close the bubble so the next words start a fresh one.
        if liveTranscriber.isRunning, wasUserSpeaking, !speaking { liveTranscriber.endTurn() }
        if !liveOwnsBubble, let umsg = convo.messages.last(where: { $0.role == .user }) {
            let user = umsg.content.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let itemID = "\(umsg.id)"
            if !user.isEmpty {
                let stoppedNow = wasUserSpeaking && !speaking
                if user != lastUserText || itemID != lastUserItemID || stoppedNow {
                    lastUserText = user
                    lastUserItemID = itemID
                    // Forward the item id so the UI keeps her words in ONE live bubble.
                    delegate?.voiceClient(self, didUpdateUserTranscript: itemID, text: user, isFinal: !speaking)
                }
            }
        }
        wasUserSpeaking = speaking
        // Upsert the latest assistant message by its item id, so streaming text
        // fills one bubble (immune to spurious VAD on the simulator).
        if let msg = convo.messages.last(where: { $0.role == .assistant }) {
            let text = msg.content.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let itemID = "\(msg.id)"
            if !text.isEmpty, itemID != lastAssistantItemID || text != lastAssistantText {
                lastAssistantItemID = itemID
                lastAssistantText = text
                delegate?.voiceClient(self, didUpsertAssistantMessage: itemID, text: text, isFinal: !convo.isModelSpeaking)
            }
        }

        for entry in convo.entries {
            if case let .functionCall(call) = entry, call.status == .completed, !processedCallIds.contains(call.callId) {
                processedCallIds.insert(call.callId)
                Task { @MainActor in await self.runTool(call) }
            }
        }
    }

    private func statusText(_ status: RealtimeAPI.Status) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        @unknown default: return String(describing: status)
        }
    }

    private func latestText(role: Item.Message.Role) -> String? {
        guard let msg = conversation?.messages.last(where: { $0.role == role }) else { return nil }
        let t = msg.content.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var createResponseWork: DispatchWorkItem?

    private func runTool(_ call: Item.FunctionCall) async {
        ArtemisLog.info("Realtime: tool call \(call.name)")
        let output = await delegate?.voiceClient(self, requestsTool: call.name, callId: call.callId, argumentsJSON: call.arguments) ?? "{}"
        try? conversation?.send(result: .init(id: String(UUID().uuidString.prefix(32)), callId: call.callId, output: output))
        // Debounce the follow-up response: when the model calls SEVERAL tools in one
        // turn (e.g. NHS lookup + assess), each tool result must NOT fire its own
        // createResponse, or the second collides with the first
        // ("conversation_already_has_active_response") and the whole turn breaks. We
        // send exactly ONE createResponse after the last tool of the batch settles.
        createResponseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in try? self?.conversation?.send(event: .createResponse()) }
        createResponseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: tools (mirror Tools.swift, expressed in the SDK schema DSL)

    nonisolated private static func makeTools() -> [Tool] {
        [
            .function(.init(
                name: ArtemisTool.retrieveNHSGuidance.rawValue,
                description: ArtemisTool.retrieveNHSGuidance.toolDescription,
                parameters: .object(properties: [
                    "query": .string(description: "What she described, in plain words."),
                    "suspected_topics": .array(of: .string(description: "A possible condition.")),
                ]))),
            .function(.init(
                name: ArtemisTool.assessSymptoms.rawValue,
                description: ArtemisTool.assessSymptoms.toolDescription,
                parameters: .object(properties: [
                    "tier": .enum(cases: ["reassuring", "self_care", "routine", "urgent", "emergency"]),
                    "spoken_response": .string(description: "A warm reply under three sentences."),
                    "matched_condition": .string(description: "A neutral topic you phrase, never her exact words or a question."),
                    "red_flags_detected": .array(of: .string(description: "Concerning signs.")),
                    "nhs_source_title": .string(description: "NHS article title."),
                    "nhs_source_url": .string(description: "NHS article url."),
                    "recommended_action": .string(description: "What to do now."),
                    "route_to": .enum(cases: ["maternity_triage", "nhs111", "emergency999", "gp", "none"]),
                ]))),
            .function(.init(
                name: ArtemisTool.findNearestService.rawValue,
                description: ArtemisTool.findNearestService.toolDescription,
                parameters: .object(properties: [
                    "service_type": .string(description: "e.g. maternity_unit."),
                    "lat": .number(description: "Latitude, if known."),
                    "lng": .number(description: "Longitude, if known."),
                ]))),
            .function(.init(
                name: ArtemisTool.logCheckin.rawValue,
                description: ArtemisTool.logCheckin.toolDescription,
                parameters: .object(properties: [
                    "physical_signals": .array(of: .string(description: "Bodily signals.")),
                    "emotional_signals": .array(of: .string(description: "Feelings.")),
                    "concerns": .array(of: .string(description: "Her worries.")),
                    "themes": .array(of: .string(description: "Recurring tags.")),
                    "mood_score": .integer(description: "1 to 5."),
                    "reflection_summary": .string(description: "Warm paraphrase."),
                    "flags_for_followup": .array(of: .string(description: "Watch items.")),
                    "summary_line": .string(description: "One line for trends."),
                ]))),
            .function(.init(
                name: ArtemisTool.getRecentCheckins.rawValue,
                description: ArtemisTool.getRecentCheckins.toolDescription,
                parameters: .object(properties: [
                    "limit": .integer(description: "How many to read."),
                ]))),
        ]
    }

    // MARK: ephemeral key

    private struct TokenResponse: Decodable {
        let value: String?
        struct ClientSecret: Decodable { let value: String? }
        let client_secret: ClientSecret?
        var key: String? { value ?? client_secret?.value }
    }

    private func fetchEphemeralKey() async throws -> String {
        let url = RealtimeConfig.serverBaseURL.appendingPathComponent("realtime/token")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            RealtimeEventLog.shared.tokenResult = "HTTP \(code)"
            delegate?.voiceClient(self, didReportTokenStatus: "HTTP \(code)")
            guard (200..<300).contains(code) else {
                ArtemisLog.error("Token: server returned HTTP \(code).")
                throw NSError(domain: "Artemis.Token", code: code, userInfo: [NSLocalizedDescriptionKey: "token server HTTP \(code)"])
            }
            guard let key = (try? JSONDecoder().decode(TokenResponse.self, from: data))?.key, !key.isEmpty else {
                ArtemisLog.error("Token: no ephemeral key in response.")
                throw NSError(domain: "Artemis.Token", code: -2, userInfo: [NSLocalizedDescriptionKey: "no ephemeral key"])
            }
            ArtemisLog.info("Token: minted ephemeral key (\(key.prefix(3))…).")
            return key
        } catch {
            RealtimeEventLog.shared.tokenResult = "unreachable"
            delegate?.voiceClient(self, didReportTokenStatus: "unreachable")
            ArtemisLog.error("Token: \(error.localizedDescription).")
            // Classify as a token-server reach failure so the status is honest.
            throw NSError(domain: "Artemis.Token", code: -3, userInfo: [NSLocalizedDescriptionKey: "token server unreachable"])
        }
    }
}
#endif
