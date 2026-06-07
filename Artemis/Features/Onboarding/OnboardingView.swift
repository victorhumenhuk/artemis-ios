//  OnboardingView.swift
//  First-run setup, ~40 seconds, then never again. Built to the onboarding
//  design: welcome, microphone, where you are, language, light risk profile,
//  the promise.

import SwiftUI

struct OnboardingView: View {
    var onDone: (UserProfile) -> Void
    var initial: UserProfile? = nil          // pre-fill when re-running from Settings
    @Environment(\.palette) private var p

    @State private var step = 0
    @State private var name = ""
    @State private var stage: Stage = .pregnant
    @State private var weeks = 38
    @State private var birth = "This week"
    @State private var language = "English"
    @State private var firstPregnancy = true
    @State private var ageBand = "30-34"
    @State private var history: Set<String> = []
    @State private var ethnicity = ""

    var body: some View {
        VStack(spacing: 0) {
            // Form steps need the vertical room, so the top spacer + orb shrink.
            Spacer().frame(height: (2...5).contains(step) ? 22 : 60)
            Orb(state: orbState, size: orbSize)
            if (1...5).contains(step) { dots.padding(.top, 10) }
            content.padding(.horizontal, 26)
                .id(step)   // cross-fade between steps
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            if step > 0 {
                Button { withAnimation { step -= 1 } } label: {
                    Icon(name: "chevLeft", size: 18, weight: .semibold).foregroundStyle(p.inkSoft)
                        .frame(width: 42, height: 42).background(p.surface, in: Circle())
                        .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 6, y: 2)
                }
                .buttonStyle(.plain).padding(.leading, 18).padding(.top, 14)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: step)
        .onAppear {
            if let i = initial {           // re-running from Settings: pre-fill her details
                name = i.name; stage = i.stageEnum; weeks = i.weeks; birth = i.birthTiming ?? birth
                language = i.language; firstPregnancy = i.firstPregnancy; ageBand = i.ageBand ?? ageBand
                ethnicity = i.ethnicity
            }
            if let s = ProcessInfo.processInfo.environment["ARTEMIS_ONBOARD_STEP"], let i = Int(s) { step = i }
        }
    }

