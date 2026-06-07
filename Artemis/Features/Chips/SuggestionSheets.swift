//  SuggestionSheets.swift
//  Capabilities live as suggestion chips inside the conversation, not as a tab
//  bar or feature grid. A chip opens a single-purpose bottom sheet that returns
//  a result card with the NHS citation into the chat thread.

import SwiftUI

enum ChipKind: Identifiable {
    case safe, bp, mood, symptoms, kicks, dailyCheckin
    var id: String { String(describing: self) }
}

// MARK: - Quick-start chips (a small set above the input at rest)

struct SuggestionChipsBar: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L("checkin", engine.uiLanguage), "heart") { engine.openChip(.dailyCheckin) }
                chip(L("mood", engine.uiLanguage), "heart") { engine.openChip(.mood) }
                chip(L("symptoms", engine.uiLanguage), "drop") { engine.talkAboutSymptoms() }
                chip(L("bp", engine.uiLanguage), "drop") { engine.openChip(.bp) }
                chip(L("kicks", engine.uiLanguage), "sparkle") { engine.openChip(.kicks) }
                chip(L("safe", engine.uiLanguage), "shield") { engine.openChip(.safe) }
                chip(L("appointment", engine.uiLanguage), "person") { engine.buildAdvocacy() }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icon(name: icon, size: 14).foregroundStyle(p.sage600)
                Text(title).font(ArtemisFont.sans(13.5, .semibold)).foregroundStyle(p.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(p.hairline, lineWidth: 1))
        }
        .buttonStyle(PressButtonStyle())
    }
}

// MARK: - Chip sheet host

struct ChipSheetHost: View {
    let kind: ChipKind
    var body: some View {
        switch kind {
        case .safe: SafeCheckSheet()
        case .bp: BPCheckSheet()
        case .mood: MoodSheet()
        case .symptoms: SymptomSheet()
        case .kicks: KicksSheet()
        case .dailyCheckin: DailyCheckInSheet()
        }
    }
}

// MARK: - Daily check-in (mood + BP + kicks, together)

struct DailyCheckInSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    private let faces = ["😞", "🙁", "😐", "🙂", "😊"]
    @State private var mood = 0
    @State private var systolic = ""
    @State private var diastolic = ""
    @State private var kicks = 0

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.82, onClose: { engine.closeChip() }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Daily check-in").voiceStyle(28, weight: .medium).foregroundStyle(p.ink)
                        Text("Mood, blood pressure and movements, all in one. Fill what you have.")
                            .font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
                    }

                    section("How is your mood?") {
                        HStack(spacing: 8) {
                            ForEach(1...5, id: \.self) { s in
                                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { mood = s }; Haptics.tap() } label: {
                                    Text(faces[s - 1]).font(.system(size: 30))
                                        .frame(maxWidth: .infinity).frame(height: 58)
                                        .background(mood == s ? p.sage200 : p.sage50, in: RoundedRectangle(cornerRadius: 14))
                                        .scaleEffect(mood == s ? 1.08 : 1.0)
                                }.buttonStyle(PressButtonStyle())
                            }
                        }
                    }

                    section("Blood pressure (optional)") {
                        HStack(spacing: 12) {
                            numField("top", $systolic)
                            Text("/").font(ArtemisFont.sans(26, .semibold)).foregroundStyle(p.inkMute)
                            numField("bottom", $diastolic)
                        }
                    }

                    section("Movements (optional)") {
                        HStack(spacing: 14) {
                            Text("\(kicks)").font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(p.sage700).contentTransition(.numericText(value: Double(kicks)))
                                .frame(minWidth: 50)
                            Button { kicks += 1; Haptics.tap() } label: {
                                Text("Tap for each kick").font(ArtemisFont.sans(15, .semibold)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).frame(height: 50).background(p.sage600, in: Capsule())
                            }.buttonStyle(PressButtonStyle())
                        }
                    }

                    PillButton(title: "Save check-in", tone: .sage) {
                        engine.submitDailyCheckin(mood: mood, systolic: Int(systolic.filter(\.isNumber)),
                                                  diastolic: Int(diastolic.filter(\.isNumber)), kicks: kicks)
                    }
                    Text("Logged to your private history, on this phone, so Artemis can notice patterns.")
                        .font(ArtemisFont.sans(11.5)).foregroundStyle(p.inkMute)
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(ArtemisFont.sans(15, .semibold)).foregroundStyle(p.ink)
            content()
        }
    }
    private func numField(_ hint: String, _ value: Binding<String>) -> some View {
        TextField(hint, text: value)
            .keyboardType(.numberPad).font(ArtemisFont.sans(22, .semibold)).multilineTextAlignment(.center)
            .padding(.vertical, 12).frame(maxWidth: .infinity)
            .background(p.sage50, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Mood

struct MoodSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    private let faces = ["😞", "🙁", "😐", "🙂", "😊"]
    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.42, onClose: { engine.closeChip() }) {
            VStack(alignment: .leading, spacing: 16) {
                Text("How is your mood?").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { s in
                        Button { engine.submitMood(s) } label: {
                            Text(faces[s - 1]).font(.system(size: 34))
                                .frame(maxWidth: .infinity).frame(height: 64)
                                .background(p.sage50, in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(PressButtonStyle())
                    }
                }
                Text("Logged to your private history, so Artemis can notice patterns.")
                    .font(ArtemisFont.sans(11.5)).foregroundStyle(p.inkMute)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 24)
        }
    }
}

