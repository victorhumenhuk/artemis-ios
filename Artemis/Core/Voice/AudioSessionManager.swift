//  AudioSessionManager.swift
//  Configures the shared audio session for a calm voice conversation: record +
//  playback, voice-chat mode, speaker by default.

import Foundation
import AVFoundation

enum AudioSessionManager {
    static func configureForConversation() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
            try session.setActive(true, options: [])
            // Make sure her voice comes out of the speaker, not the earpiece.
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            // Non-fatal: the app still works in text mode.
        }
    }

    static func configureForPlaybackOnly() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true, options: [])
        } catch {}
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