    private var orbState: ConversationState { step == 0 || step == 6 ? .responding : (step == 1 ? .idle : .listening) }
    private var orbSize: CGFloat { switch step { case 0: return 158; case 1: return 140; case 6: return 124; default: return 64 } }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i == step ? p.sage600 : p.sage200)
                    .frame(width: i == step ? 22 : 6, height: 6)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        case 1: languageStep
        case 2: nameStep
        case 3: stageStep
        case 4: permission
        case 5: riskProfile
        default: promise
        }
    }

    // step 0
    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 0) {
                Text("WELCOME").font(ArtemisFont.sans(12.5, .bold)).tracking(2).foregroundStyle(p.sage600)
                Text("Hello, I'm\nArtemis.").welcomeHeading(40, weight: .medium).multilineTextAlignment(.center)
                    .foregroundStyle(p.ink).padding(.top, 14)
                Text("A calm voice to talk to through your pregnancy. I listen, check NHS guidance, and help you be heard.")
                    .font(ArtemisFont.sans(17)).foregroundStyle(p.inkSoft).multilineTextAlignment(.center)
                    .padding(.top, 18).padding(.horizontal, 6)
            }
            Spacer()
            PillButton(title: "Get started") { step = 1 }
            Text("No account, no email. Your history stays on this phone, and your voice is only ever used to power the conversation.")
                .font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute).padding(.top, 14).padding(.bottom, 40)
        }
    }

    // step 1
    private var permission: some View {
        VStack(spacing: 0) {
            Spacer()
            Icon(name: "mic", size: 30).foregroundStyle(p.sage600)
                .frame(width: 64, height: 64).background(p.sage100, in: Circle())
            Text("Let's find your voice").voiceStyle(27, weight: .medium).foregroundStyle(p.ink).padding(.top, 18)
            Text("To talk with me, I'll need your microphone. You can always type instead.")
                .font(ArtemisFont.sans(17)).foregroundStyle(p.inkSoft).multilineTextAlignment(.center)
                .padding(.top, 14).padding(.horizontal, 10)
            Spacer()
            PillButton(title: "Allow microphone", icon: "mic") {
                Task {
                    _ = await LocalVoiceClient.requestPermissions()
                    LocationProvider.shared.requestPermission()   // for nearest-unit routing
                    step = 5
                }
            }
            Text("Used only while you're talking. Audio is never stored.")
                .font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute).padding(.top, 12).padding(.bottom, 44)
        }
    }

    // step 2, name only, one question per screen
    private var nameStep: some View {
        VStack(spacing: 16) {
            Spacer()
            question("First, what should\nI call you?")
            TextField("Your first name", text: $name)
                .font(ArtemisFont.sans(19)).multilineTextAlignment(.center)
                .submitLabel(.done)
                .padding(.vertical, 16).padding(.horizontal, 18)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(p.hairline, lineWidth: 1))
                .padding(.horizontal, 4)
            Spacer()
            PillButton(title: "Continue") { step = 3 }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .padding(.bottom, 30)
        }
    }

    // step 3, stage and weeks, on its own uncluttered screen
    private var stageStep: some View {
        VStack(spacing: 12) {
            question(name.isEmpty ? "Where are you\nright now?" : "\(name), where are\nyou right now?")
            ScrollView {
                VStack(spacing: 12) {
                    ChoiceCard(icon: "sparkle", label: "Trying to conceive", sub: "Hoping to get pregnant", selected: stage == .tryingToConceive) { stage = .tryingToConceive }
                    ChoiceCard(icon: "heart", label: "I'm pregnant", sub: "Expecting now", selected: stage == .pregnant) { stage = .pregnant }
                    if stage == .pregnant { revealBox { WeeksPicker(weeks: $weeks) } }
                    ChoiceCard(icon: "moon", label: "I've given birth", sub: "Postnatal", selected: stage == .postnatal) { stage = .postnatal }
                    if stage == .postnatal { revealBox { BirthDropdown(value: $birth) } }
                }
                .padding(.horizontal, 4).padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 4)
            PillButton(title: "Continue") { step = 4 }.padding(.bottom, 28)
        }
    }

    // step 3
    private var languageStep: some View {
        VStack(spacing: 0) {
            question("What language feels\nmost like home?")
            FlowLayout(spacing: 10) {
                ForEach(["English", "Romanian", "Spanish", "Polish", "Bengali", "Turkish",
                         "Gujarati", "Punjabi", "Urdu", "French", "Arabic"], id: \.self) { l in
                    Chip(label: l, selected: language == l) { language = l }
                }
            }
            Spacer()
            PillButton(title: "Continue") { step = 2 }.padding(.bottom, 30)
        }
    }

    // step 4
    private var riskProfile: some View {
        VStack(alignment: .leading, spacing: 14) {
            question("A few optional things\nthat help me look out for you")
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    field("Is this your first pregnancy?") {
                        HStack(spacing: 9) {
                            Chip(label: "Yes", selected: firstPregnancy) { firstPregnancy = true }
                            Chip(label: "No", selected: !firstPregnancy) { firstPregnancy = false }
                        }
                    }
                    field("Age") {
                        FlowLayout(spacing: 9) {
                            ForEach(["Under 25", "25-29", "30-34", "35-39", "40+"], id: \.self) { a in
                                Chip(label: a, selected: ageBand == a) { ageBand = a }
                            }
                        }
                    }
                    field("Your background (optional)") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("This helps me tailor risk awareness. Some groups face higher risks in UK maternity care, so I stay a little more vigilant. Never used to stereotype.")
                                .font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute)
                            FlowLayout(spacing: 9) {
                                ForEach(["Black", "Asian", "White", "Mixed", "Other", "Prefer not to say"], id: \.self) { e in
                                    Chip(label: e, selected: ethnicity == e || (e == "Prefer not to say" && ethnicity.isEmpty)) {
                                        ethnicity = (e == "Prefer not to say") ? "" : e
                                    }
                                }
                            }
                        }
                    }
                    field("Anything I should know? (optional)") {
                        FlowLayout(spacing: 9) {
                            ForEach(["High blood pressure", "Mental health history", "Diabetes"], id: \.self) { h in
                                Chip(label: h, selected: history.contains(h)) {
                                    if history.contains(h) { history.remove(h) } else { history.insert(h) }
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            PillButton(title: "Continue") { step = 6 }
            Button { step = 6 } label: {
                Text("Skip for now").font(ArtemisFont.sans(15, .semibold)).foregroundStyle(p.inkMute)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 4).padding(.bottom, 22)
        }
    }

    // step 5
    private var promise: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 7) {
                Icon(name: "shield", size: 16); Text("MY PROMISE TO YOU").font(ArtemisFont.sans(12.5, .bold)).tracking(1)
            }
            .foregroundStyle(p.sage600)
            Text("I never diagnose. I listen, check NHS guidance, and help you be heard. Your history stays on this phone, and your voice is only ever used to power our conversation.")
                .voiceStyle(25).multilineTextAlignment(.center).foregroundStyle(p.ink)
                .padding(.top, 16).padding(.horizontal, 4)
            Spacer()
            PillButton(title: "Start") { onDone(makeProfile()) }.padding(.bottom, 34)
        }
    }

    private func makeProfile() -> UserProfile {
        UserProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            stage: stage, weeks: weeks, birthTiming: stage == .postnatal ? birth : nil,
            language: language, firstPregnancy: firstPregnancy, ageBand: ageBand,
            hasBPHistory: history.contains("High blood pressure"),
            hasMentalHealthHistory: history.contains("Mental health history"),
            ethnicity: ethnicity,
            appearanceOverride: initial?.appearanceOverride ?? "System")
    }

    private func question(_ text: String) -> some View {
        Text(text).voiceStyle(28, weight: .semibold).multilineTextAlignment(.center)
            .foregroundStyle(p.ink).padding(.top, 14).padding(.bottom, 6)
    }
    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(ArtemisFont.sans(13.5, .bold)).foregroundStyle(p.inkSoft)
            content()
        }
    }
    private func revealBox<C: View>(@ViewBuilder content: () -> C) -> some View {
        content().padding(18)
            .frame(maxWidth: .infinity)
            .background(p.surface, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 4)
    }
}

