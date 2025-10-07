import Foundation
import OrderedCollections

public enum MemoryKind: String, Codable, CaseIterable {
    case episodic
    case semantic
    case procedural
}

public enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

public struct MemoryItem: Identifiable, Codable {
    public let id: Int
    public let kind: MemoryKind
    public let text: String
    public let tags: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let importance: Double
    public let sentiment: Double?
    public let recencyBias: Double
    public let meta: [String: AnyCodable]

    public init(
        id: Int,
        kind: MemoryKind,
        text: String,
        tags: [String],
        createdAt: Date,
        updatedAt: Date,
        importance: Double,
        sentiment: Double?,
        recencyBias: Double,
        meta: [String: AnyCodable]
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.importance = importance
        self.sentiment = sentiment
        self.recencyBias = recencyBias
        self.meta = meta
    }
}

public struct RetrievedMemory: Identifiable, Codable {
    public struct Reason: Codable {
        public let label: String
        public let score: Double

        public init(label: String, score: Double) {
            self.label = label
            self.score = score
        }
    }

    public let id: Int
    public let kind: MemoryKind
    public let textSnippet: String
    public let tags: [String]
    public let activation: Double
    public let reasons: [Reason]
    public let citation: String?

    public init(
        id: Int,
        kind: MemoryKind,
        textSnippet: String,
        tags: [String],
        activation: Double,
        reasons: [Reason],
        citation: String?
    ) {
        self.id = id
        self.kind = kind
        self.textSnippet = textSnippet
        self.tags = tags
        self.activation = activation
        self.reasons = reasons
        self.citation = citation
    }
}

public struct ShortTermMessage: Codable, Hashable {
    public let text: String
    public let role: MessageRole
    public let timestamp: Date
    public let tags: [String]

    public init(text: String, role: MessageRole, timestamp: Date, tags: [String]) {
        self.text = text
        self.role = role
        self.timestamp = timestamp
        self.tags = tags
    }
}

public struct EngineConfiguration: Codable, Equatable {
    public var recencyHalfLifeDays: Double
    public var driftProbability: Double
    public var neighborEdgeThreshold: Double
    public var similarityThreshold: Double
    public var sleepWindowStart: String
    public var sleepWindowEnd: String
    public var sleepBudgetSecondsPerTick: TimeInterval

    public init(
        recencyHalfLifeDays: Double = 14,
        driftProbability: Double = 0.03,
        neighborEdgeThreshold: Double = 0.2,
        similarityThreshold: Double = 0.35,
        sleepWindowStart: String = "23:00",
        sleepWindowEnd: String = "06:00",
        sleepBudgetSecondsPerTick: TimeInterval = 60
    ) {
        self.recencyHalfLifeDays = recencyHalfLifeDays
        self.driftProbability = driftProbability
        self.neighborEdgeThreshold = neighborEdgeThreshold
        self.similarityThreshold = similarityThreshold
        self.sleepWindowStart = sleepWindowStart
        self.sleepWindowEnd = sleepWindowEnd
        self.sleepBudgetSecondsPerTick = sleepBudgetSecondsPerTick
    }
}

public struct AnyCodable: Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type")
            throw EncodingError.invalidValue(value, context)
        }
    }
}
