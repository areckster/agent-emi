import SwiftUI
import AppKit
import Combine

struct MimicContentView: View {
    @EnvironmentObject private var prefs: AppPrefs
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var runner: LLMRunner

    @State private var userInput: String = ""
    @State private var showReasoning: Bool = false
    @State private var showSidebar: Bool = true
    @State private var justSentID: UUID?
    @State private var pendingAttachments: [Attachment] = []

    private var messages: [ChatMessage] { store.currentChat()?.messages ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(gradient: Gradient(colors: [
                LG.backgroundGradientStart,
                LG.backgroundGradientEnd
            ]), startPoint: .top, endPoint: .bottom)
            .opacity(prefs.chatBackgroundOpacity)
            .ignoresSafeArea()

            // Drag handle for hidden title bar windows
            WindowDragHandle()
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.clear)
                .ignoresSafeArea(edges: .top)

            HStack(spacing: 12) {
                LuxSidebarView(isOpen: $showSidebar)
                    .animation(.spring(response: 0.24, dampingFraction: 0.97), value: showSidebar)
                    .frame(width: showSidebar ? 172 : 44)

                VStack(spacing: 14) {
                    // Transcript card (restyled with tighter chrome and animated rows)
                    GlassCard(cornerRadius: 20) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(messages) { m in
                                        ChatBubbleRow(message: m, justSentID: justSentID)
                                            .id(m.id)
                                    }

                                    if runner.isRunning {
                                        VStack(alignment: .leading, spacing: 10) {
                                            ReasoningHud(
                                                show: $showReasoning,
                                                status: runner.statusLine.isEmpty ? "Thinking" : runner.statusLine,
                                                sites: runner.visitedSites.map { ($0.0, $0.1, $0.2) },
                                                thoughts: runner.streamingThink
                                            )

                                            ChatBubbleStreaming()
                                        }
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                    }

                                    Color.clear.frame(height: 1).id("BOTTOM")
                                }
                                .padding(.horizontal, 2)
                                .padding(.vertical, 2)
                            }
                            .frame(minHeight: 320)
                            .onChange(of: messages.count) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                            }
                            .onChange(of: runner.streamingVisible) {
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                            }
                            .onChange(of: runner.isRunning) { running in
                                if !running {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
                                }
                            }
                        }
                    }
                    // Smooth crossfade/scale when switching chats
                    .id(store.selectedChatID)
                    .transition(.asymmetric(insertion: .scale(scale: 0.985).combined(with: .opacity),
                                            removal: .opacity))
                    .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.selectedChatID)

                    ComposerBar(
                        text: $userInput,
                        isRunning: runner.isRunning,
                        maxLines: 5,
                        sendAction: send,
                        stopAction: { runner.stop() },
                        attachments: pendingAttachments,
                        attachAction: { openFilePicker() },
                        onRemoveAttachment: { att in
                            pendingAttachments.removeAll { $0.id == att.id }
                        }
                    )
                }
                .padding(.trailing, 4)
            }
            .padding(16)
            .padding(.top, 0)

            WindowConfigurator().frame(width: 0, height: 0)

            if let err = runner.lastError {
                HStack {
                    Spacer()
                    AnimatedErrorBanner(text: err)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(10)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.horizontal, 120)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: runner.lastError)
            }
        }
        .tint(LG.accent)
        .onAppear {
            if store.currentChat() == nil { store.newChat() }
        }
    }

    private func send() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !runner.isRunning else { return }
        if pendingAttachments.isEmpty {
            store.appendUser(text: text)
        } else {
            store.appendUser(text: text, attachments: pendingAttachments)
        }
        if let last = store.currentChat()?.messages.last { justSentID = last.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if justSentID == store.currentChat()?.messages.last?.id { justSentID = nil }
        }
        userInput = ""
        pendingAttachments.removeAll()

        let history = store.historyForRunner()
        runner.generateWithToolsStreaming(
            prefs: prefs,
            history: history,
            forceSearchIfUserAsked: text.lowercased().contains("search") || text.lowercased().contains("find "),
            onEvent: { _ in },
            completion: { result in
                switch result {
                case .failure:
                    // Ensure UI unlocks in edge cases
                    runner.isRunning = false
                case .success(let out):
                    let final: String
                    if out.isEmpty {
                        // streamingVisible is already sanitized by the runner
                        final = runner.streamingVisible
                    } else {
                        final = Sanitizer.sanitizeLLM(out)
                    }
                    // Capture reasoning before clearing
                    let thinkFinal = runner.streamingThink.trimmingCharacters(in: .whitespacesAndNewlines)
                    let dur = runner.lastThinkDuration
                    let cleaned = purgeHallucinatedSources(final, usedSearch: runner.usedSearchThisAnswer)
                    let srcs: [ChatSource]? = runner.usedSearchThisAnswer ? runner.visitedSites.map { ChatSource(title: $0.0, url: $0.1, host: $0.2) } : nil
                    store.appendAssistant(text: cleaned, think: thinkFinal.isEmpty ? nil : thinkFinal, duration: dur, sources: srcs)
                    if let lastID = store.currentChat()?.messages.last?.id {
                        runner.justCompletedMessageID = lastID
                    }
                    // Defensive: ensure UI resets even if upstream finish didn't toggle fast enough
                    runner.isRunning = false
                    runner.streamingVisible = ""
                    runner.streamingThink = ""
                }
            }
        )
    }

    private func openFilePicker() {
        guard let chatID = store.selectedChatID else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseFiles = true
        p.canChooseDirectories = false
        if p.runModal() == .OK {
            let imported = store.importAttachments(urls: p.urls, to: chatID)
            pendingAttachments.append(contentsOf: imported)
        }
    }
}

