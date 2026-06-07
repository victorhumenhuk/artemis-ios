//  ConversationStateMachine.swift
//  The home screen IS a state machine. Four working states plus a calm idle
//  (entered only when "Listen on open" is off). Each state fixes the mic and
//  audio behaviour, exactly per the spec table.

import Foundation
import Observation

enum ConversationState: String {
    case idle           // listen-on-open is off: tap the orb or type
    case listening      // mic hot, audio on, transcript building
    case silentTyping   // mic muted, audio suppressed (tap to hear), keyboard up
    case thinking       // user turn ended, brief status line
    case responding     // model replying, spoken + text (audio unless silent)

    var micHot: Bool { self == .listening }

    /// Whether spoken audio plays in this state (silent mode overrides to false).
    var audioOutputOn: Bool {
        switch self {
        case .listening, .responding, .idle: return true
        case .thinking, .silentTyping: return false
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Tap the orb or just start talking"
        case .listening: return "Listening"
        case .silentTyping: return "Silent mode · typing"
        case .thinking: return "Checking NHS guidance…"
        case .responding: return "Speaking"
        }
    }

    /// Whether the status line shows the animated live dots.
    var isLive: Bool {
        switch self {
        case .listening, .thinking, .responding: return true
        case .idle, .silentTyping: return false
        }
    }
}

@MainActor @Observable
final class ConversationStateMachine {
    private(set) var state: ConversationState = .idle

    /// Persistent silent-mode toggle: once locked, the session stays text-only.
    private(set) var silentLocked = false

    /// Mic mute toggle, reachable in every state.
    private(set) var micMuted = false

    var isSilent: Bool { silentLocked || state == .silentTyping }

    /// Effective: should spoken audio play right now?
    var audioOn: Bool { state.audioOutputOn && !isSilent }

    // MARK: Transitions

    func enterListening() {
        if silentLocked { state = .silentTyping; return }
        micMuted = false
        state = .listening
    }

    func goIdle() {
        state = .idle
    }

    /// Tapping the text box: mute mic, suppress audio, text-only replies.
    func enterSilentTyping() {
        micMuted = true
        state = .silentTyping
    }

    func enterThinking() { state = .thinking }

    func enterResponding() { state = .responding }

    /// After a reply, settle back to listening or silent typing.
    func settleAfterResponse() {
        if isSilent { state = .silentTyping } else { enterListening() }
    }

    // MARK: Toggles

    /// Persistent silent lock for the whole session.
    func lockSilent(_ on: Bool) {
        silentLocked = on
        if on {
            micMuted = true
            if state == .listening || state == .idle { state = .silentTyping }
        } else {
            enterListening()
        }
    }

    /// Mic mute toggle reachable in every state.
    func toggleMute() {
        if isSilent {
            // unmuting from silent leaves silent mode and starts listening
            silentLocked = false
            micMuted = false
            enterListening()
        } else {
            micMuted.toggle()
            state = micMuted ? .idle : .listening
        }
    }
}
