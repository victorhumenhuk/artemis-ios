//  ConversationView.swift
//  The home screen IS the conversation. Artemis is already listening; a text box
//  is always present so she can type when she cannot talk. Built to artemis-home.jsx.

import SwiftUI
import UIKit

struct ConversationView: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var draft = ""
    @State private var showHistory = false
    @State private var menuMessage: ChatMessage?

    // image attach
    @State private var attachedImage: UIImage?
    @State private var showAttachMenu = false
    @State private var picker: PickerSource?
    @State private var fullScreenImage: UIImage?

    enum PickerSource: Identifiable { case camera, library; var id: Int { hashValue } }

    // The thread is restored on launch, but the screen only expands into the
    // conversation once she engages this session, so opening the app is a calm
    // orb, not a wall of past messages.
    private var active: Bool {
        engine.sessionEngaged || !engine.interim.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !active { orbZone }     // hero only at rest; when active the orb lives in the top bar
            if active { transcript }
            // No Stop button: the mic IS the single control (toggles + interrupts).
            // Tracking chips (Mood, Symptoms, BP, Kicks) live above the bar ALWAYS.
            SuggestionChipsBar().padding(.bottom, 6)
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.45) : .spring(response: 0.5, dampingFraction: 0.85), value: active)
        .overlay(alignment: .topTrailing) {
            if DebugFlags.shared.showConnectionOverlay {
                ConnectionOverlay().padding(.top, 104).padding(.trailing, 12)
            }
        }
        .overlay {
            if let chip = engine.activeChip {
                ChipSheetHost(kind: chip)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(3)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: engine.activeChip?.id)
        .confirmationDialog("Add a photo", isPresented: $showAttachMenu, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { picker = .camera }
            }
            Button("Choose from Library") { picker = .library }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $picker) { src in
            ImagePicker(source: src == .camera ? .camera : .photoLibrary) { img in attachedImage = img }
                .ignoresSafeArea()
        }
        .sheet(item: $menuMessage) { msg in
            MessageMenuSheet(message: msg) { action in
                menuMessage = nil
                engine.followUp(action, on: msg)
            } onClose: { menuMessage = nil }
                .presentationDetents([.height(320)])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: Binding(get: { fullScreenImage.map { ImageBox(image: $0) } }, set: { fullScreenImage = $0?.image })) { box in
            FullImageView(image: box.image) { fullScreenImage = nil }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIcon(icon: "chart") { engine.view = .history }
            Spacer(minLength: 6)
            // When the conversation is going, the orb and status sit inline at
            // button height, so the top bar stays small and the chat fills the screen.
            if active {
                Button { engine.orbTapped() } label: {
                    HStack(spacing: 7) {
                        Orb(state: engine.state, size: 34)
                        if engine.statusIsLive { LiveDots(color: compactStatusColor) }
                        Text(compactStatus)
                            .font(ArtemisFont.sans(12.5, .semibold)).tracking(0.4)
                            .foregroundStyle(compactStatusColor)
                            .contentTransition(.opacity)
                            .animation(.easeInOut(duration: 0.35), value: compactStatus)
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
            Spacer(minLength: 6)
            GlassIcon(icon: "gear") { engine.view = .settings }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, active ? 6 : 0)
    }

    private var compactStatus: String {
        switch engine.voiceMode {
        case .connecting: return "Connecting"
        case .offline: return "Tap to reconnect"
        case .realtime:
            if engine.isSilent { return "Silent" }
            switch engine.state {
            case .responding: return L("speaking", engine.uiLanguage)
            case .thinking: return "CHECKING"
            // Reflect the ACTUAL mic: only say LISTENING when the mic is hot, so the
            // top stays in sync with the wave when she taps to stop/start.
            case .listening: return engine.micHot ? L("listening", engine.uiLanguage) : "Tap to speak"
            default: return engine.micHot ? L("listening", engine.uiLanguage) : "Tap to speak"
            }
        case .failed: return "Tap to retry"
        }
    }
    private var compactStatusColor: Color {
        switch engine.state { case .responding: return p.clay; case .thinking, .listening: return p.sage600; default: return p.inkMute }
    }

    // MARK: orb

    private var orbZone: some View {
        VStack(spacing: 16) {
            // Once the conversation is going, the orb shrinks to a small header
            // so the chat fills the screen and scrolls like a normal chat.
            Orb(state: engine.state, size: active ? 58 : 234)
                .onTapGesture { engine.orbTapped() }
                .padding(.top, active ? 2 : 0)
                // Fluid resize + state easing (Headspace-grade calm motion).
                .animation(.spring(response: 0.55, dampingFraction: 0.82), value: active)
                .animation(.smooth(duration: 0.45), value: engine.state)
            if !active {
                VStack(spacing: 16) {
                    Text(L("feeling", engine.uiLanguage))
                        .multilineTextAlignment(.center)
                        .voiceStyle(27, weight: .medium)
                        .foregroundStyle(p.ink)
                    StatusLineView()
                }
                .padding(.horizontal, 40)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: active ? 70 : .infinity)
    }

    // MARK: transcript

    // While she is in a live exchange we focus on the latest turns; earlier
    // messages collapse behind a small "show earlier" control.
    private var visibleMessages: [ChatMessage] {
        // Keep the recent conversation visible; only collapse for long threads.
        guard !showHistory, engine.messages.count > 8 else { return engine.messages }
        return Array(engine.messages.suffix(6))
    }

    // A soft, beautiful bubble entrance (blur + lift + settle). Extracted as a
    // static so the type-checker stays fast.
    private static let bubbleTransition: AnyTransition = .asymmetric(
        insertion: AnyTransition.move(edge: .bottom)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.94, anchor: .bottom))
            .combined(with: .modifier(active: BubbleBlur(radius: 2.5), identity: BubbleBlur(radius: 0))),
        removal: AnyTransition.opacity.combined(with: .scale(scale: 0.98)))

    private var transcript: some View {
        VStack(spacing: 0) {
            if !showHistory, engine.messages.count > visibleMessages.count {
                Button { withAnimation { showHistory = true } } label: {
                    HStack(spacing: 5) {
                        Icon(name: "chevUp", size: 12)
                        Text("Show earlier messages").font(ArtemisFont.sans(12.5, .semibold))
                    }
                    .foregroundStyle(p.sage600)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(p.sage50, in: Capsule())
                }
                .buttonStyle(.plain).padding(.top, 4).padding(.bottom, 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(visibleMessages, id: \.id) { msg in
                            BubbleView(message: msg,
                                       canHear: engine.isSilent && msg.role == .artemis && msg.id == engine.messages.last?.id,
                                       hasVerdict: msg.role == .artemis && engine.verdict != nil && msg.id == engine.messages.last?.id,
                                       onTapVerdict: { engine.reopenVerdict() },
                                       onShowImage: { fullScreenImage = $0 },
                                       onMenu: { menuMessage = msg },
                                       onAction: { engine.performAction($0) })
                                .id(msg.id)
                                .transition(reduceMotion ? .opacity : Self.bubbleTransition)
                        }
                        if !engine.interim.isEmpty {
                            InterimBubble(text: engine.interim).id("interim")   // what she is saying, live
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.52, dampingFraction: 0.8), value: visibleMessages.count)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: engine.messages.count) { _, _ in
                    showHistory = false   // a new turn re-focuses on the latest
                    withAnimation { proxy.scrollTo(engine.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: engine.interim) { _, _ in
                    withAnimation { proxy.scrollTo("interim", anchor: .bottom) }
                }
                .onChange(of: engine.messages.last?.text) { _, _ in
                    proxy.scrollTo(engine.messages.last?.id, anchor: .bottom)   // pin while streaming
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: input bar

    private var inputBar: some View {
        VStack(spacing: 10) {
            if let img = attachedImage {
                HStack(spacing: 10) {
                    Image(uiImage: img).resizable().scaledToFill()
                        .frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .topTrailing) {
                            Button { attachedImage = nil } label: {
                                Icon(name: "close", size: 11).foregroundStyle(.white)
                                    .frame(width: 22, height: 22).background(p.ink, in: Circle())
                                    .overlay(Circle().stroke(p.bg, lineWidth: 2))
                            }.buttonStyle(.plain).offset(x: 7, y: -7)
                        }
                    Text("Photo ready to send").font(ArtemisFont.sans(13, .semibold)).foregroundStyle(p.inkSoft)
                    Spacer()
                }
                .padding(.leading, 6)
                .transition(.opacity)
            }
            HStack(spacing: 4) {
                // One attach button, the camera. Library is reachable from the menu.
                attachButton(icon: "camera") { showAttachMenu = true }

                TextField(L("placeholder", engine.uiLanguage), text: $draft, axis: .vertical)
                    .font(ArtemisFont.sans(16.5))
                    .foregroundStyle(p.ink)
                    .focused($inputFocused)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onChange(of: inputFocused) { _, focused in
                        // Tapping into the text box pauses the mic so it never listens
                        // while she types; leaving it (without sending) resumes listening.
                        if focused { engine.enterSilentTyping() }
                        else { engine.exitSilentTyping() }
                    }
                    .onSubmit(send)

                if !draft.trimmingCharacters(in: .whitespaces).isEmpty || attachedImage != nil {
                    Button(action: send) {
                        Icon(name: "arrowUp", size: 20, weight: .semibold)
                            .foregroundStyle(p.btnPrimaryFg)
                            .frame(width: 40, height: 40)
                            .background(p.btnPrimaryBg, in: Circle())
                    }
                    .buttonStyle(PressButtonStyle())
                } else {
                    // The single voice control: an always-present waveform. It animates
                    // only when the mic is on, and is flat and even when off, a clear
                    // sign it is not listening. Tapping toggles, or interrupts Artemis.
                    Button { engine.micButtonTapped() } label: {
                        MicWaveform(color: engine.micHot ? p.btnPrimaryFg : p.sage600, active: engine.micHot)
                            .frame(width: 22, height: 18)
                            .frame(width: 40, height: 40)
                            .background(engine.micHot ? AnyShapeStyle(p.btnPrimaryBg) : AnyShapeStyle(p.sage100), in: Circle())
                    }
                    .buttonStyle(PressButtonStyle())
                    .accessibilityLabel(engine.micHot ? "Stop listening" : "Start listening")
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 7)
            .background(p.surface, in: Capsule())
            .overlay(Capsule().stroke(p.hairline, lineWidth: 1))
            .shadow(color: Color(hex: "3C3357").opacity(0.16), radius: 16, y: 6)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: attachedImage != nil)
    }

    private func attachButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(name: icon, size: 20).foregroundStyle(p.inkMute).frame(width: 40, height: 40)
        }
        .buttonStyle(PressButtonStyle())
    }

    private func send() {
        let text = draft
        let img = attachedImage
        draft = ""
        attachedImage = nil
        if let img {
            guard let data = img.jpegData(compressionQuality: 0.7) else {
                engine.appendNotice("That photo could not be attached. Try another image.")
                return
            }
            engine.send(text, imageData: data)
        } else {
            engine.send(text, imageData: nil)
        }
    }
}

private struct ImageBox: Identifiable { let id = UUID(); let image: UIImage }

// MARK: - Status line

struct StatusLineView: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p

    private var color: Color {
        switch engine.voiceMode {
        case .failed: return p.urgent
        case .offline, .connecting: return p.inkMute
        case .realtime:
            switch engine.state {
            case .responding: return p.clay
            case .thinking, .listening: return p.sage600
            default: return p.inkMute
            }
        }
    }

    var body: some View {
        Button {
            if engine.canRetryVoice { engine.retryConnection() }
        } label: {
            HStack(spacing: 8) {
                if engine.statusIsLive { LiveDots(color: color) }
                Text(engine.statusIsLive ? engine.statusLine.uppercased() : engine.statusLine)
                    .font(ArtemisFont.sans(13, .semibold))
                    .tracking(0.3)
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
            }
            .frame(minHeight: 22)
            .padding(.horizontal, 24)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(engine.canRetryVoice)
    }
}

struct LiveDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion {
            HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: 4, height: 4).opacity(0.7) } }
        } else {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        let phase = sin((t * 1.4) - Double(i) * 0.5)
                        Circle().fill(color)
                            .frame(width: 4, height: 4)
                            .scaleEffect(0.6 + 0.4 * (0.5 + 0.5 * phase))
                            .opacity(0.4 + 0.6 * (0.5 + 0.5 * phase))
                    }
                }
            }
        }
    }
}