// MARK: - Onboarding bits

struct ChoiceCard: View {
    let icon: String, label: String, sub: String, selected: Bool
    var action: () -> Void
    @Environment(\.palette) private var p
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Icon(name: icon, size: 22).foregroundStyle(selected ? .white : p.sage600)
                    .frame(width: 44, height: 44)
                    .background(selected ? AnyShapeStyle(p.sage600) : AnyShapeStyle(p.sage100), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(ArtemisFont.sans(17, .semibold)).foregroundStyle(p.ink)
                    Text(sub).font(ArtemisFont.sans(13.5)).foregroundStyle(p.inkMute)
                }
                Spacer()
                ZStack {
                    Circle().stroke(selected ? p.sage600 : p.hairline, lineWidth: 2).frame(width: 24, height: 24)
                    if selected { Circle().fill(p.sage600).frame(width: 24, height: 24); Icon(name: "check", size: 14).foregroundStyle(.white) }
                }
            }
            .padding(17)
            .background(selected ? p.sage100 : p.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? p.sage600 : .clear, lineWidth: 1.5))
            .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct Chip: View {
    let label: String, selected: Bool
    var action: () -> Void
    @Environment(\.palette) private var p
    var body: some View {
        Button(action: action) {
            Text(label).font(ArtemisFont.sans(15, .semibold))
                .foregroundStyle(selected ? .white : p.ink)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(selected ? AnyShapeStyle(p.sage600) : AnyShapeStyle(p.surface), in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : p.hairline, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

struct WeeksPicker: View {
    @Binding var weeks: Int
    @Environment(\.palette) private var p
    var body: some View {
        VStack(spacing: 6) {
            Text("HOW MANY WEEKS ARE YOU?").font(ArtemisFont.sans(12.5, .bold)).tracking(0.4).foregroundStyle(p.inkMute)
            HStack(spacing: 22) {
                roundButton("minus") { weeks = max(1, weeks - 1) }
                VStack(spacing: 2) {
                    Text("\(weeks)").voiceStyle(64, weight: .medium).foregroundStyle(p.sage700)
                    Text("weeks").font(ArtemisFont.sans(14, .semibold)).foregroundStyle(p.inkSoft)
                }
                .frame(minWidth: 110)
                roundButton("plus") { weeks = min(42, weeks + 1) }
            }
            Slider(value: Binding(get: { Double(weeks) }, set: { weeks = Int($0) }), in: 1...42, step: 1).tint(p.sage600)
            Text(trimesterLabel).font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.sage700)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(p.sage100, in: Capsule())
        }
    }
    private var trimesterLabel: String {
        switch weeks {
        case 40...: return "Full term"
        case 37...: return "Full term, nearly there"
        case 28...: return "Third trimester"
        case 13...: return "Second trimester"
        default: return "First trimester"
        }
    }
    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 22, weight: .semibold).foregroundStyle(p.sage700)
                .frame(width: 52, height: 52).background(p.sage100, in: Circle())
        }.buttonStyle(.plain)
    }
}

struct BirthDropdown: View {
    @Binding var value: String
    @State private var open = false
    @Environment(\.palette) private var p
    private let opts = ["This week", "1 week ago", "2 weeks ago", "3 weeks ago", "4 weeks ago", "6 weeks ago", "8+ weeks ago"]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("WHEN DID YOUR BABY ARRIVE?").font(ArtemisFont.sans(12.5, .bold)).tracking(0.4).foregroundStyle(p.inkMute)
            Button { withAnimation { open.toggle() } } label: {
                HStack {
                    Text(value).font(ArtemisFont.sans(16.5, .semibold)).foregroundStyle(p.ink)
                    Spacer()
                    Icon(name: "chevDown", size: 20).foregroundStyle(p.sage600).rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(p.sage50, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(open ? p.sage600 : p.hairline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            if open {
                VStack(spacing: 0) {
                    ForEach(opts, id: \.self) { o in
                        Button { value = o; withAnimation { open = false } } label: {
                            HStack {
                                Text(o).font(ArtemisFont.sans(16, o == value ? .semibold : .medium)).foregroundStyle(p.ink)
                                Spacer()
                                if o == value { Icon(name: "check", size: 17).foregroundStyle(p.sage600) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(o == value ? p.sage50 : .clear)
                        }
                        .buttonStyle(.plain)
                        if o != opts.last { Divider().overlay(p.hairline2) }
                    }
                }
                .background(p.surface, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: Color(hex: "3C3357").opacity(0.16), radius: 16, y: 6)
            }
        }
    }
}