// MARK: - Subviews

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let w = v.window {
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
                w.isMovableByWindowBackground = false
                w.backgroundColor = .clear
                // Extend content into title bar for an invisible top bar; dragging handled by WindowDragHandle overlay
                w.styleMask.insert(.fullSizeContentView)
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct AnimatedErrorBanner: View {
    var text: String
    @State private var appear = false
    @State private var hovered = false
    @State private var dismissWork: DispatchWorkItem?
    @EnvironmentObject private var runner: LLMRunner

    private func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak runner] in
            if !(hovered) {
                runner?.lastError = nil
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    var body: some View {
        GlassCard(cornerRadius: 14) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 2)
        }
        .onHover { inside in
            hovered = inside
            if inside {
                dismissWork?.cancel()
            } else {
                scheduleDismiss(after: 2.0)
            }
        }
        .scaleEffect(appear ? 1.0 : 0.98)
        .opacity(appear ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { appear = true }
            // Initial auto-dismiss; hover can cancel it
            scheduleDismiss(after: 3.5)
        }
        .onDisappear { dismissWork?.cancel() }
    }
}

private struct ComposerBar: View {
    @Binding var text: String
    var isRunning: Bool
    var maxLines: Int
    var sendAction: () -> Void
    var stopAction: () -> Void
    var attachments: [Attachment]
    var attachAction: () -> Void
    var onRemoveAttachment: (Attachment) -> Void
    @FocusState private var isFocused: Bool
    @EnvironmentObject private var prefs: AppPrefs
    @EnvironmentObject private var store: ChatStore
    
    var body: some View {
        GlassCard(cornerRadius: 18, contentPadding: EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)) {
            HStack(alignment: .center, spacing: 8) {
                IconButton(system: "paperclip", size: 28) { attachAction() }
                    .help("Attach files")
                
                GrowingTextView(text: $text,
                                 placeholder: "Ask anything…",
                                 maxLines: maxLines,
                                 onSend: {
                    // Enter sends; Shift+Enter handled inside GrowingTextView to insert newline
                    if !isRunning {
                        sendAction()
                    }
                },
                                 placeholderColor: NSColor(calibratedWhite: 1.0, alpha: 0.45),
                                 textColor: NSColor(calibratedWhite: 1.0, alpha: 0.98),
                                 bgColor: .clear,
                                 onFocusChange: { focused in isFocused = focused })
                .frame(minHeight: 28)

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(attachments) { att in
                                AttachmentPill(attachment: att, removable: true) {
                                    onRemoveAttachment(att)
                                }
                            }
                        }
                    }
                    .frame(height: 28)
                }

                ReasoningLevelMenu(level: $prefs.reasoningEffort)
                    .help("Reasoning effort")
                
                SendButton(isRunning: isRunning,
                           enabled: !isRunning && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           onSend: {
                    guard !isRunning else { return }
                    sendAction()
                },
                           onStop: {
                    guard isRunning else { return }
                    stopAction()
                })
                // Enter to send handled by GrowingTextView
            }
            .onAppear { isFocused = true }
        }
        .scaleEffect(isFocused ? 1.01 : 1.0)
        .shadow(color: Color.black.opacity(isFocused ? 0.25 : 0.0), radius: isFocused ? 12 : 0, x: 0, y: 6)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: isFocused)
    }
}

