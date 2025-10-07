import Foundation
import Logging

struct RetrievalCandidate {
    let memory: MemoryRow
    let cosine: Double
    var neighborWeight: Double
}

struct Retriever {
    let storage: MemoryStore
    let graphStore: GraphStore
    let embedding: EmbeddingProvider
    let configuration: EngineConfiguration
    let logger: Logger

    func retrieve(query: String, limit k: Int) async throws -> [RetrievedMemory] {
        guard k > 0 else { return [] }
        let queryEmbedding = try await embedding.embed(texts: [query]).first ?? []
        var queryVector = queryEmbedding
        VectorMath.normalize(&queryVector)
        let rows = try await storage.fetchMemories(kind: [.episodic, .semantic, .procedural])
        let proceduralRows = rows.filter { $0.kind == .procedural }
        let vectors = rows.map { $0.embedding ?? [] }
        var filteredRows: [MemoryRow] = []
        var filteredVectors: [[Float]] = []
        for (row, vector) in zip(rows, vectors) where !vector.isEmpty {
            filteredRows.append(row)
            filteredVectors.append(vector)
        }
        let cosines = VectorMath.dotProducts(between: queryVector, and: filteredVectors.map { $0 })
        var cosineById: [Int: Double] = [:]
        for (row, cosine) in zip(filteredRows, cosines) {
            cosineById[row.id] = Double(cosine)
        }
        let paired = zip(filteredRows, cosines).map { (row, cosine) in
            RetrievalCandidate(memory: row, cosine: Double(cosine), neighborWeight: 0)
        }
        let sorted = paired.sorted { $0.cosine > $1.cosine }
        let topK1 = Array(sorted.prefix(min(8, sorted.count)))
        var candidatesById: [Int: RetrievalCandidate] = [:]
        for candidate in topK1 {
            candidatesById[candidate.memory.id] = candidate
        }
        for candidate in topK1 {
            let neighbors = try await graphStore.neighbors(of: candidate.memory.id)
            for edge in neighbors where edge.weight >= configuration.neighborEdgeThreshold {
                let neighborId = edge.srcId == candidate.memory.id ? edge.dstId : edge.srcId
                if var existing = candidatesById[neighborId] {
                    existing.neighborWeight = max(existing.neighborWeight, edge.weight)
                    candidatesById[neighborId] = existing
                } else if let neighborRow = filteredRows.first(where: { $0.id == neighborId }) {
                    let newCandidate = RetrievalCandidate(
                        memory: neighborRow,
                        cosine: cosineById[neighborId] ?? 0,
                        neighborWeight: edge.weight
                    )
                    candidatesById[neighborId] = newCandidate
                }
            }
        }
        var activationTuples: [(RetrievalCandidate, Double)] = []
        for candidate in candidatesById.values {
            let activation = 0.60 * candidate.cosine +
                0.20 * candidate.memory.importance +
                0.10 * candidate.memory.recencyBias +
                0.10 * candidate.neighborWeight
            activationTuples.append((candidate, activation))
        }
        activationTuples.sort { $0.1 > $1.1 }
        var selectedDict: [Int: (RetrievalCandidate, Double)] = [:]
        for (candidate, activation) in activationTuples.prefix(k) {
            selectedDict[candidate.memory.id] = (candidate, activation)
        }
        var extraAllowance = 0

        for candidate in topK1 {
            let neighborEdges = try await graphStore.neighbors(of: candidate.memory.id)
            let strongNeighbor = neighborEdges
                .filter { $0.weight >= configuration.neighborEdgeThreshold }
                .max(by: { $0.weight < $1.weight })
            if let strongNeighbor {
                let neighborId = strongNeighbor.srcId == candidate.memory.id ? strongNeighbor.dstId : strongNeighbor.srcId
                if let neighborCandidate = candidatesById[neighborId] {
                    let activation = 0.60 * neighborCandidate.cosine +
                        0.20 * neighborCandidate.memory.importance +
                        0.10 * neighborCandidate.memory.recencyBias +
                        0.10 * max(neighborCandidate.neighborWeight, strongNeighbor.weight)
                    if let existing = selectedDict[neighborId] {
                        if activation > existing.1 {
                            selectedDict[neighborId] = (neighborCandidate, activation)
                        }
                    } else {
                        selectedDict[neighborId] = (neighborCandidate, activation)
                        extraAllowance += 1
                    }
                }
            }
        }

        if Double.random(in: 0...1) <= configuration.driftProbability {
            let importanceSorted = rows.sorted { $0.importance > $1.importance }
            let topCount = max(1, Int(ceil(Double(importanceSorted.count) * 0.1)))
            let topSlice = importanceSorted.prefix(topCount)
            if let driftCandidateRow = topSlice.first(where: { selectedDict[$0.id] == nil }) ?? topSlice.first {
                let cosine = cosineById[driftCandidateRow.id] ?? 0
                let neighborWeight = candidatesById[driftCandidateRow.id]?.neighborWeight ?? 0
                let candidate = RetrievalCandidate(
                    memory: driftCandidateRow,
                    cosine: cosine,
                    neighborWeight: neighborWeight
                )
                let activation = 0.60 * cosine +
                    0.20 * driftCandidateRow.importance +
                    0.10 * driftCandidateRow.recencyBias +
                    0.10 * neighborWeight
                if let existing = selectedDict[driftCandidateRow.id] {
                    if activation > existing.1 {
                        selectedDict[driftCandidateRow.id] = (candidate, activation)
                    }
                } else {
                    selectedDict[driftCandidateRow.id] = (candidate, activation)
                    extraAllowance += 1
                }
            }
        }

        let queryTokens = Set(query.lowercased().split { !$0.isLetter }.map(String.init))
        let selectedTagSet = Set(selectedDict.values.flatMap { $0.0.memory.tags.map { $0.lowercased() } })
        var proceduralAdded = false
        for row in proceduralRows {
            guard selectedDict[row.id] == nil else { continue }
            let lowerTags = row.tags.map { $0.lowercased() }
            let tagMatchCount = lowerTags.filter { selectedTagSet.contains($0) || queryTokens.contains($0) }.count
            let cosine = cosineById[row.id] ?? 0
            if tagMatchCount == 0 && cosine < 0.25 && row.importance < 0.6 { continue }
            let activation = 0.60 * cosine +
                0.20 * row.importance +
                0.10 * row.recencyBias +
                0.10 * Double(min(1, tagMatchCount))
            let candidate = RetrievalCandidate(memory: row, cosine: cosine, neighborWeight: 0)
            selectedDict[row.id] = (candidate, activation)
            proceduralAdded = true
        }

        let bulletMap = buildBullets(for: Array(selectedDict.values))

        var results: [RetrievedMemory] = []
        let limit = k + extraAllowance + (proceduralAdded ? 1 : 0)
        let ordered = selectedDict.values.sorted { $0.1 > $1.1 }.prefix(limit)

        for (candidate, activation) in ordered {
            let textSnippet = bulletMap[candidate.memory.id] ?? String(candidate.memory.text.prefix(280))
            let reasons = buildReasons(candidate: candidate)
            let retrieved = RetrievedMemory(
                id: candidate.memory.id,
                kind: candidate.memory.kind,
                textSnippet: String(textSnippet),
                tags: candidate.memory.tags,
                activation: activation,
                reasons: reasons,
                citation: candidate.memory.meta["citation"].flatMap { $0.value as? String }
            )
            results.append(retrieved)
        }

        let logPayload: [String: Any] = [
            "query": query,
            "selected_ids": results.map { $0.id },
            "reasons": results.map { $0.reasons.map { ["label": $0.label, "score": $0.score] } }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: logPayload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            logger.info("retrieval", metadata: ["payload": .string(json)])
        }
        return results
    }

