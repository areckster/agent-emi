import Foundation
import Logging

public actor MemoryEngine {
    private var shortTerm: [ShortTermMessage] = []
    private let storage: MemoryStore
    private let graphStore: GraphStore
    private let embeddingProvider: EmbeddingProvider
    private var configuration: EngineConfiguration
    private var recencyCalculator: RecencyBiasCalculator
    private let importanceScorer = ImportanceScorer()
    private let sentimentScorer = SentimentScorer()
    private let summarizer: SemanticSummarizer
    private let logger: Logger
    private let nowProvider: () -> Date

    public init(
        dbURL: URL,
        embedding: EmbeddingProvider,
        summarizer: SemanticSummarizer = PassthroughSummarizer(),
        configuration: EngineConfiguration = EngineConfiguration(),
        clock: any Clock<Duration> = ContinuousClock(),
        nowProvider: (() -> Date)? = nil,
        logger: Logger = Logger(label: "MemoryEngine")
    ) async throws {
        self.storage = try await MemoryStore(dbURL: dbURL, logger: logger)
        self.graphStore = GraphStore(storage: storage)
        self.embeddingProvider = embedding
        self.configuration = configuration
        self.recencyCalculator = RecencyBiasCalculator(halfLifeDays: configuration.recencyHalfLifeDays)
        self.summarizer = summarizer
        self.logger = logger
        if let nowProvider {
            self.nowProvider = nowProvider
        } else {
            self.nowProvider = { Date() }
        }
    }

    // MARK: - Short Term

    public func recordShortTerm(_ message: String, role: MessageRole, tags: [String]) async {
        shortTerm.append(ShortTermMessage(text: message, role: role, timestamp: now(), tags: tags))
        if shortTerm.count > 6 {
            shortTerm.removeFirst(shortTerm.count - 6)
        }
    }

    public func commitEpisodeIfNeeded() async throws -> Int? {
        guard !shortTerm.isEmpty else { return nil }
        let episode = shortTerm
        shortTerm.removeAll()
        let now = self.now()
        let text = episode.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n")
        let tags = Array(Set(episode.flatMap { $0.tags }))
        let importance = importanceScorer.score(text: text, tags: tags)
        let sentiment = sentimentScorer.sentiment(for: text)
        let recency = recencyCalculator.recencyBias(for: now, reference: now)
        var embedding = try await embeddingProvider.embed(texts: [text]).first ?? []
        VectorMath.normalize(&embedding)
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        let row = MemoryRow(
            id: 0,
            kind: .episodic,
            text: text,
            embedding: embedding,
            createdAt: now,
            updatedAt: now,
            lastAccessedAt: now,
            importance: importance,
            sentiment: sentiment,
            recencyBias: recency,
            tags: tags,
            meta: [:]
        )
        let newId = try await storage.insertMemory(row, embeddingData: data)
        try await linkAssociations(for: newId, embedding: embedding, tags: tags)
        return newId
    }

    // MARK: - Procedural

    public func upsertProceduralRule(_ text: String, tags: [String]) async throws {
        var vector: [Float]? = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            var embeddingVector = try await embeddingProvider.embed(texts: [trimmed]).first ?? []
            if !embeddingVector.isEmpty {
                VectorMath.normalize(&embeddingVector)
                vector = embeddingVector
            }
        }
        try await ProceduralRuleStore(storage: storage).upsert(text: trimmed, tags: tags, embedding: vector)
    }

    public func listProceduralRules() async throws -> [MemoryItem] {
        try await ProceduralRuleStore(storage: storage).list()
    }

    // MARK: - Retrieval

    public func retrieveContext(for query: String, limit k: Int) async throws -> [RetrievedMemory] {
        let retriever = Retriever(storage: storage, graphStore: graphStore, embedding: embeddingProvider, configuration: configuration, logger: logger)
        return try await retriever.retrieve(query: query, limit: k)
    }

    public func noteAccess(_ ids: [Int]) async {
        do {
            try await storage.updateLastAccessed(ids: ids, date: now())
        } catch {
            logger.error("failed to update access: \(error.localizedDescription)")
        }
    }

    // MARK: - Graph

    public func rebuildGraphIncremental() async throws {
        let rows = try await storage.fetchMemories(kind: [.episodic])
        for row in rows where row.embedding != nil {
            try await linkAssociations(for: row.id, embedding: row.embedding ?? [], tags: row.tags)
        }
    }

    public func addAssociativeEdge(src: Int, dst: Int, weight: Double) async throws {
        try await graphStore.upsertEdge(src: src, dst: dst, weight: weight)
    }

    public func nightlyConsolidate(budgetSeconds: TimeInterval) async throws {
        var consolidator = SleepConsolidator(
            storage: storage,
            graphStore: graphStore,
            embedding: embeddingProvider,
            summarizer: summarizer,
            configuration: configuration,
            logger: logger
        )
        try await consolidator.run(budgetSeconds: budgetSeconds, now: now())
    }

    // MARK: - Configuration

    public func setDriftProbability(_ p: Double) async {
        configuration.driftProbability = max(0, min(1, p))
    }

    public func setRecencyHalfLife(days: Double) async {
        configuration.recencyHalfLifeDays = max(1, days)
        recencyCalculator = RecencyBiasCalculator(halfLifeDays: configuration.recencyHalfLifeDays)
    }

    // MARK: - Helpers

    private func linkAssociations(for newId: Int, embedding: [Float], tags: [String]) async throws {
        let existing = try await storage.fetchMemories(kind: [.episodic, .semantic])
        let filtered = existing.filter { $0.id != newId && $0.embedding != nil }
        let vectors = filtered.map { $0.embedding ?? [] }
        let cosines = VectorMath.dotProducts(between: embedding, and: vectors)
        let threshold = configuration.similarityThreshold
        let topM = zip(filtered, cosines)
            .sorted { $0.1 > $1.1 }
            .prefix(12)
        for (row, cosineFloat) in topM {
            let cosine = Double(cosineFloat)
            guard cosine >= threshold else { continue }
            var weight = min(1.0, max(0.0, 0.5 * cosine))
            if !Set(row.tags).isDisjoint(with: tags) {
                weight = min(1.0, weight + 0.1)
            }
            try await graphStore.upsertEdge(src: newId, dst: row.id, weight: weight)
        }
    }

    private func now() -> Date {
        nowProvider()
    }
}