// Attachment chip with optional remove button
private struct AttachmentPill: View {
    var attachment: Attachment
    var removable: Bool = false
    var onRemove: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "paperclip")
                .font(.system(size: 10, weight: .semibold))
            Text(attachment.displayName).lineLimit(1)
                .font(.caption)
            Text(formatSize(attachment.byteSize)).font(.caption2).foregroundStyle(.secondary)
            if removable, let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(LG.quartz(0.14)))
        .overlay(Capsule(style: .continuous).stroke(LG.stroke, lineWidth: 1))
    }
    private func formatSize(_ s: Int64) -> String {
        let f = ByteCountFormatter(); f.allowedUnits = [.useKB, .useMB]; f.countStyle = .file
        return f.string(fromByteCount: s)
    }
}

private struct SendButton: View {
    var isRunning: Bool
    var enabled: Bool
    var size: CGFloat = 32
    var onSend: () -> Void
    var onStop: () -> Void
    var body: some View {
        // Action depends on state
        let action = isRunning ? onStop : onSend
        let isEnabled = isRunning ? true : enabled
        let label: some View = Group {
            if isRunning {
                Label("Stop", systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "arrow.up")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
        }
        
        return Button(action: action) {
            label
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .background(GlassCircle(size: size))
        .overlay(Circle().stroke(isEnabled ? LG.accent.opacity(0.45) : .clear, lineWidth: 1))
        .foregroundStyle(isEnabled ? LG.accent : .secondary)
        .opacity(isEnabled ? 1.0 : 0.55)
        .help(isRunning ? "Stop generating" : "Send (⌘⏎)")
    }
}

private struct RoleTag: View {
    var text: String
    var color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color.opacity(0.95))
            .frame(width: 72, alignment: .trailing)
    }
}

// MARK: - New chat rows

private struct RoleChip: View {
    var role: ChatRole
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: role == .user ? "person.fill" : "sparkles")
                .font(.system(size: 11, weight: .semibold))
            Text(role == .user ? "You" : "Assistant")
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(role == .user ? LG.accent.opacity(0.16) : LG.quartz(0.14))
        )
        .overlay(
            Capsule(style: .continuous).stroke(role == .user ? LG.accent.opacity(0.35) : LG.stroke, lineWidth: 1)
        )
        .foregroundStyle(role == .user ? LG.accent : .secondary)
    }
}

private struct ChatBubbleRow: View {
    let message: ChatMessage
    var justSentID: UUID?
    @State private var appear = false
    @EnvironmentObject private var runner: LLMRunner
    @EnvironmentObject private var prefs: AppPrefs
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.role == .assistant {
                VStack(alignment: .leading, spacing: 6) {
                    AssistantHeaderWithReasoning(message: message)
                    MessageBubble(role: .assistant) {
                        WaveBoldOnAppear(isActive: shouldAnimate(message), duration: 2.2, progressiveReveal: prefs.progressiveRevealOnAnswer) {
                            MarkdownView(message.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let sources = message.sources, !sources.isEmpty {
                        HStack(spacing: 8) {
                            Text("Sources:")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
                                        SitePill(title: s.title, url: s.url, host: s.host)
                                    }
                                }
                            }
                        }
                    }
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachments) { att in
                                    AttachmentOpenPill(attachment: att)
                                }
                            }
                        }
                    }
                }
                .scaleEffect(appear ? 1.0 : 0.992)
                .opacity(appear ? 1.0 : 0.0)
                .offset(x: appear ? 0 : -6)
                Spacer(minLength: 36)
            } else {
                Spacer(minLength: 36)
                VStack(alignment: .trailing, spacing: 6) {
                    RoleChip(role: .user)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    MessageBubble(role: .user) {
                        UserSendArrival(isActive: message.id == justSentID) {
                            MarkdownView(message.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .scaleEffect(message.id == justSentID ? 1.02 : 1.0)
                    .shadow(color: Color.black.opacity(message.id == justSentID ? 0.18 : 0.0), radius: message.id == justSentID ? 8 : 0, x: 0, y: 6)
                    .animation(.spring(response: 0.22, dampingFraction: 0.78), value: justSentID)
                    .overlay(
                        Group {
                            if message.id == justSentID {
                                BubbleFillPulse(cornerRadius: 16)
                                    .allowsHitTesting(false)
                            }
                        }
                    )
                    if let attachments = message.attachments, !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(attachments) { att in
                                    AttachmentOpenPill(attachment: att)
                                }
                            }
                        }
                    }
                }
                .scaleEffect(appear ? 1.0 : 0.992)
                .opacity(appear ? 1.0 : 0.0)
                .offset(x: appear ? 0 : 6)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { appear = true }
            if shouldAnimate(message) {
                // Clear after animation to avoid replaying on history open
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                    if runner.justCompletedMessageID == message.id { runner.justCompletedMessageID = nil }
                }
            }
        }
    }
    private func shouldAnimate(_ msg: ChatMessage) -> Bool { runner.justCompletedMessageID == msg.id }
}

