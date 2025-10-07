import Foundation

public protocol EmbeddingProvider {
    var dimension: Int { get }
    func embed(texts: [String]) async throws -> [[Float]]
}

public enum EmbeddingError: Error {
    case invalidResponse
    case transportFailure
    case dimensionMismatch
}
