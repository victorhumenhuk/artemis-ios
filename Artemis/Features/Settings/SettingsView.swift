//  SettingsView.swift
//  Profile, the two session toggles (Listen on open, Start in silent mode),
//  language, and the on-device data controls (Export, Delete everything).
//  Built to the Settings design.

import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var listenOnOpen = true
    @State private var startSilent = false
    @State private var showDeleteConfirm = false
    @State private var exportItem: ExportText?
    @State private var showDebug = false
    @State private var showConsole = false
    @State private var showMemory = false
    @State private var showNameEdit = false
    @State private var editName = ""
    @State private var locStatus = ""
    @State private var locArea: String?
    @State private var locAuthorized = false

    // Reading profileRev ties this fetch to the observable trigger, so the view
    // re-renders the moment weeks/language/etc change.
    private var profile: UserProfile? { _ = engine.profileRev; return engine.store.profile() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                profileCard
                group("Your journey") {
                    Button { editName = profile?.name ?? ""; showNameEdit = true } label: {
                        SettingsRow(icon: "heart", title: "Your name", sub: "Artemis calls you by this") {
                            HStack(spacing: 4) {
                                Text((profile?.name).flatMap { $0.isEmpty ? nil : $0 } ?? "Add").foregroundStyle(p.inkMute)
                                Icon(name: "chevRight", size: 15).foregroundStyle(p.inkMute)
                            }.font(ArtemisFont.sans(15))
                        }
                    }.buttonStyle(.plain)
                    Divider().overlay(p.hairline2)
                    SettingsRow(icon: "sparkle", title: "Stage", sub: "The conversation adapts to where you are") {
                        Menu {
                            ForEach(Stage.allCases, id: \.self) { s in
                                Button(s.label) { updateProfileAndReapply { $0.stage = s.rawValue } }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(profile?.stageEnum.label ?? "Pregnant").foregroundStyle(p.inkMute)
                                Icon(name: "chevDown", size: 15).foregroundStyle(p.inkMute)
                            }.font(ArtemisFont.sans(15))
                        }
                    }
                    if profile?.stageEnum == .pregnant {
                        Divider().overlay(p.hairline2)
                        SettingsRow(icon: "chart", title: "Weeks pregnant", sub: "Used to tailor guidance") {
                            Menu {
                                ForEach(Array(stride(from: 4, through: 42, by: 1)), id: \.self) { w in
                                    Button("\(w) weeks") { updateProfileAndReapply { $0.weeks = w } }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text("\(profile?.weeks ?? 0) weeks").foregroundStyle(p.inkMute)
                                    Icon(name: "chevDown", size: 15).foregroundStyle(p.inkMute)
                                }.font(ArtemisFont.sans(15))
                            }
                        }
                    }
                    Divider().overlay(p.hairline2)
                    Button { showMemory = true } label: {
                        SettingsRow(icon: "sparkle", title: "What Artemis remembers", sub: "On your phone, readable and deletable") {
                            Icon(name: "chevRight", size: 18).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                    Divider().overlay(p.hairline2)
                    Button { engine.restartOnboarding() } label: {
                        SettingsRow(icon: "sparkle", title: "Edit your details", sub: "Redo the welcome to change name, stage, weeks, language and background") {
                            Icon(name: "chevRight", size: 18).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                }
                group("Location") {
                    Button {
                        if locAuthorized == false, let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        } else {
                            LocationProvider.shared.requestPermission()
                            Task { _ = await LocationProvider.shared.currentCoarseLocation(); refreshLocation() }
                        }
                    } label: {
                        SettingsRow(icon: "location", title: "Location", sub: locArea ?? "Find your nearest NHS maternity unit") {
                            Text(locStatus.isEmpty ? "Tap to enable" : locStatus)
                                .font(ArtemisFont.sans(14)).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                }
                group("Voice & sound") {
                    SettingsRow(icon: "mic", title: "Listen on open", sub: "Artemis is ready the moment you open") {
                        Toggle("", isOn: $listenOnOpen).labelsHidden().tint(p.sage600)
                            .onChange(of: listenOnOpen) { _, v in updateProfile { $0.listenOnOpen = v } }
                    }
                    Divider().overlay(p.hairline2)
                    SettingsRow(icon: "micOff", title: "Start in silent mode", sub: "Text-only replies, mic muted") {
                        Toggle("", isOn: $startSilent).labelsHidden().tint(p.sage600)
                            .onChange(of: startSilent) { _, v in
                                updateProfile { $0.startInSilentMode = v }
                                engine.setSilentLocked(v)
                            }
                    }
                }
                group("Developer") {
                    SettingsRow(icon: "wave", title: "Connection overlay", sub: "Live realtime status on the home screen") {
                        Toggle(isOn: Binding(
                            get: { DebugFlags.shared.showConnectionOverlay },
                            set: { DebugFlags.shared.showConnectionOverlay = $0 }
                        )) {}.labelsHidden().tint(p.sage600)
                    }
                    Divider().overlay(p.hairline2)
                    Button { showConsole = true } label: {
                        SettingsRow(icon: "chart", title: "Event console", sub: "Live raw realtime events, the model proof") {
                            Icon(name: "chevRight", size: 18).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                }
                group("Language") {
                    SettingsRow(icon: "globe", title: "Language", sub: "Artemis replies in your language") {
                        Menu {
                            ForEach(["English", "Romanian", "Spanish", "Polish", "Bengali", "Turkish",
                                     "Gujarati", "Punjabi", "Urdu", "French", "Arabic"], id: \.self) { l in
                                Button(l) { updateProfileAndReapply { $0.language = l } }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(profile?.language ?? "English").foregroundStyle(p.inkMute)
                                Icon(name: "chevDown", size: 15).foregroundStyle(p.inkMute)
                            }.font(ArtemisFont.sans(15))
                        }
                    }
                }
                group("Appearance") {
                    SettingsRow(icon: "sparkle", title: "Display mode", sub: "Follows your phone, or choose your own") {
                        Menu {
                            ForEach(["System", "Light", "Dark"], id: \.self) { m in
                                Button(m) { updateProfile { $0.appearanceOverride = m } }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(profile?.appearanceOverride ?? "System").foregroundStyle(p.inkMute)
                                Icon(name: "chevDown", size: 15).foregroundStyle(p.inkMute)
                            }.font(ArtemisFont.sans(15))
                        }
                    }
                }
                group("Your data") {
                    SettingsRow(icon: "lock", title: "Stored on this phone only", sub: "Your history and memory stay on your device") {
                        Icon(name: "check", size: 20).foregroundStyle(p.routine)
                    }
                    Divider().overlay(p.hairline2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Voice and replies use OpenAI").font(ArtemisFont.sans(16, .medium)).foregroundStyle(p.ink)
                        Text("To power her voice, what you say and type is sent to OpenAI for processing. It is not used to train models.")
                            .font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 13)
                    Divider().overlay(p.hairline2)
                    Button { exportItem = ExportText(text: engine.store.exportCheckinsText()) } label: {
                        SettingsRow(icon: "chart", title: "Export my check-in log") {
                            Icon(name: "chevRight", size: 18).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                    Divider().overlay(p.hairline2)
                    Button { showDeleteConfirm = true } label: {
                        SettingsRow(icon: "close", title: "Delete everything") {
                            Icon(name: "chevRight", size: 18).foregroundStyle(p.inkMute)
                        }
                    }.buttonStyle(.plain)
                }
                promiseCard
                Text("Artemis v1.0 · Health & Fitness")
                    .font(ArtemisFont.sans(12.5)).foregroundStyle(p.inkMute)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3) { showDebug = true }   // hidden diagnostics
            }
            .padding(.horizontal, 18).padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .overlay {
            if showDebug { DebugView { showDebug = false } }
            if showConsole { RawEventConsoleView { showConsole = false } }
            if showMemory { MemoryView { showMemory = false } }
        }
        .onAppear {
            listenOnOpen = profile?.listenOnOpen ?? true
            startSilent = profile?.startInSilentMode ?? false
            if ProcessInfo.processInfo.environment["ARTEMIS_OPEN_DEBUG"] == "1" { showDebug = true }
            if ProcessInfo.processInfo.environment["ARTEMIS_OPEN_CONSOLE"] == "1" { showConsole = true }
            if ProcessInfo.processInfo.environment["ARTEMIS_OPEN_MEMORY"] == "1" { showMemory = true }
            refreshLocation()
        }
        .alert("Your name", isPresented: $showNameEdit) {
            TextField("First name", text: $editName)
            Button("Save") { updateProfileAndReapply { $0.name = editName.trimmingCharacters(in: .whitespacesAndNewlines) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Artemis will use this to address you.")
        }
        .confirmationDialog("Delete everything?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { engine.eraseEverything(); engine.view = .home }
            Button("Keep my data", role: .cancel) {}
        } message: {
            Text("This removes every check-in, symptom, reading and message from this phone. It cannot be undone.")
        }
        .sheet(item: $exportItem) { item in
            ActivityView(text: item.text)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                GlassIcon(icon: "chevDown") { engine.view = .home }
                Spacer()
                Color.clear.frame(width: 42, height: 42)
            }
            Text("Settings").voiceStyle(32, weight: .medium).foregroundStyle(p.ink).padding(.top, 4)
        }
        .padding(.top, 6)
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            Circle().fill(p.orbGradient()).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.summaryLine ?? "Welcome").font(ArtemisFont.sans(17.5, .bold)).foregroundStyle(p.ink)
                Text("\(profile?.firstPregnancy == false ? "Not first baby" : "First baby") · \(profile?.language ?? "English")")
                    .font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
            }
            Spacer()
        }
        .padding(18)
        .background(p.surface, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 3)
    }

    private var promiseCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Icon(name: "shield", size: 18); Text("The promise").font(ArtemisFont.sans(14, .bold))
            }
            .foregroundStyle(p.sage700)
            Text("Artemis never diagnoses. She listens, checks NHS guidance, and helps you be heard. Your check-ins, history and anything you type stay on this phone. When you talk to her, your voice is sent securely to power the reply and is never stored.")
                .voiceStyle(16.5).foregroundStyle(p.ink)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.sage50, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(p.hairline2, lineWidth: 1))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OverlineLabel(text: title).padding(.horizontal, 6)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 18)
                .background(p.surface, in: RoundedRectangle(cornerRadius: 22))
                .shadow(color: Color(hex: "3C3357").opacity(0.08), radius: 12, y: 3)
        }
    }

    private func refreshLocation() {
        let lp = LocationProvider.shared
        locAuthorized = lp.isAuthorized
        locStatus = lp.statusText
        locArea = lp.areaText
    }

    private func updateProfile(_ change: @escaping (UserProfile) -> Void) {
        engine.applyProfileChange(reconnect: false, change)   // UI refresh only, no session churn
    }

    /// Save a profile change AND re-apply it to the live realtime session and the
    /// whole UI. Single source of truth: the stored profile, observed via profileRev.
    private func updateProfileAndReapply(_ change: @escaping (UserProfile) -> Void) {
        engine.applyProfileChange(reconnect: true, change)
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var sub: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.palette) private var p
    var body: some View {
        HStack(spacing: 13) {
            Icon(name: icon, size: 19).foregroundStyle(p.sage700)
                .frame(width: 34, height: 34).background(p.sage50, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(ArtemisFont.sans(16, .medium)).foregroundStyle(p.ink)
                if let sub { Text(sub).font(ArtemisFont.sans(13)).foregroundStyle(p.inkMute) }
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 13)
    }
}

struct ExportText: Identifiable { let id = UUID(); let text: String }

struct ActivityView: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