// Compact menu to choose reasoning effort inline
private struct ReasoningLevelMenu: View {
    @Binding var level: ReasoningEffort
    var body: some View {
        Menu {
            ForEach(ReasoningEffort.allCases) { e in
                Button(action: { level = e }) {
                    if e == level { Image(systemName: "checkmark") }
                    Text(e.rawValue.capitalized)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                Text(levelLabel(level))
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(LG.quartz(0.14)))
            .overlay(Capsule(style: .continuous).stroke(LG.stroke, lineWidth: 1))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }
    private func levelLabel(_ e: ReasoningEffort) -> String {
        switch e { case .low: return "Low"; case .medium: return "Medium"; case .high: return "High" }
    }
}

// Refined, subtle arrival animation for user messages
private struct UserSendArrival<Content: View>: View {
    var isActive: Bool
    @ViewBuilder var content: () -> Content
    @State private var appeared: Bool = false
    @State private var blur: CGFloat = 4
    @State private var xOffset: CGFloat = 10
    @State private var scale: CGFloat = 0.98
    var body: some View {
        content()
            .blur(radius: appeared ? 0 : blur)
            .offset(x: appeared ? 0 : xOffset)
            .scaleEffect(appeared ? 1.0 : scale)
            .onAppear {
                guard isActive else { appeared = true; return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    appeared = true
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    appeared = false
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) { appeared = true }
                }
            }
    }
}

// Quick, soft inner highlight to make the bubble feel tactile on arrival
private struct BubbleFillPulse: View {
    var cornerRadius: CGFloat = 16
    @State private var opacity: Double = 0.35
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(colors: [
                    Color.white.opacity(0.22),
                    Color.white.opacity(0.06)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.35)) { opacity = 0.0 }
            }
    }
}

// MARK: - Upgraded reasoning HUD

private struct ReasoningHud: View {
    @EnvironmentObject private var runner: LLMRunner
    @Binding var show: Bool
    var status: String
    var sites: [(title: String, url: String, host: String)]
    var thoughts: String
    @State private var pulse = false

