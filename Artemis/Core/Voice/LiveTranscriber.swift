//  LiveTranscriber.swift
//  Live, word-by-word transcription of HER speech AS she speaks, using the raw
//  microphone via AVAudioEngine (cleaner than WebRTC's processed track, which
//  produced garbled text) and SFSpeechRecognizer with her language's locale.
//
//  Crash-safe: the tap is installed EXACTLY ONCE, only after verifying the input
//  format has real channels (a 0-channel installTap throws an uncatchable
//  NSException). Sub-utterance finals accumulate into ONE bubble; a new bubble
//  starts only when the caller signals the turn ended (endTurn, driven by VAD).

import Foundation
import Speech
import AVFoundation

@MainActor
final class LiveTranscriber {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapInstalled = false
    private var keepRunning = false
    private(set) var isRunning = false

    private var accumulated = ""      // finalised sub-utterances in the CURRENT turn
    private var currentPartial = ""   // live text of the in-flight sub-utterance
    /// When true, captured buffers are ignored (no engine cycling), so Artemis's
    /// own voice echoing from the speaker is never transcribed as if it were hers.
    nonisolated(unsafe) var paused = false

    /// Pause/resume the caption feed. On RESUME (after Artemis finishes speaking),
    /// guarantee a live recognition task exists, because the previous task may have
    /// finalised during the pause. Without this, her first word of the next turn is
    /// silently dropped while a new task spins up (the warm-up gap).
    func setPaused(_ p: Bool) {
        let wasPaused = paused
        paused = p
        guard wasPaused, !p, isRunning, request == nil else { return }
        startTask()   // recogniser is warm and ready before her first buffer arrives
    }

    /// (fullText, isFinalForThisTurn). Same turn keeps one bubble; endTurn closes it.
    var onText: ((String, Bool) -> Void)?

    func configure(languageName: String?) {
        let id = LiveTranscriber.localeId(for: languageName)
        recognizer = (id.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer()
    }

    func start() {
        guard !isRunning else { return }
        let auth = SFSpeechRecognizer.authorizationStatus()
        ArtemisLog.info("LIVECAP: start auth=\(auth.rawValue)")
        guard auth == .authorized else { ArtemisLog.warn("LIVECAP: not authorized"); return }
        guard let recognizer = recognizer ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            ArtemisLog.warn("LIVECAP: recognizer unavailable"); return
        }
        self.recognizer = recognizer

        // Install the tap + start the engine ONCE.
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        ArtemisLog.info("LIVECAP: input format sr=\(format.sampleRate) ch=\(format.channelCount)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            ArtemisLog.warn("LIVECAP: input not ready (0 ch/sr), no live caption"); return
        }
        if tapInstalled { input.removeTap(onBus: 0); tapInstalled = false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, !self.paused else { return }
            self.request?.append(buffer)
        }
        tapInstalled = true
        audioEngine.prepare()
        do { try audioEngine.start(); ArtemisLog.info("LIVECAP: engine started (raw mic)") }
        catch {
            ArtemisLog.warn("LIVECAP: engine.start failed \(error)")
            input.removeTap(onBus: 0); tapInstalled = false; return
        }

        keepRunning = true
        isRunning = true
        accumulated = ""; currentPartial = ""
        startTask()
    }

    private func startTask() {
        guard keepRunning, isRunning, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = false   // best available recogniser, accurate
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty { ArtemisLog.info("LIVECAP: partial '\(text.prefix(48))'") }
                    if result.isFinal {
                        if !text.isEmpty { self.accumulated = self.join(self.accumulated, text) }
                        self.currentPartial = ""
                        self.emit(final: false)
                        self.cycleTask()
                    } else {
                        self.currentPartial = text
                        self.emit(final: false)
                    }
                } else if error != nil {
                    self.cycleTask()
                }
            }
        }
    }

    private func cycleTask() {
        request?.endAudio()
        task = nil
        request = nil
        guard keepRunning, isRunning else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            if self.keepRunning, self.isRunning { self.startTask() }
        }
    }

    /// The realtime VAD says her turn ended: close the current bubble.
    func endTurn() {
        guard isRunning else { return }
        let full = join(accumulated, currentPartial)
        accumulated = ""; currentPartial = ""
        if !full.isEmpty { onText?(full, true) }
    }

    private func emit(final: Bool) {
        let full = join(accumulated, currentPartial)
        if !full.isEmpty { onText?(full, final) }
    }

    private func join(_ a: String, _ b: String) -> String {
        let aa = a.trimmingCharacters(in: .whitespaces), bb = b.trimmingCharacters(in: .whitespaces)
        if aa.isEmpty { return bb }
        if bb.isEmpty { return aa }
        return aa + " " + bb
    }

    func stop() {
        keepRunning = false
        guard isRunning else { return }
        isRunning = false
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        accumulated = ""; currentPartial = ""
    }

    private static func localeId(for language: String?) -> String? {
        guard let l = language?.lowercased() else { return "en-GB" }
        let map: [String: String] = [
            "english": "en-GB", "romanian": "ro-RO", "spanish": "es-ES", "polish": "pl-PL",
            "bengali": "bn-IN", "turkish": "tr-TR", "gujarati": "gu-IN", "punjabi": "pa-IN",
            "urdu": "ur-PK", "french": "fr-FR", "arabic": "ar-SA", "russian": "ru-RU",
        ]
        return map[l] ?? "en-GB"
    }
}