// MARK: - Symptom

struct SymptomSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var text = ""
    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.45, onClose: { engine.closeChip() }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Log a symptom").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                TextField("e.g. swelling, headache, nausea", text: $text)
                    .font(ArtemisFont.sans(17)).padding(.horizontal, 16).padding(.vertical, 14)
                    .background(p.sage50, in: RoundedRectangle(cornerRadius: 14))
                    .submitLabel(.done).onSubmit { engine.submitSymptom(text) }
                PillButton(title: "Log it", tone: .sage) { engine.submitSymptom(text) }
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 24)
        }
    }
}

// MARK: - Kicks

struct KicksSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var count = 0
    @State private var ripple = false
    @State private var bump = false
    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.56, onClose: { engine.closeChip() }) {
            VStack(spacing: 18) {
                Text("Count the kicks").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // A living count: expanding ripple on each tap, a soft bump on the number.
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .stroke(p.sage300.opacity(ripple ? 0 : 0.5), lineWidth: 2)
                            .frame(width: 120, height: 120)
                            .scaleEffect(ripple ? 1.5 + Double(i) * 0.2 : 0.8)
                    }
                    Circle().fill(p.sage50).frame(width: 120, height: 120)
                    Text("\(count)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(p.sage700)
                        .contentTransition(.numericText(value: Double(count)))
                        .scaleEffect(bump ? 1.18 : 1.0)
                }
                .frame(height: 140)

                Button {
                    count += 1
                    Haptics.tap()
                    ripple = false; bump = false
                    withAnimation(.easeOut(duration: 0.55)) { ripple = true }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { bump = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 160_000_000)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bump = false }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Icon(name: "sparkle", size: 16)
                        Text("Tap for each movement").font(ArtemisFont.sans(16, .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 56).background(p.sage600, in: Capsule())
                }.buttonStyle(PressButtonStyle())

                PillButton(title: "Save count", tone: .sage) { engine.submitKicks(count) }
                Text("Reduced movements should always be checked, day or night.")
                    .font(ArtemisFont.sans(11.5)).foregroundStyle(p.inkMute).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 24)
        }
    }
}

// MARK: - "Is this safe?" sheet

struct SafeCheckSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.5, onClose: { engine.closeChip() }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Is this safe?").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                    Text("A medicine, food, or activity. I'll check NHS guidance.")
                        .font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
                }
                TextField("e.g. paracetamol, brie, running", text: $text)
                    .font(ArtemisFont.sans(17)).focused($focused)
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background(p.sage50, in: RoundedRectangle(cornerRadius: 14))
                    .submitLabel(.go).onSubmit(submit)
                PillButton(title: "Check NHS guidance", tone: .sage, action: submit)
                Text("Artemis never diagnoses. She checks NHS guidance and helps you be heard.")
                    .font(ArtemisFont.sans(11.5)).foregroundStyle(p.inkMute)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 24)
            .onAppear { focused = true }
        }
    }
    private func submit() { engine.submitSafeCheck(text) }
}

// MARK: - Blood-pressure self-check sheet

struct BPCheckSheet: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var systolic = ""
    @State private var diastolic = ""

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.55, onClose: { engine.closeChip() }) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blood pressure").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                    Text("Enter your reading. I'll check it against NHS thresholds.")
                        .font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
                }
                HStack(spacing: 12) {
                    field("Systolic", "top number", $systolic)
                    Text("/").font(ArtemisFont.sans(28, .semibold)).foregroundStyle(p.inkMute)
                    field("Diastolic", "bottom number", $diastolic)
                }
                PillButton(title: "Check this reading", tone: .sage, action: submit)
                Text("Flags and signposts only, never a diagnosis. Thresholds from NHS guidance.")
                    .font(ArtemisFont.sans(11.5)).foregroundStyle(p.inkMute)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 24)
        }
    }

    private func field(_ label: String, _ hint: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(hint, text: value)
                .keyboardType(.numberPad).font(ArtemisFont.sans(24, .semibold))
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(p.sage50, in: RoundedRectangle(cornerRadius: 14))
            Text(label).font(ArtemisFont.sans(12, .semibold)).foregroundStyle(p.inkMute)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func submit() {
        guard let s = Int(systolic.filter(\.isNumber)), let d = Int(diastolic.filter(\.isNumber)), s > 0, d > 0 else { return }
        engine.submitBPCheck(systolic: s, diastolic: d)
    }
}