    var body: some View {
        ReasoningChip(isActive: true, status: status, show: $show)
            .onAppear { pulse = true }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                ReasoningPopover(status: status, sites: sites, thoughts: thoughts, animated: runner.isRunning)
                    .frame(width: 480, height: 240)
                    .padding(12)
            }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

private struct SitePill: View {
    var title: String
    var url: String
    var host: String
    var body: some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(LG.quartz(0.14)).frame(width: 18, height: 18)
                    Text(host.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(title).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(LG.quartz(0.14))
            )
            .overlay(Capsule(style: .continuous).stroke(LG.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// Clickable attachment chip that opens the local file
private struct AttachmentOpenPill: View {
    var attachment: Attachment
    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .font(.system(size: 10, weight: .semibold))
                Text(attachment.displayName).lineLimit(1)
                    .font(.caption)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                Capsule(style: .continuous).fill(LG.quartz(0.14))
            )
            .overlay(Capsule(style: .continuous).stroke(LG.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private func open() {
        let base = ChatStore.attachmentsBaseURL
        let url = base.appendingPathComponent(attachment.relativePath)
        NSWorkspace.shared.open(url)
    }
}

private struct MessageBubble<Content: View>: View {
    var role: ChatRole
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Group {
            if role == .user {
                VStack(alignment: .leading, spacing: 6) { content }
                    .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                    .background(
                        shape
                            .fill(LinearGradient(colors: [LG.accent.opacity(0.18), LG.accent.opacity(0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .overlay(shape.stroke(LG.accent.opacity(0.45), lineWidth: 1))
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                    .clipShape(shape)
                    .shadow(color: Color.black.opacity(0.25), radius: 12, x: 0, y: 6)
            } else {
                GlassCard(cornerRadius: 16, contentPadding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                    VStack(alignment: .leading, spacing: 6) { content }
                }
                .overlay(shape.stroke(LG.stroke, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.20), radius: 10, x: 0, y: 6)
            }
        }
    }
}

// Streaming assistant bubble that animates content arrival
private struct ChatBubbleStreaming: View {
    @EnvironmentObject private var runner: LLMRunner
    @State private var shimmering = false
    var body: some View {
        Group {
            if !runner.streamingVisible.isEmpty {
                MessageBubble(role: .assistant) {
                    MarkdownView(runner.streamingVisible)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            } else {
                EmptyView()
            }
        }
        .transition(.opacity)
    }
}

private struct ThreeDots: View {
    @State private var idx: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(dotColor(0)).frame(width: 6, height: 6)
            Circle().fill(dotColor(1)).frame(width: 6, height: 6)
            Circle().fill(dotColor(2)).frame(width: 6, height: 6)
        }
        .onReceive(timer) { _ in idx = (idx + 1) % 3 }
    }
    private func dotColor(_ i: Int) -> Color { i == idx ? LG.accent : Color.white.opacity(0.3) }
}

// MARK: - Reasoning controls (chip + popover)

private struct ReasoningChip: View {
    @EnvironmentObject private var runner: LLMRunner
    var isActive: Bool
    var status: String
    @Binding var show: Bool
    @State private var pulse = false
    @State private var spin = false
    var body: some View {
        Button(action: { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { show.toggle() } }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill((isActive ? LG.accent : Color.white).opacity(0.16)).frame(width: 16, height: 16)
                    Circle().stroke((isActive ? LG.accent : Color.white).opacity(0.45), lineWidth: 1).frame(width: 16, height: 16)
                    Circle()
                        .fill(isActive ? LG.accent : .secondary)
                        .frame(width: pulse ? 5 : 3, height: pulse ? 5 : 3)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                }
                Text(runner.isSearching ? "Searching" : "Reasoning")
                    .font(.caption.weight(.semibold))
                if runner.isSearching {
                    Image(systemName: "magnifyingglass")
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(LG.quartz(0.14)))
            .overlay(Capsule(style: .continuous).stroke(LG.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true; spin = true }
    }
}

private struct ReasoningPopover: View {
    @EnvironmentObject private var runner: LLMRunner
    var status: String
    var sites: [(title: String, url: String, host: String)]
    var thoughts: String
    var animated: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(runner.isSearching ? "Searching" : "Reasoning")
                    .font(.headline)
                Spacer()
            }
            if !sites.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sites.enumerated()), id: \.offset) { _, s in
                            SitePill(title: s.title, url: s.url, host: s.host)
                        }
                    }
                }
            }
            if !thoughts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    ReasoningAnimatedList(thoughts: thoughts, animated: animated)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No reasoning yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(6)
    }
}

// Reasoning prettifier: transform plain thoughts into readable bullets when unstructured
private func prettyReasoning(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return t }
    let normalized = t.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let bulletPrefixes = ["- ", "* ", "• "]
    let numberedPattern = try? NSRegularExpression(pattern: "^\\s*\\d+\\.\\s+")
    let hasBullets = lines.filter { line in
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { return false }
        if bulletPrefixes.contains(where: { l.hasPrefix($0) }) { return true }
        if let re = numberedPattern, re.firstMatch(in: l, options: [], range: NSRange(location: 0, length: (l as NSString).length)) != nil { return true }
        return false
    }.count >= 2
    if hasBullets { return t }

    // Extract sentences (simple heuristic)
    let regex = try? NSRegularExpression(pattern: "[^.!?\n]+[.!?]", options: [])
    var sentences: [String] = []
    if let re = regex {
        let ns = normalized as NSString
        let matches = re.matches(in: normalized, range: NSRange(location: 0, length: ns.length))
        sentences = matches.map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
    }
    if sentences.isEmpty {
        // fallback: split by line
        let bulleted = lines.map { l -> String in
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : "- \(trimmed)"
        }.joined(separator: "\n")
        return bulleted
    }

