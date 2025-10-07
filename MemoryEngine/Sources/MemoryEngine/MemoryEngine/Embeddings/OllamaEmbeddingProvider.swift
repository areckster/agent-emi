import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class OllamaEmbeddingProvider: EmbeddingProvider {
    public let dimension: Int
    private let baseURL: URL
    private let model: String
    private let session: URLSession

    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String = "nomic-embed-text", dimension: Int = 768, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.dimension = dimension
        self.session = session
    }

    private struct Request: Encodable {
        let model: String
        let input: [String]
    }

    private struct Response: Decodable {
        let embeddings: [[Double]]
    }

    public func embed(texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = baseURL.appendingPathComponent("api/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, input: texts))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EmbeddingError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        var floatEmbeddings: [[Float]] = []
        floatEmbeddings.reserveCapacity(decoded.embeddings.count)
        for vector in decoded.embeddings {
            guard vector.count == dimension else { throw EmbeddingError.dimensionMismatch }
            var floats = vector.map { Float($0) }
            VectorMath.normalize(&floats)
            floatEmbeddings.append(floats)
        }
        return floatEmbeddings
    }
}
