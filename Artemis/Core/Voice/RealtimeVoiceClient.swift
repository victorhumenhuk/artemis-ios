//  RealtimeVoiceClient.swift
//  One protocol isolates the voice transport so the OpenAI realtime SDK can be
//  swapped for the on-device client without the rest of the app knowing.

import Foundation

@MainActor
protocol RealtimeVoiceClientDelegate: AnyObject {
    func voiceClientDidConnect(_ client: RealtimeVoiceClient)
    func voiceClient(_ client: RealtimeVoiceClient, didUpdateUserTranscript itemId: String, text: String, isFinal: Bool)
    /// Create or update the assistant bubble for a specific model message item,
    /// so streaming updates one bubble and never fragments.
    func voiceClient(_ client: RealtimeVoiceClient, didUpsertAssistantMessage id: String, text: String, isFinal: Bool)
    func voiceClient(_ client: RealtimeVoiceClient, didChangeUserSpeaking speaking: Bool)
    func voiceClient(_ client: RealtimeVoiceClient, didChangeModelSpeaking speaking: Bool)
    /// The model wants to run a tool. Return the JSON result string.
    func voiceClient(_ client: RealtimeVoiceClient, requestsTool name: String, callId: String, argumentsJSON: String) async -> String
    func voiceClient(_ client: RealtimeVoiceClient, didError error: Error)

    // Diagnostics (default no-op; the engine implements them for the overlay).
    func voiceClient(_ client: RealtimeVoiceClient, didChangeConnectionState state: String)
    func voiceClientDidReceiveAudio(_ client: RealtimeVoiceClient)
    func voiceClient(_ client: RealtimeVoiceClient, didReportTokenStatus status: String)
}

extension RealtimeVoiceClientDelegate {
    func voiceClient(_ client: RealtimeVoiceClient, didChangeConnectionState state: String) {}
    func voiceClientDidReceiveAudio(_ client: RealtimeVoiceClient) {}
    func voiceClient(_ client: RealtimeVoiceClient, didReportTokenStatus status: String) {}
}

@MainActor
protocol RealtimeVoiceClient: AnyObject {
    var delegate: RealtimeVoiceClientDelegate? { get set }
    var isConnected: Bool { get }

    /// true: the remote model reasons (calls tools) and speaks its own audio.
    /// false: the engine reasons locally and we drive text-to-speech here.
    var handlesReasoning: Bool { get }

    func connect() async throws
    func disconnect()

    func startListening()
    func stopListening()
    func setMuted(_ muted: Bool)

    /// Typed input. `silent` suppresses spoken audio for this turn.
    func sendText(_ text: String, silent: Bool) async throws

    /// Engine-driven speech (used by the on-device client). No-op for OpenAI,
    /// whose model speaks its own audio.
    func speak(_ text: String)
    func stopSpeaking()
    func interrupt()
}
