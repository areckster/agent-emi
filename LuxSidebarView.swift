import SwiftUI
import AppKit

struct LuxSidebarView: View {
    @Binding var isOpen: Bool
    @EnvironmentObject private var store: ChatStore

    // Sidebar sizes similar to agent-lux: open ~172, collapsed ~44
    private let openWidth: CGFloat = 172
    private let collapsedWidth: CGFloat = 44

    // Rename sheet
    @State private var showRenameSheet = false
    @State private var renameText = ""
    @State private var renameTargetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconButton(system: isOpen ? "sidebar.left" : "sidebar.right", size: 28) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { isOpen.toggle() }
                }
                if isOpen {
                    Text("Chats").font(.headline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                IconButton(system: "square.and.pencil", size: 28) { withAnimation { store.newChat() } }
                    .help("New Chat")
            }

            Divider().opacity(0.25)

            if isOpen {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.chats) { chat in
                            Button { withAnimation { store.selectedChatID = chat.id } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "message")
                                    Text(chat.title.isEmpty ? "Untitled" : chat.title)
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(SidebarButtonStyle())
                            .contextMenu {
                                Button("Rename") { beginRename(chat) }
                                Divider()
                                Button("Delete", role: .destructive) { store.deleteChat(chat) }
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: .infinity)
                .clipped()
            } else {
                // Collapsed: keep content area empty; bottom control rendered below for consistency
                Spacer(minLength: 0)
            }

            Spacer()

            Group {
                if isOpen {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: openSettingsWindow) {
                            HStack(spacing: 6) {
                                Image(systemName: "gearshape")
                                Text("Settings")
                            }
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.clear)
                            )
                        }
                        .buttonStyle(.borderless)
                        .help("Settings")
                        Spacer(minLength: 0)
                    }
                } else {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: openSettingsWindow) {
                            Image(systemName: "gearshape")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("Settings")
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(10)
        .frame(width: isOpen ? openWidth : collapsedWidth, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: isOpen ? 18 : 14, style: .continuous)
            // Sidebar glass is 5% less transparent than the main background
            let base = AppEnv.prefs?.chatBackgroundOpacity ?? 0.92
            let glassOpacity = min(1.0, base + 0.05)
            shape
                .fill(.ultraThinMaterial)
                .opacity(glassOpacity)
                .glassEffect(.regular, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .clipShape(RoundedRectangle(cornerRadius: isOpen ? 18 : 14, style: .continuous))
        .animation(.interpolatingSpring(stiffness: 140, damping: 18), value: isOpen)
        .sheet(isPresented: $showRenameSheet) {
            RenameSheet(title: $renameText, onCancel: { showRenameSheet = false }, onSave: {
                if let id = renameTargetID, let chat = store.chats.first(where: { $0.id == id }) {
                    store.renameChat(chat, to: renameText)
                }
                showRenameSheet = false
            })
            .frame(width: 400)
        }
    }

    private func beginRename(_ chat: ChatThread) {
        renameTargetID = chat.id
        renameText = chat.title
        showRenameSheet = true
    }
}

private struct RenameSheet: View {
    @Binding var title: String
    var onCancel: () -> Void
    var onSave: () -> Void
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: [LG.backgroundGradientStart, LG.backgroundGradientEnd]), startPoint: .top, endPoint: .bottom)
                .opacity((AppEnv.prefs?.chatBackgroundOpacity ?? 0.92))
                .ignoresSafeArea()
            GlassCard(cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rename Chat").font(.headline)
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button("Cancel", action: onCancel); Button("Save", action: onSave).keyboardShortcut(.return) }
                }
            }
            .padding(16)
        }
    }
}

struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.10) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
