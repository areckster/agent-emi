//
//  SettingsView.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//


import SwiftUI
import AppKit

private enum SettingsTab: String, CaseIterable, Identifiable { case general, model, profile; var id: String { rawValue } }

struct SettingsView: View {
    @EnvironmentObject var prefs: AppPrefs
    @EnvironmentObject var store: ChatStore
    @State private var showConfirmClear = false
    @State private var tab: SettingsTab = .general

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(gradient: Gradient(colors: [LG.backgroundGradientStart, LG.backgroundGradientEnd]), startPoint: .top, endPoint: .bottom)
                .opacity(prefs.chatBackgroundOpacity)
                .ignoresSafeArea()

            // Drag handle for settings window with hidden title bar
            WindowDragHandle()
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.clear)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 14) {
                GlassCard(cornerRadius: 14, contentPadding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) {
                    HStack {
                        Text("Preferences").font(.title3.weight(.semibold))
                        Spacer()
                        Picker("", selection: $tab) {
                            Label("General", systemImage: "gearshape").tag(SettingsTab.general)
                            Label("Model", systemImage: "brain.head.profile").tag(SettingsTab.model)
                            Label("Profile", systemImage: "person.crop.circle").tag(SettingsTab.profile)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 360)
                    }
                }

                GlassCard(cornerRadius: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        switch tab {
                        case .general: general
                        case .model: model
                        case .profile: profile
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 620, height: 420)
        .tint(LG.accent)
        .onDisappear { prefs.save() }
        // Ensure the settings window is also translucent like the main window
        .background(TransparentWindowConfigurator())
    }

    private var general: some View {
        Form {
            Picker("Reasoning effort", selection: $prefs.reasoningEffort) {
                ForEach(ReasoningEffort.allCases) { e in Text(e.rawValue.capitalized).tag(e) }
            }
            HStack(spacing: 8) {
                Text("Chat background opacity")
                Slider(value: $prefs.chatBackgroundOpacity, in: 0.6...1.0, step: 0.01)
                Text("\(Int(prefs.chatBackgroundOpacity * 100))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Toggle("Animate text reveal on new answers", isOn: $prefs.progressiveRevealOnAnswer)
            Toggle("Show detailed model errors", isOn: $prefs.showDetailedErrors)

            Section(header: Text("Danger Zone")) {
                Button(role: .destructive) {
                    showConfirmClear = true
                } label: {
                    Label("Clear All Chats", systemImage: "trash")
                }
                .alert("Clear all chats?", isPresented: $showConfirmClear) {
                    Button("Cancel", role: .cancel) { showConfirmClear = false }
                    Button("Clear", role: .destructive) {
                        store.clearAll()
                    }
                } message: {
                    Text("This removes all chat history and starts a new empty chat. This cannot be undone.")
                }
            }
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MLX In‑Process Model").font(.headline)
            // Model path and theme removed (bundled models, single theme)
            HStack(spacing: 8) {
                Text("Max new tokens").frame(width: 140, alignment: .leading)
                Slider(value: Binding(get: { Double(prefs.maxTokens) }, set: { prefs.maxTokens = Int($0) }), in: 256...65536, step: 256)
                Text("\(prefs.maxTokens)").monospacedDigit()
            }
        }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("User Profile").font(.headline)
            HStack(spacing: 8) {
                Text("Preferred name").frame(width: 140, alignment: .leading)
                TextField("Alex", text: $prefs.preferredName).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("About you").frame(width: 140, alignment: .leading)
                TextEditor(text: $prefs.userBio)
                    .font(.body)
                    .frame(height: 100)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LG.quartz(0.06))
                    )
            }
            HStack(spacing: 8) {
                Text("Profession").frame(width: 140, alignment: .leading)
                TextField("Software Engineer", text: $prefs.userProfession).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Text("Response style").frame(width: 140, alignment: .leading)
                Picker("Response style", selection: $prefs.userResponseStyle) {
                    ForEach(ResponseStyle.allCases) { s in Text(s.rawValue.capitalized).tag(s) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            Text("These preferences guide how responses are written. They are never exposed to tools or included in citations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Appearance settings removed as part of MLX-only cleanup

    private func browse(_ binding: inout String, canChooseFiles: Bool) {
        let p = NSOpenPanel()
        p.canChooseFiles = canChooseFiles
        p.canChooseDirectories = !canChooseFiles
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url {
            binding = url.path
        }
    }
}

// Makes the hosting NSWindow for this view glass-friendly (clear background, hidden title)
private struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let w = v.window {
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
                w.isOpaque = false
                w.backgroundColor = .clear
                // Extend content into title bar for an invisible top bar; dragging handled by WindowDragHandle overlay
                w.styleMask.insert(.fullSizeContentView)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
