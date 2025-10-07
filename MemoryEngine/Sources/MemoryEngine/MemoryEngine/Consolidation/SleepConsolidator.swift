import Foundation
import Logging
#if canImport(Accelerate)
import Accelerate
#endif

struct SleepConsolidator {
    let storage: MemoryStore
    let graphStore: GraphStore
    let embedding: EmbeddingProvider
    let summarizer: SemanticSummarizer
    var configuration: EngineConfiguration
    let logger: Logger
    var calendar: Calendar = Calendar(identifier: .gregorian)

    private let checkpointKey = "sleep_checkpoint"

    func withinSleepWindow(now: Date) -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let startComponents = configuration.sleepWindowStart.split(separator: ":").compactMap { Int($0) }
        let endComponents = configuration.sleepWindowEnd.split(separator: ":").compactMap { Int($0) }
        guard startComponents.count == 2, endComponents.count == 2 else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let startMinutes = startComponents[0] * 60 + startComponents[1]
        let endMinutes = endComponents[0] * 60 + endComponents[1]
        if startMinutes <= endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        } else {
            return minutes >= startMinutes || minutes < endMinutes
        }
    }

    mutating func run(budgetSeconds: TimeInterval, now: Date = Date()) async throws {
        guard withinSleepWindow(now: now) else {
            logger.debug("sleep consolidate skipped - outside window")
            return
        }
        var checkpoint = try await loadCheckpoint()
        let updatedAfter = checkpoint.timestamp.map { Date(timeIntervalSince1970: $0) }
        let episodics = try await storage.fetchMemories(kind: .episodic, updatedAfter: updatedAfter)
            .filter { checkpoint.lastProcessedId == nil || $0.id > checkpoint.lastProcessedId! }
        guard !episodics.isEmpty else {
            try await saveCheckpoint(lastId: checkpoint.lastProcessedId ?? 0, timestamp: now.timeIntervalSince1970)
            return
        }
        let clusters = try await clusterEpisodics(episodics)
        let newSemanticIds = try await synthesizeSemanticMemories(clusters: clusters, now: now)
        try await weaveGraph(semanticIds: newSemanticIds)
        try await decayEdges()
        try await archiveOldMemories(reference: now)
        let touched = episodics + newSemanticIds.map { $0.row }
        try await recomputeRecency(for: touched, reference: now)
        checkpoint.lastProcessedId = episodics.map { $0.id }.max()
        checkpoint.timestamp = now.timeIntervalSince1970
        try await saveCheckpoint(lastId: checkpoint.lastProcessedId ?? 0, timestamp: checkpoint.timestamp)
    }

    private func loadCheckpoint() async throws -> (lastProcessedId: Int?, timestamp: TimeInterval?) {
        guard let value = try await storage.readEngineState(key: checkpointKey) else {
            return (nil, nil)
        }
        guard let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (nil, nil) }
        return (json["last_id"] as? Int, json["timestamp"] as? TimeInterval)
    }

    private func saveCheckpoint(lastId: Int, timestamp: TimeInterval?) async throws {
        var payload: [String: Any] = ["last_id": lastId]
        if let timestamp {
            payload["timestamp"] = timestamp
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        if let json = String(data: data, encoding: .utf8) {
            try await storage.upsertEngineState(key: checkpointKey, value: json)
        }
    }

    private func clusterEpisodics(_ episodics: [MemoryRow]) async throws -> [[MemoryRow]] {
        let vectors: [[Float]] = episodics.compactMap { $0.embedding }
        guard !vectors.isEmpty else { return [] }
        let estimate = max(2, min(32, Int(max(2.0, round(Double(vectors.count) / 50.0)))))
        let assignments = sphericalKMeans(vectors: vectors, k: estimate)
        var clusters: [[MemoryRow]] = Array(repeating: [], count: estimate)
        for (index, assignment) in assignments.enumerated() {
            clusters[assignment].append(episodics[index])
        }
        return clusters.filter { $0.count >= 4 }
    }

    private func sphericalKMeans(vectors: [[Float]], k: Int, maxIterations: Int = 15, tolerance: Float = 1e-3) -> [Int] {
        let count = vectors.count
        let clusterCount = max(1, min(k, count))
        var centroids: [[Float]] = []
        var rng = SystemRandomNumberGenerator()
        // k-means++ initialization
        centroids.append(vectors.randomElement(using: &rng) ?? vectors[0])
        while centroids.count < clusterCount {
            var distances = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let vector = vectors[i]
                var best: Float = .greatestFiniteMagnitude
                for centroid in centroids {
                    let dot = max(-1, min(1, dotProduct(vector, centroid)))
                    let dist = 1 - dot
                    best = min(best, dist)
                }
                distances[i] = best * best
            }
            let total = distances.reduce(0, +)
            let threshold = Float.random(in: 0...total)
            var cumulative: Float = 0
            var selectedIndex = 0
            for (index, distance) in distances.enumerated() {
                cumulative += distance
                if cumulative >= threshold {
                    selectedIndex = index
                    break
                }
            }
            centroids.append(vectors[selectedIndex])
        }
        var assignments = [Int](repeating: 0, count: count)
        for _ in 0..<maxIterations {
            var hasChanged = false
            for i in 0..<count {
                var bestIndex = 0
                var bestScore: Float = -Float.greatestFiniteMagnitude
                for (index, centroid) in centroids.enumerated() {
                    let score = dotProduct(vectors[i], centroid)
                    if score > bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }
                if assignments[i] != bestIndex {
                    assignments[i] = bestIndex
                    hasChanged = true
                }
            }
            if !hasChanged { break }
            var newCentroids = Array(repeating: [Float](repeating: 0, count: vectors[0].count), count: clusterCount)
            var counts = [Int](repeating: 0, count: clusterCount)
            for i in 0..<count {
                let clusterIndex = assignments[i]
#if canImport(Accelerate)
                vDSP.add(vectors[i], newCentroids[clusterIndex], result: &newCentroids[clusterIndex])
#else
                for j in 0..<vectors[i].count {
                    newCentroids[clusterIndex][j] += vectors[i][j]
                }
#endif
                counts[clusterIndex] += 1
            }
            for index in 0..<clusterCount {
                if counts[index] > 0 {
                    let scale = 1 / Float(counts[index])
#if canImport(Accelerate)
                    vDSP.multiply(scale, newCentroids[index], result: &newCentroids[index])
                    let norm = vDSP.norm(newCentroids[index])
                    if norm > .ulpOfOne {
                        vDSP.multiply(1 / norm, newCentroids[index], result: &newCentroids[index])
                    }
#else
                    for j in 0..<newCentroids[index].count {
                        newCentroids[index][j] *= scale
                    }
                    let norm = sqrt(newCentroids[index].reduce(0) { $0 + Double($1 * $1) })
                    if norm > .ulpOfOne {
                        let factor = Float(1 / norm)
                        for j in 0..<newCentroids[index].count {
                            newCentroids[index][j] *= factor
                        }
                    }
#endif
                } else {
                    newCentroids[index] = centroids[index]
                }
            }
            var maxShift: Float = 0
            for index in 0..<clusterCount {
                let shift = 1 - dotProduct(centroids[index], newCentroids[index])
                maxShift = max(maxShift, abs(shift))
            }
            centroids = newCentroids
            if maxShift < tolerance {
                break
            }
        }
        return assignments
    }

    private func synthesizeSemanticMemories(clusters: [[MemoryRow]], now: Date) async throws -> [SemanticResult] {
        var results: [SemanticResult] = []
        for cluster in clusters {
            let items = cluster.map { row in
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
            let summary = try await summarizer.summarize(cluster: items)
            var embeddingVector = try await embedding.embed(texts: [summary]).first ?? []
            VectorMath.normalize(&embeddingVector)
            let importance = min(1.0, max(0.0, cluster.map { $0.importance }.reduce(0, +) / Double(cluster.count) + 0.1))
            let recency = RecencyBiasCalculator(halfLifeDays: configuration.recencyHalfLifeDays).recencyBias(for: now, reference: now)
            let row = MemoryRow(
                id: 0,
                kind: .semantic,
                text: summary,
                embedding: embeddingVector,
                createdAt: now,
                updatedAt: now,
                lastAccessedAt: nil,
                importance: importance,
                sentiment: nil,
                recencyBias: recency,
                tags: Array(Set(cluster.flatMap { $0.tags })),
                meta: ["source": AnyCodable("semantic_cluster")]
            )
            let data = embeddingVector.withUnsafeBufferPointer { Data(buffer: $0) }
            let insertedId = try await storage.insertMemory(row, embeddingData: data)
            let storedRow = MemoryRow(
                id: insertedId,
                kind: .semantic,
                text: summary,
                embedding: embeddingVector,
                createdAt: now,
                updatedAt: now,
                lastAccessedAt: nil,
                importance: importance,
                sentiment: nil,
                recencyBias: recency,
                tags: Array(Set(cluster.flatMap { $0.tags })),
                meta: ["source": AnyCodable("semantic_cluster")]
            )
            results.append(SemanticResult(id: insertedId, embedding: embeddingVector, members: cluster, row: storedRow))
        }
        return results
    }

    private func weaveGraph(semanticIds: [SemanticResult]) async throws {
        for result in semanticIds {
            for member in result.members {
                try await graphStore.upsertEdge(src: result.id, dst: member.id, weight: 0.7)
            }
        }
        for (lhsIndex, lhs) in semanticIds.enumerated() {
            for rhs in semanticIds[(lhsIndex + 1)...] {
                let cosine = dotProduct(lhs.embedding, rhs.embedding)
                if cosine >= 0.55 {
                    try await graphStore.upsertEdge(src: lhs.id, dst: rhs.id, weight: 0.3)
                }
            }
        }
    }

    private func decayEdges() async throws {
        try await graphStore.decayAll(factor: 0.99, floor: 0.05)
    }

    private func archiveOldMemories(reference: Date) async throws {
        let episodics = try await storage.fetchMemories(kind: [.episodic])
        let cutoff = reference.addingTimeInterval(-90 * 24 * 60 * 60)
        for row in episodics where row.createdAt < cutoff && row.importance < 0.2 {
            let newImportance = row.importance * 0.9
            try await storage.updateMemoryMetadata(id: row.id, importance: newImportance, recencyBias: nil)
            if newImportance < 0.05 {
                try await storage.archiveMemory(id: row.id)
            }
        }
    }

    private func recomputeRecency(for rows: [MemoryRow], reference: Date) async throws {
        let calculator = RecencyBiasCalculator(halfLifeDays: configuration.recencyHalfLifeDays)
        let ids = rows.map { $0.id }
        let biases = rows.map { calculator.recencyBias(for: $0.createdAt, reference: reference) }
        try await storage.updateRecencyBias(ids: ids, values: biases)
    }

    private func dotProduct(_ lhs: [Float], _ rhs: [Float]) -> Float {
        var result: Float = 0
#if canImport(Accelerate)
        vDSP_dotpr(lhs, 1, rhs, 1, &result, vDSP_Length(lhs.count))
#else
        for i in 0..<lhs.count {
            result += lhs[i] * rhs[i]
        }
#endif
        return result
    }

    struct SemanticResult {
        let id: Int
        let embedding: [Float]
        let members: [MemoryRow]
        let row: MemoryRow
    }
}
