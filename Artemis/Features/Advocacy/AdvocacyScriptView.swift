//  AdvocacyScriptView.swift
//  The "For your midwife" handover. Built client-side from the stored log, so it
//  works offline. Copyable. Built to the AdvocacySheet design.

import SwiftUI
import AVFoundation

struct AdvocacySheetView: View {
    let script: AdvocacyScript
    var onClose: () -> Void
    @State private var copied = false
    @Environment(\.palette) private var p

    var body: some View {
        ArtemisSheet(tint: p.lilac50, onClose: onClose) {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 3) {
                        HStack(spacing: 7) {
                            Icon(name: "sparkle", size: 16)
                            Text("ADVOCACY SCRIPT").font(ArtemisFont.sans(12.5, .bold)).tracking(1)
                        }
                        .foregroundStyle(p.lilac600)
                        Text(script.title).voiceStyle(27, weight: .medium).foregroundStyle(p.ink).padding(.top, 8)
                        Text(script.generated).font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute)
                    }
                    .padding(.bottom, 18)

                    // the script, typeset like a note
                    HStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 3).fill(p.lilac300).frame(width: 3)
                            .padding(.trailing, 12)
                        VStack(alignment: .leading, spacing: 13) {
                            ForEach(Array(script.body.enumerated()), id: \.offset) { _, line in
                                Text(line).voiceStyle(18, weight: .medium).foregroundStyle(p.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(22)
                    .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(p.hairline, lineWidth: 1))
                    .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 16, y: 6)

                    HStack(spacing: 10) {
                        secondaryButton(copied ? "Copied" : "Copy", icon: copied ? "check" : "link") {
                            UIPasteboard.general.string = script.plainText
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        }
                        secondaryButton("Read aloud", icon: "ear") { Speaker.shared.speak(script.plainText, language: script.language) }
                    }
                    .padding(.top, 16)

                    PillButton(title: "Show this screen to my midwife", tone: .dark, icon: "person").padding(.top, 10)
                }
                .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { Icon(name: icon, size: 18); Text(title).font(ArtemisFont.sans(15.5, .semibold)) }
                .foregroundStyle(p.sage800)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(p.surface, in: Capsule())
                .overlay(Capsule().stroke(p.sage300, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

/// Small shared TTS for "Read aloud". Reads in HER language: an AI advocacy
/// script generated in Arabic/Bengali/etc. must not be voiced with an en-GB
/// voice (silent for non-Latin scripts, mispronounced for Latin ones).
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String, language: String? = nil) {
        let u = AVSpeechUtterance(string: text)
        let localeId = LiveTranscriber.localeId(for: language) ?? "en-GB"
        u.voice = AVSpeechSynthesisVoice(language: localeId)
            ?? AVSpeechSynthesisVoice(language: "en-GB")
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        synth.speak(u)
    }
}