    // Group sentences into multi-sentence bullets for readability
    let n = sentences.count
    let chunk: Int
    if n <= 3 { chunk = 1 }
    else if n <= 7 { chunk = 2 }
    else { chunk = 3 }
    var bullets: [String] = []
    var i = 0
    while i < n {
        let j = min(i + chunk, n)
        let group = sentences[i..<j].joined(separator: " ")
        bullets.append("- \(group)")
        i = j
    }
    return bullets.joined(separator: "\n")
}

// Streaming-friendly: always emit at least one bullet with the raw text
private func streamingFriendlyBullets(_ s: String) -> String {
    let t = s.replacingOccurrences(of: "\r\n", with: "\n")
    if t.contains("\n- ") || t.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
        return t
    }
    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return "- " + trimmed
}

// Animated reasoning list: reveals complete bullets as they form
private struct ReasoningAnimatedList: View {
    var thoughts: String
    var animated: Bool
    @State private var finalized: [String] = []
    @State private var lastSnapshot: String = ""

    private let groupSize = 2 // reveal two sentences per bullet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if animated {
                ForEach(Array(finalized.enumerated()), id: \.offset) { _, line in
                    WaveBoldOnAppear(isActive: true, duration: 1.1) {
                        MarkdownView(line)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            } else {
                MarkdownView(prettyReasoning(thoughts))
            }
        }
        .onAppear {
            lastSnapshot = thoughts
            if animated { finalized.removeAll() }
            revealCycle()
        }
        .onChange(of: thoughts) {
            revealCycle()
        }
    }

    private func sentences(from text: String) -> [String] {
        let t = text.replacingOccurrences(of: "\r\n", with: " ")
        let ns = t as NSString
        // Simple sentence matcher: any run ending with ., !, or ? followed by space or EoS
        let pattern = #"[^.!?]+[.!?]"#
        let re = try? NSRegularExpression(pattern: pattern, options: [])
        let matches = re?.matches(in: t, options: [], range: NSRange(location: 0, length: ns.length)) ?? []
        return matches.map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func builtGroups() -> [String] {
        let raw = thoughts
        // If the model already emits bullets, respect them
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let modelBullets = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") && $0.count > 3 }
        if modelBullets.count >= 2 {
            return modelBullets
        }
        // Otherwise group sentences
        let sents = sentences(from: raw)
        guard !sents.isEmpty else { return [] }
        var groups: [String] = []
        var i = 0
        while i + (groupSize - 1) < sents.count { // only complete groups
            let chunk = sents[i..<min(i + groupSize, sents.count)].joined(separator: " ")
            groups.append("- " + chunk)
            i += groupSize
        }
        return groups
    }

    private func revealCycle() {
        guard animated else { return }
        let groups = builtGroups()
        // Reveal new complete groups one-by-one with animation
        while finalized.count < groups.count {
            let next = groups[finalized.count]
            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                finalized.append(next)
            }
        }
        lastSnapshot = thoughts
    }
}

// Remove fabricated source claims when no search was used
private func purgeHallucinatedSources(_ text: String, usedSearch: Bool) -> String {
    // Remove source claims regardless of whether search was used;
    // sources should be shown via UI (site pills), not inline strings.
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let filtered = lines.filter { line in
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^\(Visited\s+\d+\s+URLs?[^)]*\)\s*$"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^(?i)(sources|citations)\s*:.*$"#, options: .regularExpression) != nil { return false }
        return true
    }
    return filtered.joined(separator: "\n")
}

private struct AssistantHeaderWithReasoning: View {
    let message: ChatMessage
    @State private var show = false
    var body: some View {
        HStack(spacing: 8) {
            RoleChip(role: .assistant)
            if let d = message.thinkDuration, let t = message.think, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider().frame(height: 10).overlay(Color.white.opacity(0.25))
                Button(action: { withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { show.toggle() } }) {
                    Text("reasoned for \(formatDuration(d))")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $show, arrowEdge: .bottom) {
                    ReasoningPopover(status: "Saved", sites: [], thoughts: t, animated: false)
                        .frame(width: 440, height: 220)
                        .padding(12)
                }
            }
            Spacer()
        }
    }
    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let min = s / 60
        let sec = s % 60
        if min == 0 { return "\(sec) second\(sec == 1 ? "" : "s")" }
        if sec == 0 { return "\(min) minute\(min == 1 ? "" : "s")" }
        return "\(min) minute\(min == 1 ? "" : "s") and \(sec) second\(sec == 1 ? "" : "s")"
    }
}

