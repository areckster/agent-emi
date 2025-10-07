import XCTest
@testable import MemoryEngine

final class MemoryEngineTests: XCTestCase {
    func testCosineCorrectness() async throws {
        let provider = MockEmbeddingProvider(dimension: 3)
        let clock = ManualClock(now: DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 1, day: 1, hour: 12).date!)
        let engine = try await makeEngine(provider: provider, clock: clock)
        await engine.recordShortTerm("Discuss astronomy homework", role: .user, tags: ["school", "astronomy"])
        let firstId = try await engine.commitEpisodeIfNeeded()!
        await engine.recordShortTerm("Study workflow planning", role: .user, tags: ["workflow"])
        let secondId = try await engine.commitEpisodeIfNeeded()!
        await engine.recordShortTerm("Prepare for history quiz", role: .user, tags: ["school", "history"])
        let thirdId = try await engine.commitEpisodeIfNeeded()!
        let storedTexts: [Int: String] = [
            firstId: "user: Discuss astronomy homework",
            secondId: "user: Study workflow planning",
            thirdId: "user: Prepare for history quiz"
        ]

        let query = "astronomy homework plan"
        let results = try await engine.retrieveContext(for: query, limit: 3)
        XCTAssertEqual(results.count, 3)
        let queryVector = try await provider.embed(texts: [query]).first!
        var maxDot: Double = -Double.infinity
        var maxId: Int = -1
        for result in results {
            guard let text = storedTexts[result.id] else { continue }
            let memoryVector = try await provider.embed(texts: [text]).first!
            let dot = zip(queryVector, memoryVector).map(*).reduce(0, +)
            if let similarity = result.reasons.first(where: { $0.label == "similarity" })?.score {
                XCTAssertEqual(similarity, Double(dot), accuracy: 1e-5)
            }
            if Double(dot) > maxDot {
                maxDot = Double(dot)
                maxId = result.id
            }
        }
        var expectedBestId = firstId
        var expectedBestDot = -Double.infinity
        for (id, text) in storedTexts {
            let vector = try await provider.embed(texts: [text]).first!
            let dot = Double(zip(queryVector, vector).map(*).reduce(0, +))
            if dot > expectedBestDot {
                expectedBestDot = dot
                expectedBestId = id
            }
        }
        XCTAssertEqual(maxId, expectedBestId)
    }

    func testAssociativeDrift() async throws {
        let provider = MockEmbeddingProvider(dimension: 4)
        let clock = ManualClock(now: Date())
        let engine = try await makeEngine(provider: provider, clock: clock)
        await engine.setDriftProbability(1.0)

        await engine.recordShortTerm("Reminder about assignment deadline", role: .user, tags: ["school"])
        _ = try await engine.commitEpisodeIfNeeded()!
        await engine.recordShortTerm("Personal assignment mantra deadline teacher expects research", role: .user, tags: [])
        let driftId = try await engine.commitEpisodeIfNeeded()!

        let results = try await engine.retrieveContext(for: "How is the project going?", limit: 2)
        XCTAssertTrue(results.count >= 2)
        XCTAssertTrue(results.contains(where: { $0.id == driftId }))
    }

    func testNeighborExpansionIncludesLinkedMemory() async throws {
        let provider = MockEmbeddingProvider(dimension: 4)
        let clock = ManualClock(now: Date())
        let engine = try await makeEngine(provider: provider, clock: clock)

        await engine.recordShortTerm("Study workflow plan", role: .user, tags: ["school", "workflow"])
        let id1 = try await engine.commitEpisodeIfNeeded()!
        await engine.recordShortTerm("Bootes constellation notes", role: .user, tags: ["astronomy"])
        let id2 = try await engine.commitEpisodeIfNeeded()!
        try await engine.addAssociativeEdge(src: id1, dst: id2, weight: 0.6)

        let results = try await engine.retrieveContext(for: "Need a study workflow", limit: 2)
        XCTAssertTrue(results.contains(where: { $0.id == id2 }))
        let neighbor = results.first(where: { $0.id == id2 })
        XCTAssertTrue(neighbor?.reasons.contains(where: { $0.label == "neighbor_edge" }) ?? false)
    }

    func testSleepConsolidationCreatesSemanticMemories() async throws {
        let provider = MockEmbeddingProvider(dimension: 6)
        let baseDate = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 2, day: 1, hour: 23, minute: 30).date!
        let clock = ManualClock(now: baseDate)
        var configuration = EngineConfiguration()
        configuration.sleepWindowStart = "00:00"
        configuration.sleepWindowEnd = "23:59"
        let engine = try await makeEngine(provider: provider, clock: clock, configuration: configuration)

        for theme in ["physics", "astronomy", "literature", "history", "math"] {
            for index in 0..<100 {
                await engine.recordShortTerm("\(theme) concept #\(index)", role: .user, tags: [theme])
                _ = try await engine.commitEpisodeIfNeeded()
            }
        }

        try await engine.nightlyConsolidate(budgetSeconds: 30)
        let procedural = try await engine.listProceduralRules()
        XCTAssertTrue(procedural.isEmpty)
        let memories = try await engine.retrieveContext(for: "astronomy overview", limit: 8)
        XCTAssertTrue(memories.contains(where: { $0.kind == .semantic }))
    }

    func testBootesStyleRecall() async throws {
        let provider = MockEmbeddingProvider(dimension: 6)
        let clock = ManualClock(now: Date())
        let engine = try await makeEngine(provider: provider, clock: clock)

        try await engine.upsertProceduralRule("Use ACE format, keep sentences tight.", tags: ["ACE", "school"])
        await engine.recordShortTerm("Studied Bootes constellation assignment for astronomy class and workflow reminders from the teacher", role: .user, tags: ["school", "astronomy", "Bootes"])
        let bootId = try await engine.commitEpisodeIfNeeded()!
        await engine.recordShortTerm("Group project workflow planning", role: .user, tags: ["school", "workflow"])
        let workflowId = try await engine.commitEpisodeIfNeeded()!
        try await engine.addAssociativeEdge(src: bootId, dst: workflowId, weight: 0.5)

        await engine.setDriftProbability(1.0)
        let results = try await engine.retrieveContext(for: "How do I improve my assignment workflow?", limit: 4)
        let proceduralMatches = results.contains { $0.kind == .procedural || $0.textSnippet.contains("ACE") }
        XCTAssertTrue(proceduralMatches)
        let bootesMatches = results.contains { memory in
            memory.textSnippet.localizedCaseInsensitiveContains("Bootes") || memory.tags.contains { $0.caseInsensitiveCompare("Bootes") == .orderedSame }
        }
        XCTAssertTrue(bootesMatches)
    }

    // MARK: - Helpers

    private func makeEngine(provider: MockEmbeddingProvider, clock: ManualClock, configuration: EngineConfiguration = EngineConfiguration()) async throws -> MemoryEngine {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        return try await MemoryEngine(dbURL: url, embedding: provider, configuration: configuration, clock: clock, nowProvider: { clock.currentDate }, logger: .init(label: "test"))
    }
}

