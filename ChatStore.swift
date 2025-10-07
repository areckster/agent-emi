//
//  ChatStore.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//

import Foundation
import Combine

final class ChatStore: ObservableObject {
    @Published var chats: [ChatThread] = []
    @Published var selectedChatID: UUID?

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agent-lux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir.appendingPathComponent("chats.json")
    }

    static var attachmentsBaseURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agent-lux", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    init() {
        load()
        if chats.isEmpty {
            let c = ChatThread(title: "New Chat")
            chats = [c]
            selectedChatID = c.id
            save()
        } else if selectedChatID == nil {
            selectedChatID = chats.first?.id
        }
    }

    var selectedChat: ChatThread? {
        get { chats.first(where: { $0.id == selectedChatID }) }
        set {
            guard let value = newValue, let idx = chats.firstIndex(where: { $0.id == value.id }) else { return }
            chats[idx] = value
            save()
        }
    }

    // Convenience API to align with alternative view implementations
    func currentChat() -> ChatThread? { selectedChat }
    func historyForRunner() -> [ChatMessage] {
        guard let id = selectedChatID else { return [] }
        return historyForRunner(id)
    }
    func appendUser(text: String) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .user, text: text)
    }
    func appendUser(text: String, attachments: [Attachment]) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .user, text: text, think: nil, duration: nil, sources: nil, attachments: attachments)
    }
    func appendAssistant(text: String) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .assistant, text: text)
    }
    
    func appendAssistant(text: String, think: String?) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .assistant, text: text, think: think)
    }
    
    func appendAssistant(text: String, think: String?, duration: TimeInterval?) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .assistant, text: text, think: think, duration: duration)
    }
    func appendAssistant(text: String, think: String?, duration: TimeInterval?, sources: [ChatSource]?) {
        guard let id = selectedChatID else { return }
        appendMessage(id, role: .assistant, text: text, think: think, duration: duration, sources: sources)
    }

    func newChat() {
        let c = ChatThread(title: "New Chat")
        chats.insert(c, at: 0)
        selectedChatID = c.id
        save()
    }

    func deleteChat(_ chat: ChatThread) {
        chats.removeAll { $0.id == chat.id }
        if selectedChatID == chat.id { selectedChatID = chats.first?.id }
        save()
    }

    func renameChat(_ chat: ChatThread, to title: String) {
        guard let idx = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        chats[idx].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        chats[idx].updatedAt = .now
        save()
    }

    func updateDraft(_ chatID: UUID, text: String) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[idx].draft = text
        chats[idx].updatedAt = .now
        save()
    }

    func appendMessage(_ chatID: UUID, role: ChatRole, text: String) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[idx].messages.append(ChatMessage(role: role, text: text))
        chats[idx].updatedAt = .now
        if role == .assistant, chats[idx].isCommitted == false {
            chats[idx].isCommitted = true
        }
        // Seed title on first user message
        if role == .user, chats[idx].title == "New Chat" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chats[idx].title = String(trimmed.prefix(64))
            }
        }
        save()
    }

    // Variant that accepts reasoning content
    func appendMessage(_ chatID: UUID, role: ChatRole, text: String, think: String?) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[idx].messages.append(ChatMessage(role: role, text: text, think: think))
        chats[idx].updatedAt = .now
        if role == .assistant, chats[idx].isCommitted == false {
            chats[idx].isCommitted = true
        }
        // Seed title on first user message
        if role == .user, chats[idx].title == "New Chat" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chats[idx].title = String(trimmed.prefix(64))
            }
        }
        save()
    }

    func appendMessage(_ chatID: UUID, role: ChatRole, text: String, think: String?, duration: TimeInterval?) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let msg = ChatMessage(role: role, text: text, think: think, thinkDuration: duration)
        chats[idx].messages.append(msg)
        chats[idx].updatedAt = .now
        if role == .assistant, chats[idx].isCommitted == false {
            chats[idx].isCommitted = true
        }
        if role == .user, chats[idx].title == "New Chat" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chats[idx].title = String(trimmed.prefix(64)) }
        }
        save()
    }

    func appendMessage(_ chatID: UUID, role: ChatRole, text: String, think: String?, duration: TimeInterval?, sources: [ChatSource]?) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let msg = ChatMessage(role: role, text: text, think: think, thinkDuration: duration, sources: sources)
        chats[idx].messages.append(msg)
        chats[idx].updatedAt = .now
        if role == .assistant, chats[idx].isCommitted == false { chats[idx].isCommitted = true }
        if role == .user, chats[idx].title == "New Chat" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chats[idx].title = String(trimmed.prefix(64)) }
        }
        save()
    }

    func appendMessage(_ chatID: UUID, role: ChatRole, text: String, think: String?, duration: TimeInterval?, sources: [ChatSource]?, attachments: [Attachment]?) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let msg = ChatMessage(role: role, text: text, think: think, thinkDuration: duration, sources: sources, attachments: attachments)
        chats[idx].messages.append(msg)
        chats[idx].updatedAt = .now
        if role == .assistant, chats[idx].isCommitted == false { chats[idx].isCommitted = true }
        if role == .user, chats[idx].title == "New Chat" {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { chats[idx].title = String(trimmed.prefix(64)) }
        }
        save()
    }

    func setSummary(_ chatID: UUID, summary: String?) {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[idx].summary = summary
        chats[idx].updatedAt = .now
        save()
    }

    func clearAll() {
        let c = ChatThread(title: "New Chat")
        chats = [c]
        selectedChatID = c.id
        save()
    }

    @discardableResult
    func removeLastAssistantMessage(_ chatID: UUID) -> Bool {
        guard let idx = chats.firstIndex(where: { $0.id == chatID }) else { return false }
        if let lastIdx = chats[idx].messages.lastIndex(where: { $0.role == .assistant }) {
            chats[idx].messages.remove(at: lastIdx)
            chats[idx].updatedAt = .now
            save()
            return true
        }
        return false
    }

    func historyForRunner(_ chatID: UUID, keepLastNTurns: Int = 16) -> [ChatMessage] {
        guard let chat = chats.first(where: { $0.id == chatID }) else { return [] }
        var hist: [ChatMessage] = []
        if let s = chat.summary, !s.isEmpty {
            hist.append(ChatMessage(role: .assistant, text: "[Summary]\n\(s)"))
        }
        let tail = Array(chat.messages.suffix(keepLastNTurns * 2)) // user+assistant pairs approx
        hist.append(contentsOf: tail)
        return hist
    }

    // MARK: - Attachments import
    func importAttachments(urls: [URL], to chatID: UUID) -> [Attachment] {
        var out: [Attachment] = []
        let base = Self.attachmentsBaseURL.appendingPathComponent(chatID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: nil)
        for url in urls {
            guard url.isFileURL else { continue }
            let name = url.lastPathComponent
            let ext = (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? nil
            let sizeVal = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            let uid = UUID().uuidString
            let destName = uid + "__" + name
            let dest = base.appendingPathComponent(destName, isDirectory: false)
            do {
                // If file exists, remove before copying
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                let rel = chatID.uuidString + "/" + destName
                out.append(Attachment(displayName: name, relativePath: rel, byteSize: sizeVal, uti: ext))
            } catch {
                continue
            }
        }
        return out
    }

    private func load() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let decoded = try? JSONDecoder().decode([ChatThread].self, from: data) {
            chats = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(chats) {
            try? data.write(to: Self.storeURL)
        }
    }
}
