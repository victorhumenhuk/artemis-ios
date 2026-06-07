//  MemoryView.swift
//  "What Artemis remembers" — a small, private, readable view of the on-device
//  memory she carries across sessions. Deletable. Nothing leaves the phone.

import SwiftUI

struct MemoryView: View {
    var onClose: () -> Void
    @Environment(ConversationEngine.self) private var engine
    @Environment(\.palette) private var p
    @State private var confirmDelete = false

    private var memory: Store.Memory { engine.store.memory() }

    var body: some View {
        ArtemisSheet(maxHeightFraction: 0.92, onClose: onClose) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What Artemis remembers").voiceStyle(26, weight: .medium).foregroundStyle(p.ink)
                        Text("Kept only on your phone, so she can pick up where you left off.")
                            .font(ArtemisFont.sans(14)).foregroundStyle(p.inkSoft)
                    }

                    section("Your stage") {
                        Text(memory.stage + (memory.weeks > 0 ? ", \(memory.weeks) weeks" : ""))
                            .font(ArtemisFont.sans(15.5, .medium)).foregroundStyle(p.ink)
                    }

                    if !memory.recurringThemes.isEmpty {
                        section("Recurring themes") {
                            FlowLayout(spacing: 8) {
                                ForEach(memory.recurringThemes, id: \.0) { t in
                                    HStack(spacing: 6) {
                                        Text(t.0.capitalized).font(ArtemisFont.sans(14, .semibold))
                                        Text("×\(t.1)").font(ArtemisFont.sans(12, .semibold)).foregroundStyle(p.inkMute)
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(p.sage100, in: Capsule())
                                }
                            }
                        }
                    }
                    if !memory.concerns.isEmpty {
                        section("Worries you've shared") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(memory.concerns, id: \.self) { c in
                                    Text("• " + c).font(ArtemisFont.sans(15)).foregroundStyle(p.ink)
                                }
                            }
                        }
                    }
                    if !memory.watching.isEmpty {
                        section("Worth keeping an eye on") {
                            Text(memory.watching.joined(separator: ", "))
                                .font(ArtemisFont.sans(15, .medium)).foregroundStyle(p.ink)
                        }
                    }

                    Button(role: .destructive) { confirmDelete = true } label: {
                        HStack(spacing: 8) { Icon(name: "close", size: 16); Text("Delete what Artemis remembers").font(ArtemisFont.sans(15.5, .semibold)) }
                            .foregroundStyle(p.emergency)
                            .frame(maxWidth: .infinity).frame(height: 50)
                            .background(p.emergencyBg, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        Icon(name: "lock", size: 13)
                        Text("Stored only on your phone. Never uploaded.")
                    }
                    .font(ArtemisFont.sans(12)).foregroundStyle(p.inkMute).frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 26)
            }
            .scrollIndicators(.hidden)
        }
        .confirmationDialog("Delete everything Artemis remembers?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { engine.eraseEverything(); onClose() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This clears your check-ins, readings and chat history from this phone. It cannot be undone.")
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            OverlineLabel(text: title)
            Card { content().frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