// MARK: - Animated reveal for final assistant text
private struct RevealOnAppear<Content: View>: View {
    enum Direction { case leftToRight, diagonal }
    var duration: Double = 1.8
    var direction: Direction = .leftToRight
    @ViewBuilder var content: Content
    @State private var progress: CGFloat = 0.0
    @State private var fade: Double = 0.92
    @State private var scale: CGFloat = 0.995
    var body: some View {
        content
            .opacity(fade)
            .scaleEffect(scale)
            .mask(GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                let start: UnitPoint = (direction == .diagonal) ? .topLeading : .leading
                let end: UnitPoint = (direction == .diagonal) ? .bottomTrailing : .trailing
                LinearGradient(gradient: Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: progress),
                    .init(color: .clear, location: progress)
                ]), startPoint: start, endPoint: end)
                .frame(width: w, height: h)
            })
            .overlay(
                LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .blendMode(.screen)
                    .mask(
                        GeometryReader { proxy in
                            let w = proxy.size.width
                            let h = proxy.size.height
                            Rectangle()
                                .frame(width: w * 0.2, height: h)
                                .offset(x: (progress * w) - w * 0.2, y: 0)
                        }
                    )
                    .allowsHitTesting(false)
            )
            .onAppear {
                withAnimation(.easeOut(duration: duration)) { progress = 1.0 }
                withAnimation(.easeOut(duration: duration * 0.85)) { fade = 1.0; scale = 1.0 }
            }
    }
}

// Boldness wave overlay for new messages
private struct WaveBoldOnAppear<Content: View>: View {
    var isActive: Bool
    var duration: Double = 2.2
    var angle: Angle = .degrees(20)
    var progressiveReveal: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var progress: CGFloat = -0.2
    @State private var played = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Base layer (optionally revealed with progress). When the wave finishes,
            // show the full content to avoid ending in a masked (blank) state.
            Group {
                if progressiveReveal && isActive && !played {
                    content()
                        .mask(
                            GeometryReader { proxy in
                                let w = proxy.size.width
                                let h = proxy.size.height
                                let reveal = max(0.0, min(1.0, (progress + 0.2) / 1.4))
                                // Main horizontal reveal area only
                                Rectangle().frame(width: w * reveal, height: h)
                            }
                        )
                } else {
                    content()
                }
            }
            if isActive && !played {
                content()
                    .contrast(1.18)
                    .brightness(0.06)
                    .saturation(1.05)
                    .shadow(color: Color.white.opacity(0.05), radius: 1.0, x: 0, y: 0)
                    .mask(
                        GeometryReader { proxy in
                            let w = proxy.size.width
                            let h = proxy.size.height
                            let band = max(80, min(240, w * 0.25))
                            let x = (progress * (w + band)) - band
                            LinearGradient(gradient: Gradient(stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white, location: 0.5),
                                .init(color: .clear, location: 1.0)
                            ]), startPoint: .leading, endPoint: .trailing)
                            .frame(width: band, height: max(h * 1.4, 120))
                            .rotationEffect(angle, anchor: .leading)
                            .offset(x: x, y: -(h * 0.2))
                        }
                    )
                    .allowsHitTesting(false)

                // Glint streak
                content()
                    .blendMode(.screen)
                    .mask(
                        GeometryReader { proxy in
                            let w = proxy.size.width
                            let h = proxy.size.height
                            let band = max(40, min(120, w * 0.12))
                            let x = (progress * (w + band)) - band
                            LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band, height: max(h * 1.3, 100))
                                .rotationEffect(angle, anchor: .leading)
                                .offset(x: x, y: -(h * 0.18))
                        }
                    )
                    .allowsHitTesting(false)

                // Removed extra rise effect (new animations disabled)
            }
        }
        .onAppear {
            guard isActive, !played else { return }
            withAnimation(.easeInOut(duration: duration)) { progress = 1.2 }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { played = true }
        }
        .onChange(of: isActive) { _, newVal in
            if newVal && !played {
                progress = -0.2
                withAnimation(.easeInOut(duration: duration)) { progress = 1.2 }
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { played = true }
            }
        }
    }
}
