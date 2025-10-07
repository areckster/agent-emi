import Foundation

public protocol SemanticSummarizer {
    func summarize(cluster: [MemoryItem]) async throws -> String
}

public struct PassthroughSummarizer: SemanticSummarizer {
    public init() {}
    public func summarize(cluster: [MemoryItem]) async throws -> String {
        let joined = cluster.map { $0.text }.joined(separator: "\n")
        return "Summary of \(cluster.count) memories:\n" + joined
    }
}