final class MockEmbeddingProvider: EmbeddingProvider {
    let dimension: Int
    private var cache: [String: [Float]] = [:]

    init(dimension: Int) {
        self.dimension = dimension
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        return texts.map { text in
            if let existing = cache[text] {
                return existing
            }
            var vector = [Float](repeating: 0, count: dimension)
            let scalars = Array(text.lowercased().unicodeScalars)
            for (index, scalar) in scalars.enumerated() {
                let bucket = index % dimension
                vector[bucket] += Float(scalar.value % 97)
            }
            VectorMath.normalize(&vector)
            cache[text] = vector
            return vector
        }
    }
}

final class ManualClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Instant.Duration

    private let base: Instant
    private var offset: Duration
    private let startDate: Date

    init(now: Date) {
        let continuous = ContinuousClock()
        base = continuous.now
        let diff = now.timeIntervalSince(Date())
        offset = .seconds(diff)
        startDate = Date()
    }

    var now: Instant { base.advanced(by: offset) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let duration = now.duration(to: deadline)
        if duration > .zero {
            try await Task.sleep(for: duration)
        }
    }

    func advance(by duration: Duration) {
        offset += duration
    }

    var currentDate: Date {
        let components = offset.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return startDate.addingTimeInterval(seconds + attoseconds)
    }
}
