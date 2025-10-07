import Foundation

struct ImportanceScorer {
    func score(text: String, tags: [String]) -> Double {
        let lowered = text.lowercased()
        var score = 0.0
        let taskKeywords = ["deadline", "assignment", "due", "schedule", "plan"]
        let selfReference = ["i think", "i feel", "i am", "personally"]
        let teacherKeywords = ["teacher", "professor", "rubric", "grading"]
        let noveltyKeywords = ["new", "learned", "discovered", "research", "study"]

        for keyword in taskKeywords where lowered.contains(keyword) {
            score += 0.15
        }
        for keyword in selfReference where lowered.contains(keyword) {
            score += 0.1
        }
        for keyword in teacherKeywords where lowered.contains(keyword) {
            score += 0.1
        }
        for keyword in noveltyKeywords where lowered.contains(keyword) {
            score += 0.05
        }
        if tags.contains(where: { ["school", "assignment", "study"].contains($0.lowercased()) }) {
            score += 0.1
        }
        let logistic = 1.0 / (1.0 + exp(-4 * (score - 0.35)))
        return max(0.0, min(1.0, logistic))
    }
}

struct SentimentScorer {
    func sentiment(for text: String) -> Double? {
        let lowered = text.lowercased()
        let negative = ["frustrated", "angry", "sad", "upset", "worried", "stress"]
        let positive = ["excited", "happy", "glad", "proud", "satisfied"]
        if negative.contains(where: { lowered.contains($0) }) {
            return -0.6
        }
        if positive.contains(where: { lowered.contains($0) }) {
            return 0.6
        }
        return 0
    }
}

struct RecencyBiasCalculator {
    var halfLifeDays: Double

    init(halfLifeDays: Double) {
        self.halfLifeDays = halfLifeDays
    }

    func recencyBias(for createdAt: Date, reference: Date = Date()) -> Double {
        let tau = halfLifeDays * 24 * 60 * 60 / log(2)
        let ageSeconds = reference.timeIntervalSince(createdAt)
        guard tau > 0, ageSeconds > 0 else { return 1.0 }
        return exp(-ageSeconds / tau)
    }
}
