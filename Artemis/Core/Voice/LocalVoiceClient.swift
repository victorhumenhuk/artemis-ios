//  LocalVoiceClient.swift
//  The always-available voice path: Apple on-device speech recognition for
//  listening, AVSpeech for Artemis's voice. The engine does the reasoning
//  (handlesReasoning = false), so this works with no network and no SDK, and
//  is what powers the offline-safety path too.

import Foundation
import Speech
import AVFoundation

@MainActor
final class LocalVoiceClient: NSObject, RealtimeVoiceClient {
    weak var delegate: RealtimeVoiceClientDelegate?
    private(set) var isConnected = false
    let handlesReasoning = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()

    private var muted = false
    private var listening = false
    private var speaking = false
    private var lastTranscript = ""
    private var hadSpeech = false
    private var utteranceID = UUID().uuidString   // one id per spoken utterance, so the UI keeps one live bubble
    private var silenceTimer: Timer?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: permissions (called once at launch by the engine)

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in c.resume(returning: granted) }
        }
        return speech && mic
    }

    // MARK: lifecycle

    func connect() async throws {
        isConnected = true
        delegate?.voiceClientDidConnect(self)
    }

    func disconnect() {
        stopListening()
        stopSpeaking()
        isConnected = false
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        if muted { stopListening() }
    }

    // MARK: listening

    func startListening() {
        guard !muted, !speaking, !listening else { return }
        guard let recognizer, recognizer.isAvailable else { return }

        AudioSessionManager.configureForConversation()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            // On device when offline; either way nothing is uploaded for storage.
            req.requiresOnDeviceRecognition = !Reachability.shared.isOnline
        }
        request = req

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch { return }

        listening = true
        hadSpeech = false
        lastTranscript = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        if !self.hadSpeech {
                            self.hadSpeech = true
                            self.utteranceID = UUID().uuidString
                            self.delegate?.voiceClient(self, didChangeUserSpeaking: true)
                        }
                        self.lastTranscript = text
                        self.delegate?.voiceClient(self, didUpdateUserTranscript: self.utteranceID, text: text, isFinal: false)
                        self.resetSilenceTimer()
                    }
                    if result.isFinal { self.finalizeTurn() }
                }
                if error != nil { self.finalizeTurn() }
            }
        }
    }

    func stopListening() {
        silenceTimer?.invalidate(); silenceTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel(); task = nil
        request = nil
        listening = false
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endAudioForTurn() }
        }
    }

    private func endAudioForTurn() {
        request?.endAudio()
    }

    private func finalizeTurn() {
        guard listening else { return }
        let text = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopListening()
        if hadSpeech { delegate?.voiceClient(self, didChangeUserSpeaking: false) }
        if !text.isEmpty {
            delegate?.voiceClient(self, didUpdateUserTranscript: utteranceID, text: text, isFinal: true)
        }
    }

    // MARK: speaking (engine-driven)

    func sendText(_ text: String, silent: Bool) async throws {
        // The engine handles typed input directly; nothing to send remotely.
    }

    func speak(_ text: String) {
        stopListening()
        speaking = true
        delegate?.voiceClient(self, didChangeModelSpeaking: true)
        AudioSessionManager.configureForConversation()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1.02
        synth.speak(utterance)
    }

    func stopSpeaking() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func interrupt() {
        stopSpeaking()
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        // A warm British female voice if available.
        if let v = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == "en-GB" && $0.gender == .female
        }) { return v }
        return AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension LocalVoiceClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.delegate?.voiceClient(self, didChangeModelSpeaking: false)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            self.delegate?.voiceClient(self, didChangeModelSpeaking: false)
        }
    }
}
