import Foundation

struct ProceduralRuleStore {
    private let storage: MemoryStore

    init(storage: MemoryStore) {
        self.storage = storage
    }

    func upsert(text: String, tags: [String], embedding: [Float]?) async throws {
        let normalizedTags = Array(Set(tags))
        let existing = try await storage.fetchMemories(kind: [.procedural])
        let embeddingData = embedding?.withUnsafeBufferPointer { Data(buffer: $0) }
        if let match = existing.first(where: { $0.text == text }) {
            try await storage.updateProceduralMemory(
                id: match.id,
                tags: normalizedTags,
                importance: max(match.importance, 0.75),
                recencyBias: 1.0,
                embeddingData: embeddingData
            )
        } else {
            let now = Date()
            let row = MemoryRow(
                id: 0,
                kind: .procedural,
                text: text,
                embedding: embedding,
                createdAt: now,
                updatedAt: now,
                lastAccessedAt: nil,
                importance: 0.8,
                sentiment: nil,
                recencyBias: 1.0,
                tags: normalizedTags,
                meta: [:]
            )
            _ = try await storage.insertMemory(row, embeddingData: embeddingData)
        }
    }

    func list() async throws -> [MemoryItem] {
        let rows = try await storage.fetchMemories(kind: [.procedural])
        return rows.map { row in
            MemoryItem(
                id: row.id,
                kind: row.kind,
                text: row.text,
                tags: row.tags,
                createdAt: row.createdAt,
                updatedAt: row.updatedAt,
                importance: row.importance,
                sentiment: row.sentiment,
                recencyBias: row.recencyBias,
                meta: row.meta
            )
        }
    }
}
