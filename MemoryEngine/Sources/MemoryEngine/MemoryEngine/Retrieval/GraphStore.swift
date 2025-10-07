import Foundation

struct GraphStore {
    private let storage: MemoryStore

    init(storage: MemoryStore) {
        self.storage = storage
    }

    func neighbors(of id: Int) async throws -> [EdgeRow] {
        try await storage.fetchEdges(for: id)
    }

    func upsertEdge(src: Int, dst: Int, weight: Double) async throws {
        try await storage.upsertEdge(src: src, dst: dst, weight: weight)
    }

    func decayAll(factor: Double, floor: Double) async throws {
        try await storage.decayEdges(factor: factor, floor: floor)
    }
}
