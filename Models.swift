//
//  Models.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//


import Foundation

enum ChatRole: String, Codable { case user, assistant }

struct Attachment: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var relativePath: String // relative to AppSupport/agent-lux/Attachments
    var byteSize: Int64
    var uti: String?
    init(id: UUID = UUID(), displayName: String, relativePath: String, byteSize: Int64, uti: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.relativePath = relativePath
        self.byteSize = byteSize
        self.uti = uti
    }
}

struct ChatSource: Codable, Equatable {
    var title: String
    var url: String
    var host: String
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    var text: String
    var think: String?
    var thinkDuration: Double?
    var sources: [ChatSource]?
    var attachments: [Attachment]?
    var date: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, think: String? = nil, thinkDuration: Double? = nil, sources: [ChatSource]? = nil, attachments: [Attachment]? = nil, date: Date = .now) {
        self.id = id; self.role = role; self.text = text; self.think = think; self.thinkDuration = thinkDuration; self.sources = sources; self.attachments = attachments; self.date = date
    }
}

struct ChatThread: Identifiable, Codable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isCommitted: Bool
    var summary: String?
    var draft: String?
    var messages: [ChatMessage]

    init(title: String) {
        self.id = UUID()
        self.title = title
        self.createdAt = .now
        self.updatedAt = .now
        self.isCommitted = false
        self.summary = nil
        self.draft = nil
        self.messages = []
    }
}

// Web search models
struct WSEngineResult: Codable, Hashable {
    var title: String
    var url: String
    var snippet: String
    var engine: String
    var host: String
    var score: Double
    var rank: Int
    var because: String?
    var authorityHint: Double?
    var type: String?
}

struct WSPayload: Codable {
    var ok: Bool
    var query: String
    var source: String
    var results: [WSEngineResult]
    var previews: [String] // raw extracts
    var summaries: [String] // LLM bullets
    var recommendedOpen: WSEngineResult?
    var queryHints: [String]
    var summarized: Bool
    var debug: [String: String]?
    var error: String?
}

// Tool call decode
struct ToolCall: Codable {
    struct Args: Codable {
        var query: String
        var topK: Int?

        enum CodingKeys: String, CodingKey {
            case query
            case topK = "top_k"
        }
    }
    var tool: String
    var args: Args
}