/// Animated waveform shown inside the mic button while she is being listened to.
struct MicWaveform: View {
    var color: Color = .white
    var active: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bars = 5
    var body: some View {
        if !active || reduceMotion {
            // Flat and even: a clear sign the mic is not listening.
            HStack(spacing: 2.5) {
                ForEach(0..<bars, id: \.self) { _ in
                    Capsule().fill(color.opacity(active ? 1 : 0.7)).frame(width: 2.5, height: 6)
                }
            }
        } else {
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<bars, id: \.self) { i in
                        // Each bar gets its own frequency + a slow amplitude swell, so the
                        // waveform breathes like real listening instead of a flat sine.
                        let freq = 3.6 + Double(i) * 0.62
                        let swell = 0.78 + 0.22 * sin(t * 1.3 + Double(i))
                        let phase = sin((t * freq) - Double(i) * 0.7)
                        Capsule().fill(color)
                            .frame(width: 2.5, height: 4 + 15 * swell * (0.5 + 0.5 * phase))
                    }
                }
            }
        }
    }
}

// MARK: - Bubbles

struct BubbleView: View {
    let message: ChatMessage
    var canHear: Bool
    var hasVerdict: Bool = false
    var onTapVerdict: () -> Void = {}
    var onShowImage: (UIImage) -> Void = { _ in }
    var onMenu: () -> Void = {}
    var onAction: (MessageAction) -> Void = { _ in }
    @Environment(\.palette) private var p
    @State private var pressed = false
    private var mine: Bool { message.role == .her }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if mine { Spacer(minLength: 40) }
            if !mine { ArtemisMark(size: 30).padding(.top, 2) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if let data = message.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 180, height: 180).clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: Color(hex: "3C3357").opacity(0.16), radius: 8, y: 3)
                        .onTapGesture { onShowImage(ui) }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(mine ? ArtemisFont.sans(15.5, .medium) : ArtemisFont.sans(16, .regular))
                        .lineSpacing(2)
                        .foregroundStyle(mine ? p.bubbleMeFg : p.ink)
                        .padding(.horizontal, mine ? 14 : 15)
                        .padding(.vertical, mine ? 10 : 11)
                        .background(mine ? AnyShapeStyle(p.bubbleMeBg) : AnyShapeStyle(p.surface),
                                    in: BubbleShape(mine: mine))
                        .shadow(color: mine ? Color(hex: "6C5796").opacity(0.24) : Color(hex: "3C3357").opacity(0.08),
                                radius: 10, y: 3)
                        .scaleEffect(pressed ? 0.98 : 1)
                        .onTapGesture { if hasVerdict { onTapVerdict() } else if !mine { onMenu() } }
                        .onLongPressGesture(minimumDuration: 0.35) { if !mine { onMenu() } }
                }
                if hasVerdict {
                    Button(action: onTapVerdict) {
                        HStack(spacing: 5) { Icon(name: "shield", size: 13); Text("View your card").font(ArtemisFont.sans(12.5, .semibold)) }
                            .foregroundStyle(p.sage600)
                    }.buttonStyle(.plain)
                } else if canHear {
                    Button {} label: {
                        HStack(spacing: 5) { Icon(name: "ear", size: 15); Text("Tap to hear").font(ArtemisFont.sans(12.5, .semibold)) }
                            .foregroundStyle(p.sage600)
                    }.buttonStyle(.plain)
                }
                // Action chips: every assistant message ends in a tappable next step.
                if !mine, !message.actions.isEmpty {
                    FlowLayout(spacing: 7) {
                        ForEach(message.actions) { a in
                            Button { onAction(a) } label: { actionChip(a) }
                                .buttonStyle(PressButtonStyle())
                        }
                    }
                    .padding(.top, 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                // NHS grounding, visible right under a clinical reply (not just on the card).
                if !mine, let title = message.nhsTitle,
                   let url = URL(string: message.nhsURL ?? "") ?? URL(string: "https://www.nhs.uk") {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text("NHS").font(ArtemisFont.sans(9, .heavy)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(hex: "005EB8"), in: Capsule())
                            Text(title).font(ArtemisFont.sans(12, .medium)).foregroundStyle(p.inkSoft).lineLimit(1)
                            Icon(name: "link", size: 11).foregroundStyle(p.inkMute)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(p.surface, in: Capsule())
                        .overlay(Capsule().stroke(p.lilac300, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .leading)))
                }
                Text(message.date, format: .dateTime.hour().minute())
                    .font(ArtemisFont.sans(10.5)).foregroundStyle(p.inkMute)
                    .padding(.horizontal, 2)
            }
            if !mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        // Chips and the NHS source settle in gently when they attach to a reply.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: message.actions.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: message.nhsTitle)
    }

    private func actionChip(_ a: MessageAction) -> some View {
        HStack(spacing: 5) {
            Icon(name: a.icon, size: 12).foregroundStyle(a.urgent ? .white : p.sage700)
            Text(a.label).font(ArtemisFont.sans(12.5, .semibold)).foregroundStyle(a.urgent ? .white : p.ink)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(a.urgent ? AnyShapeStyle(p.emergency) : AnyShapeStyle(p.surface), in: Capsule())
        .overlay(Capsule().stroke(a.urgent ? .clear : p.hairline, lineWidth: 1))
    }
}