    private func buildReasons(candidate: RetrievalCandidate) -> [RetrievedMemory.Reason] {
        var reasons: [RetrievedMemory.Reason] = []
        if candidate.cosine > 0 {
            reasons.append(.init(label: "similarity", score: candidate.cosine))
        }
        if candidate.memory.importance > 0 {
            reasons.append(.init(label: "importance", score: candidate.memory.importance))
        }
        if candidate.neighborWeight > 0 {
            reasons.append(.init(label: "neighbor_edge", score: candidate.neighborWeight))
        }
        return reasons
    }

    private func buildBullets(for selected: [(RetrievalCandidate, Double)]) -> [Int: String] {
        var groups: [String: [RetrievalCandidate]] = [:]
        for (candidate, _) in selected {
            let key = candidate.memory.tags.sorted().first ?? candidate.memory.kind.rawValue
            groups[key, default: []].append(candidate)
        }
        var bullets: [Int: String] = [:]
        let limitedGroups = groups.keys.sorted().prefix(6)
        for key in limitedGroups {
            guard let candidates = groups[key] else { continue }
            let sample = candidates.first?.memory.text ?? ""
            let snippet = sample.split(separator: "\n").first.map(String.init) ?? sample
            let bullet = "• \(key): \(snippet.prefix(160))"
            for candidate in candidates {
                bullets[candidate.memory.id] = bullet
            }
        }
        return bullets
    }
}
