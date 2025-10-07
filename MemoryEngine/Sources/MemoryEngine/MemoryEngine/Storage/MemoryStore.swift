import Foundation
import SQLite
import Logging

struct MemoryRow {
    let id: Int
    let kind: MemoryKind
    let text: String
    let embedding: [Float]?
    let createdAt: Date
    let updatedAt: Date
    let lastAccessedAt: Date?
    let importance: Double
    let sentiment: Double?
    let recencyBias: Double
    let tags: [String]
    let meta: [String: AnyCodable]
}

struct EdgeRow {
    let srcId: Int
    let dstId: Int
    let weight: Double
    let createdAt: Date
    let updatedAt: Date
}

actor MemoryStore {
    private let db: Connection
    private let logger: Logger

    private let memories = Table("memories")
    private let edges = Table("edges")
    private let engineState = Table("engine_state")

    private let id = Expression<Int64>("id")
    private let kind = Expression<String>("kind")
    private let text = Expression<String>("text")
    private let embedding = Expression<Data?>("embedding")
    private let createdAt = Expression<Double>("created_at")
    private let updatedAt = Expression<Double>("updated_at")
    private let lastAccessedAt = Expression<Double?>("last_accessed_at")
    private let importance = Expression<Double>("importance")
    private let sentiment = Expression<Double?>("sentiment")
    private let recencyBias = Expression<Double>("recency_bias")
    private let tags = Expression<String?>("tags")
    private let meta = Expression<String?>("meta")

    private let srcId = Expression<Int64>("src_id")
    private let dstId = Expression<Int64>("dst_id")
    private let weight = Expression<Double>("weight")

    private let stateKey = Expression<String>("key")
    private let stateValue = Expression<String>("value")

    init(dbURL: URL, logger: Logger) async throws {
        db = try Connection(dbURL.path)
        db.busyTimeout = 1.0
        self.logger = logger
        try await migrate()
    }

    private func migrate() async throws {
        try db.run(memories.create(ifNotExists: true) { table in
            table.column(id, primaryKey: .autoincrement)
            table.column(kind)
            table.column(text)
            table.column(embedding)
            table.column(createdAt)
            table.column(updatedAt)
            table.column(lastAccessedAt)
            table.column(importance, defaultValue: 0.0)
            table.column(sentiment)
            table.column(recencyBias, defaultValue: 1.0)
            table.column(tags)
            table.column(meta)
        })

        try db.run(edges.create(ifNotExists: true) { table in
            table.column(srcId)
            table.column(dstId)
            table.column(weight)
            table.column(createdAt)
            table.column(updatedAt)
            table.primaryKey(srcId, dstId)
            table.foreignKey(srcId, references: memories, id, delete: .cascade)
            table.foreignKey(dstId, references: memories, id, delete: .cascade)
        })

        try db.run(engineState.create(ifNotExists: true) { table in
            table.column(stateKey, primaryKey: true)
            table.column(stateValue)
        })

        try db.run(memories.createIndex(kind, ifNotExists: true))
        try db.run(memories.createIndex(updatedAt, ifNotExists: true))
        try db.run(memories.createIndex(importance, ifNotExists: true))
        try db.run(edges.createIndex(srcId, ifNotExists: true))
        try db.run(edges.createIndex(dstId, ifNotExists: true))
    }

    // MARK: - Memory Access

    func insertMemory(_ row: MemoryRow, embeddingData: Data?) throws -> Int {
        let insert = memories.insert(
            kind <- row.kind.rawValue,
            text <- row.text,
            embedding <- embeddingData,
            createdAt <- row.createdAt.timeIntervalSince1970,
            updatedAt <- row.updatedAt.timeIntervalSince1970,
            lastAccessedAt <- row.lastAccessedAt?.timeIntervalSince1970,
            importance <- row.importance,
            sentiment <- row.sentiment,
            recencyBias <- row.recencyBias,
            tags <- row.tags.isEmpty ? nil : try String(data: JSONSerialization.data(withJSONObject: row.tags), encoding: .utf8),
            meta <- row.meta.isEmpty ? nil : try String(data: JSONSerialization.data(withJSONObject: row.meta.mapValues { $0.value }), encoding: .utf8)
        )
        let rowId = try db.run(insert)
        return Int(rowId)
    }

    func updateMemoryEmbedding(id memoryId: Int, embeddingData: Data?) throws {
        let row = memories.filter(id == Int64(memoryId))
        try db.run(row.update(embedding <- embeddingData, updatedAt <- Date().timeIntervalSince1970))
    }

    func updateProceduralMemory(
        id memoryId: Int,
        tags newTags: [String],
        importance newImportance: Double,
        recencyBias newBias: Double,
        embeddingData: Data?
    ) throws {
        let row = memories.filter(id == Int64(memoryId))
        let tagsString: String?
        if newTags.isEmpty {
            tagsString = nil
        } else if let data = try? JSONSerialization.data(withJSONObject: newTags),
                  let string = String(data: data, encoding: .utf8) {
            tagsString = string
        } else {
            tagsString = newTags.joined(separator: ",")
        }
        var setters: [Setter] = [
            importance <- max(0.0, min(1.0, newImportance)),
            recencyBias <- newBias,
            updatedAt <- Date().timeIntervalSince1970,
            tags <- tagsString
        ]
        if let embeddingData {
            setters.append(embedding <- embeddingData)
        }
        try db.run(row.update(setters))
    }

    func fetchMemories(kind kinds: [MemoryKind]? = nil) throws -> [MemoryRow] {
        var query = memories
        if let kinds {
            let rawValues = kinds.map { $0.rawValue }
            query = query.filter(rawValues.contains(kind))
        }
        return try db.prepare(query).compactMap { try mapRow($0) }
    }

    func fetchMemories(kind: MemoryKind, updatedAfter date: Date?) throws -> [MemoryRow] {
        var query = memories.filter(self.kind == kind.rawValue)
        if let date {
            query = query.filter(updatedAt > date.timeIntervalSince1970)
        }
        return try db.prepare(query).compactMap { try mapRow($0) }
    }

    func fetchMemories(ids: [Int]) throws -> [MemoryRow] {
        let idSet = Set(ids.map(Int64.init))
        return try db.prepare(memories.filter(idSet.contains(id))).compactMap { try mapRow($0) }
    }

    func updateLastAccessed(ids: [Int], date: Date) throws {
        let timestamp = date.timeIntervalSince1970
        for memoryId in ids {
            let row = memories.filter(id == Int64(memoryId))
            try db.run(row.update(lastAccessedAt <- timestamp, updatedAt <- timestamp))
        }
    }

    func updateRecencyBias(ids: [Int], values: [Double]) throws {
        guard ids.count == values.count else { return }
        for (memoryId, value) in zip(ids, values) {
            let row = memories.filter(id == Int64(memoryId))
            try db.run(row.update(recencyBias <- value, updatedAt <- Date().timeIntervalSince1970))
        }
    }

    func updateImportance(ids: [Int], multiplier: Double) throws {
        for memoryId in ids {
            let row = memories.filter(id == Int64(memoryId))
            if let existing = try db.pluck(row) {
                let newValue = max(0.0, min(1.0, try existing.get(importance) * multiplier))
                try db.run(row.update(importance <- newValue, updatedAt <- Date().timeIntervalSince1970))
            }
        }
    }

    func archiveMemory(id memoryId: Int) throws {
        let row = memories.filter(id == Int64(memoryId))
        try db.run(row.update(embedding <- nil, updatedAt <- Date().timeIntervalSince1970))
    }

    func updateMemoryMetadata(id memoryId: Int, importance newImportance: Double?, recencyBias newBias: Double?) throws {
        let row = memories.filter(id == Int64(memoryId))
        var setters: [Setter] = []
        if let newImportance {
            setters.append(importance <- max(0.0, min(1.0, newImportance)))
        }
        if let newBias {
            setters.append(recencyBias <- newBias)
        }
        if !setters.isEmpty {
            setters.append(updatedAt <- Date().timeIntervalSince1970)
            try db.run(row.update(setters))
        }
    }

    func upsertEngineState(key: String, value: String) throws {
        let row = engineState.filter(stateKey == key)
        if try db.run(row.update(stateValue <- value)) == 0 {
            try db.run(engineState.insert(stateKey <- key, stateValue <- value))
        }
    }

    func readEngineState(key: String) throws -> String? {
        if let row = try db.pluck(engineState.filter(stateKey == key)) {
            return try row.get(stateValue)
        }
        return nil
    }

    func fetchEdges(for id: Int) throws -> [EdgeRow] {
        let query = edges.filter(srcId == Int64(id) || dstId == Int64(id))
        return try db.prepare(query).map { row in
            EdgeRow(
                srcId: Int(try row.get(srcId)),
                dstId: Int(try row.get(dstId)),
                weight: try row.get(weight),
                createdAt: Date(timeIntervalSince1970: try row.get(createdAt)),
                updatedAt: Date(timeIntervalSince1970: try row.get(updatedAt))
            )
        }
    }

    func fetchAllEdges() throws -> [EdgeRow] {
        try db.prepare(edges).map { row in
            EdgeRow(
                srcId: Int(try row.get(srcId)),
                dstId: Int(try row.get(dstId)),
                weight: try row.get(weight),
                createdAt: Date(timeIntervalSince1970: try row.get(createdAt)),
                updatedAt: Date(timeIntervalSince1970: try row.get(updatedAt))
            )
        }
    }

    func upsertEdge(src: Int, dst: Int, weight newWeight: Double) throws {
        let sorted = src <= dst ? (src, dst) : (dst, src)
        let now = Date().timeIntervalSince1970
        let row = edges.filter(srcId == Int64(sorted.0) && dstId == Int64(sorted.1))
        if try db.run(row.update(weight <- newWeight, updatedAt <- now)) == 0 {
            try db.run(edges.insert(srcId <- Int64(sorted.0), dstId <- Int64(sorted.1), weight <- newWeight, createdAt <- now, updatedAt <- now))
        }
    }

    func decayEdges(factor: Double, floor: Double) throws {
        for edgeRow in try db.prepare(edges) {
            let current = try edgeRow.get(weight)
            let decayed = max(floor, current * factor)
            let srcValue = try edgeRow.get(srcId)
            let dstValue = try edgeRow.get(dstId)
            let row = edges.filter(srcId == srcValue && dstId == dstValue)
            try db.run(row.update(weight <- decayed, updatedAt <- Date().timeIntervalSince1970))
        }
    }

    func executeTransaction(_ block: () throws -> Void) throws {
        try db.transaction(.deferred, block: block)
    }

    // MARK: - Helpers

    private func mapRow(_ row: Row) throws -> MemoryRow {
        let tagString = try row.get(tags)
        let parsedTags: [String]
        if let tagString,
           let data = tagString.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String] {
            parsedTags = raw
        } else if let tagString {
            parsedTags = tagString.split(separator: ",").map { String($0) }
        } else {
            parsedTags = []
        }
        let metaString = try row.get(meta)
        let parsedMeta: [String: AnyCodable]
        if let metaString,
           let data = metaString.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsedMeta = raw.mapValues { AnyCodable($0) }
        } else {
            parsedMeta = [:]
        }
        let embeddingData = try row.get(embedding)
        let vector: [Float]?
        if let embeddingData {
            vector = embeddingData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }
        } else {
            vector = nil
        }

        return MemoryRow(
            id: Int(try row.get(id)),
            kind: MemoryKind(rawValue: try row.get(kind)) ?? .episodic,
            text: try row.get(text),
            embedding: vector,
            createdAt: Date(timeIntervalSince1970: try row.get(createdAt)),
            updatedAt: Date(timeIntervalSince1970: try row.get(updatedAt)),
            lastAccessedAt: try row.get(lastAccessedAt).map { Date(timeIntervalSince1970: $0) },
            importance: try row.get(importance),
            sentiment: try row.get(sentiment),
            recencyBias: try row.get(recencyBias),
            tags: parsedTags,
            meta: parsedMeta
        )
    }
}