// MARK: - Message follow-up menu

struct MessageMenuSheet: View {
    let message: ChatMessage
    var onAction: (ConversationEngine.FollowUp) -> Void
    var onClose: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.text)
                .font(ArtemisFont.sans(15, .regular)).foregroundStyle(p.inkSoft)
                .lineLimit(2).padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 8)
            row("sparkle", "Explain this better") { onAction(.explain) }
            Divider().overlay(p.hairline2).padding(.leading, 56)
            row("shield", "What should I do") { onAction(.whatToDo) }
            Divider().overlay(p.hairline2).padding(.leading, 56)
            row("heart", "Say it more simply") { onAction(.simpler) }
            Divider().overlay(p.hairline2).padding(.leading, 56)
            row("chart", "Copy") {
                UIPasteboard.general.string = message.text
                Haptics.tap(); onClose()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.bg)
    }

    private func row(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Icon(name: icon, size: 18).foregroundStyle(p.sage700)
                    .frame(width: 34, height: 34).background(p.sage50, in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(ArtemisFont.sans(16.5, .medium)).foregroundStyle(p.ink)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BubbleShape: Shape {
    let mine: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 20, s: CGFloat = 6
        return Path(roundedRect: rect, cornerRadii: mine
            ? .init(topLeading: r, bottomLeading: r, bottomTrailing: s, topTrailing: r)
            : .init(topLeading: s, bottomLeading: r, bottomTrailing: r, topTrailing: r))
    }
}

struct InterimBubble: View {
    let text: String
    @Environment(\.palette) private var p
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var cursorOn = true
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            // The cursor is a SEPARATE element so its pulse never crossfades the text
            // (which caused the caption to ghost/double). The text updates instantly.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text)
                    .font(ArtemisFont.sans(16))
                    .foregroundStyle(p.lilac700)
                    .contentTransition(.identity)
                    .animation(nil, value: text)
                Text("|")
                    .font(ArtemisFont.sans(16))
                    .foregroundStyle(p.lilac700)
                    .opacity(cursorOn ? 1 : 0.12)
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(p.lilac100, in: BubbleShape(mine: true))
            .overlay(BubbleShape(mine: true).stroke(p.lilac300, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : 10)
        .blur(radius: entered ? 0 : 4)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.82)) { entered = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { cursorOn = false }
        }
        .onDisappear { cursorOn = true }   // stop the repeat-forever pulse when removed
    }
}

// MARK: - Image picker + full-screen viewer

struct ImagePicker: UIViewControllerRepresentable {
    let source: UIImagePickerController.SourceType
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = UIImagePickerController.isSourceTypeAvailable(source) ? source : .photoLibrary
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct FullImageView: View {
    let image: UIImage
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Icon(name: "close", size: 18).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                    }.padding()
                }
                Spacer()
            }
        }
        .onTapGesture(perform: onClose)
    }
}

/// Blur component for the bubble entrance transition (blur → crisp as it settles).
private struct BubbleBlur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
