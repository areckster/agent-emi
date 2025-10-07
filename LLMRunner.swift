//
//  LLMRunner.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//

import Foundation
import Combine

enum RunnerEvent {
    case status(String)
    case toolStarted(String)
    case siteOpened(title: String, url: String, host: String)
    case toolFinished(String)
}

enum RunnerError: Error, LocalizedError {
    case invalidPaths
    case processFailed(String)
    case outputEmpty
    var errorDescription: String? {
        switch self {
        case .invalidPaths: return "MLX model folder path invalid."
        case .processFailed(let s): return "Model process failed: \(s)"
        case .outputEmpty: return "The model produced no output."
        }
    }
}

final class LLMRunner: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var streamingVisible: String = ""
    @Published var streamingThink: String = ""
    @Published var statusLine: String = ""
    @Published var visitedSites: [(String,String,String)] = [] // (title,url,host)
    @Published var lastError: String?
    @Published var isSearching: Bool = false
    @Published var lastThinkDuration: TimeInterval?
    @Published var justCompletedMessageID: UUID?
    @Published var usedSearchThisAnswer: Bool = false
    
    // MLX-only engine
    private var currentTask: Task<Void, Never>?
    private var cancelled: Bool = false
    private var streamedToolCallAccum: String = ""
    private var visibleStreamRaw: String = ""
    private var thinkStreamRaw: String = ""
    private var thinkStartedAt: Date?
    private var thinkEndedAt: Date?
    private var lastUserEcho: String = ""
    private var didPruneUserEcho: Bool = false
    private var composeVisibleDraft: String = ""
    private var lastMalformedToolCall: String?

    private let toolSpec = "Use web_search for anything time-sensitive by emitting <tool_call>{\"tool\":\"web_search\",\"args\":{\"query\":\"...\",\"top_k\":5}}</tool_call>. Do not include any other keys in args."
    private let filter = StreamFilter()
    private var cancellables = Set<AnyCancellable>()
    private var mlxEngine: MLXEngine?
    private var mlxEngineModelPath: String = ""
    private let contextWindowTokens: Int = 8192 // conservative default for small local models

    // MARK: Public orchestration
    func generateWithToolsStreaming(
        prefs: AppPrefs,
        history: [ChatMessage],
        onEvent: @escaping (RunnerEvent) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        // MLX only: require a valid MLX model folder (prefs path, bundled "mlx-q5", or App Support fallback)
        guard let modelURL = resolveModelURL(prefs: prefs) else { completion(.failure(RunnerError.invalidPaths)); return }
        ensureEngine(modelURL: modelURL, prefs: prefs)

        self.isRunning = true
        self.cancelled = false
        self.streamingVisible = ""
        self.streamingThink = ""
        self.visibleStreamRaw = ""
        self.thinkStreamRaw = ""
        self.composeVisibleDraft = ""
        self.lastThinkDuration = nil
        self.thinkStartedAt = nil
        self.thinkEndedAt = nil
        self.visitedSites.removeAll()
        self.statusLine = "Thinking…"
        self.lastError = nil
        self.streamedToolCallAccum = ""
        self.didPruneUserEcho = false
        self.isSearching = false
        self.justCompletedMessageID = nil
        self.usedSearchThisAnswer = false
        self.lastMalformedToolCall = nil
        if let lastUser = history.last(where: { $0.role == .user }) {
            let normalized = lastUser.text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            self.lastUserEcho = String(normalized.prefix(256))
        } else {
            self.lastUserEcho = ""
        }
        onEvent(.status("Thinking…"))

        // Round 1
        // Trim history to fit budget before first pass
        let trimmed = self.trimHistoryToBudget(
            prefs: prefs,
            reasoning: prefs.reasoningEffort,
            toolSpec: toolSpec,
            history: history
        )
        runOnce(
            prefs: prefs,
            prompt: PromptTemplate.buildPrompt(reasoning: prefs.reasoningEffort, toolSpec: toolSpec, history: trimmed),
            earlyStopOnToolCall: true,
            onEvent: onEvent
        ) { [weak self] r1 in
            guard let self else { return }
            // Bail out early if user cancelled mid-stream
            if self.cancelled {
                self.finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion)
                return
            }
            switch r1 {
            case .failure(let err):
                self.finish(.failure(err), prefs: prefs, completion: completion)
            case .success(let out1):
                let extraction = self.extractToolCall(from: out1)
                if let tool = extraction.call, tool.tool == "web_search" {
                    onEvent(.toolStarted("web_search"))
                    self.statusLine = "Searching…"
                    self.isSearching = true
                    let topK = tool.args.topK ?? 5
                    WebSearchService.shared.web_search(
                        query: tool.args.query,
                        topK: topK,
                        progress: { ev in
                            DispatchQueue.main.async {
                                switch ev {
                                case let .opened(t, u, h):
                                    self.visitedSites.append((t, u, h))
                                    onEvent(.siteOpened(title: t, url: u, host: h))
                                case .status(let s):
                                    self.statusLine = s
                                    onEvent(.status(s))
                                }
                            }
                        },
                        completion: { wsResult in
                            DispatchQueue.main.async {
                                if self.cancelled {
                                    self.finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion)
                                    return
                                }
                switch wsResult {
                case .failure(let err):
                    onEvent(.toolFinished("web_search"))
                    let status = self.searchStatusText(for: err, query: tool.args.query)
                    self.statusLine = status
                    onEvent(.status(status))
                    self.isSearching = false
                    let banner = self.searchErrorBanner(for: err, query: tool.args.query, prefs: prefs)
                    self.updateLastError(with: banner)
                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                    let callJSON = self.canonicalToolCallJSON(query: tool.args.query, topK: topK)
                    let failurePayload = self.encodeSearchFailurePayload(query: tool.args.query, topK: topK, error: err)
                    let extendedRaw = trimmed + [
                        ChatMessage(role: .assistant, text: "<tool_call>\(callJSON)</tool_call>"),
                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">\(failurePayload)</tool_result>")
                    ]
                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                case .success(let payload):
                                    onEvent(.toolFinished("web_search"))
                                    self.isSearching = false
                                    self.usedSearchThisAnswer = true
                                    let encoded = self.encodeSearchPayloadCompacted(payload)
                                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                                    let callJSON = self.canonicalToolCallJSON(query: tool.args.query, topK: topK)
                                    let extendedRaw = trimmed + [
                                        ChatMessage(role: .assistant, text: "<tool_call>\(callJSON)</tool_call>"),
                                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">\(encoded)</tool_result>")
                                    ]
                                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                                }
                            }
                        }
                    )
                } else if let malformed = extraction.malformed {
                    self.lastMalformedToolCall = malformed
                    self.statusLine = "Tool call malformed."
                    onEvent(.status("Tool call malformed."))
                    self.isSearching = false
                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                    let queryHint = self.normalizeQueryHint(extraction.inferredQuery ?? self.fallbackQuery(from: history))
                    let canonical = self.canonicalToolCallJSON(query: queryHint, topK: 5)
                    let payload = self.encodeMalformedToolResult(received: malformed, canonical: canonical)
                    let extendedRaw = trimmed + [
                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">\(payload)</tool_result>")
                    ]
                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                } else {
                    // No tool call → treat out1 as the answer
                    self.isSearching = false
                    let cleaned = self.cleanVisible(out1)
                    guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.finish(.failure(RunnerError.outputEmpty), prefs: prefs, completion: completion); return
                    }
                    self.finish(.success(cleaned), prefs: prefs, completion: completion)
                }
            }
        }
    }

    private func secondPass(
        prefs: AppPrefs,
        extendedHistory: [ChatMessage],
        onEvent: @escaping (RunnerEvent) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if cancelled { finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion); return }
        self.statusLine = "Composing…"
        onEvent(.status("Composing…"))
        // Trim again to include tool_result while staying under budget
        let trimmed = self.trimHistoryToBudget(
            prefs: prefs,
            reasoning: prefs.reasoningEffort,
            toolSpec: toolSpec,
            history: extendedHistory
        )
        runOnce(
            prefs: prefs,
            prompt: PromptTemplate.buildPrompt(reasoning: prefs.reasoningEffort, toolSpec: toolSpec, history: trimmed),
            earlyStopOnToolCall: false,
            onEvent: onEvent
        ) { [weak self] r2 in
            guard let self else { return }
            if self.cancelled { self.finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion); return }
            switch r2 {
            case .failure(let e): self.finish(.failure(e), prefs: prefs, completion: completion)
            case .success(let out2):
                var cleaned = self.cleanVisible(out2)
                if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Fallback to buffered compose draft if sanitizer stripped too much
                    let fallback = Sanitizer.sanitizeLLM(self.composeVisibleDraft)
                    if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cleaned = fallback
                    }
                }
                guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(.failure(RunnerError.outputEmpty), prefs: prefs, completion: completion); return
                }
                self.finish(.success(cleaned), prefs: prefs, completion: completion)
            }
        }
    }

    private func finish(_ result: Result<String, Error>, prefs: AppPrefs, completion: (Result<String, Error>) -> Void) {
        if case .failure(let e) = result {
            let message = userFacingErrorMessage(from: e, prefs: prefs)
            if let current = lastError,
               current.lowercased().contains("web search failed"),
               message == RunnerError.outputEmpty.localizedDescription {
                // Preserve the more actionable search failure message.
            } else {
                updateLastError(with: message)
            }
            // UI manages dismissal timing (hover-aware)
        }
        // Ensure visible output is tidy and no dangling buffers remain
        self.streamingVisible = Sanitizer.sanitizeLLM(self.visibleStreamRaw)
        self.streamingThink = Sanitizer.sanitizeThink(self.thinkStreamRaw)
        if let s = thinkStartedAt, let e = thinkEndedAt, e >= s {
            self.lastThinkDuration = e.timeIntervalSince(s)
        }
        self.isRunning = false
        self.statusLine = ""
        completion(result)
    }

    private func userFacingErrorMessage(from error: Error, prefs: AppPrefs) -> String {
        if prefs.showDetailedErrors { return error.localizedDescription }
        if let runnerError = error as? RunnerError {
            switch runnerError {
            case .processFailed(let reason):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.caseInsensitiveCompare("Cancelled") == .orderedSame {
                    return "Generation cancelled."
                }
                return "Model process failed. Enable detailed errors in Settings for full output."
            case .invalidPaths, .outputEmpty:
                return runnerError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    // MARK: Process (MLX engine)
    private func runOnce(
        prefs: AppPrefs,
        prompt: String,
        earlyStopOnToolCall: Bool,
        onEvent: @escaping (RunnerEvent) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let filter = self.filter
        var fullBuffer = ""
        var terminatedForToolCall = false
        var terminatedForInactivity = false
        var lastDataAt = Date()
        var inactivityTimer: DispatchSourceTimer?
        var tempVisibleBuffer = ""

        // Controls
        let tempVal = Double(samplingTemp(for: prefs.reasoningEffort)) ?? 0.7
        let maxNew = max(64, prefs.bucketedTokens())
        let stopTokens = ["<|im_end|>", "<|endoftext|>"]

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let engine = self.mlxEngine else {
                    DispatchQueue.main.async { completion(.failure(RunnerError.processFailed("Engine not initialized"))) }
                    return
                }
                let stream = try await engine.stream(
                    prompt: prompt,
                    temperature: tempVal,
                    topP: 0.9,
                    maxTokens: maxNew,
                    stop: stopTokens
                )

                for try await chunk in stream {
                    if Task.isCancelled { break }
                    lastDataAt = Date()
                    fullBuffer += chunk
                    filter.feed(
                        chunk,
                        onVisible: { vis in
                            // Do not stream final visible text to UI; always buffer
                            tempVisibleBuffer += vis
                            self.composeVisibleDraft = tempVisibleBuffer
                        },
                        onThink: { th in
                            DispatchQueue.main.async { self.appendThinkChunk(th) }
                        },
                        onToolCall: { tc in
                            self.streamedToolCallAccum += tc
                            if earlyStopOnToolCall {
                                terminatedForToolCall = true
                                self.currentTask?.cancel()
                            }
                        }
                    )
                    if earlyStopOnToolCall && fullBuffer.contains("</tool_call>") {
                        terminatedForToolCall = true
                        self.currentTask?.cancel()
                    }
                }

                DispatchQueue.main.async {
                    // Flush and finalize
                    self.filter.flush(
                        onVisible: { v in
                            // Do not stream final visible text to UI; always buffer
                            tempVisibleBuffer += v
                            self.composeVisibleDraft = tempVisibleBuffer
                        },
                        onThink: { self.appendThinkChunk($0) },
                        onToolCall: { self.streamedToolCallAccum += $0 }
                    )
                    inactivityTimer?.cancel(); inactivityTimer = nil
                    if self.cancelled {
                        completion(.failure(RunnerError.processFailed("Cancelled")))
                    } else if terminatedForToolCall {
                        completion(.success(fullBuffer))
                    } else if earlyStopOnToolCall && !terminatedForToolCall && self.streamedToolCallAccum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !tempVisibleBuffer.isEmpty { self.appendVisibleChunk(tempVisibleBuffer) }
                        completion(.success(fullBuffer))
                    } else if terminatedForInactivity {
                        completion(.success(fullBuffer))
                    } else {
                        completion(.success(fullBuffer))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    inactivityTimer?.cancel(); inactivityTimer = nil
                    if self.cancelled {
                        completion(.failure(RunnerError.processFailed("Cancelled")))
                    } else {
                        completion(.failure(RunnerError.processFailed(error.localizedDescription)))
                    }
                }
            }
        }

        // Inactivity timeout for compose pass
        if !earlyStopOnToolCall {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 2.0, repeating: 0.5)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.cancelled { return }
                let silence = Date().timeIntervalSince(lastDataAt)
                if silence > 1.5, !self.visibleStreamRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    terminatedForInactivity = true
                    self.currentTask?.cancel()
                }
            }
            inactivityTimer = timer
            timer.resume()
        }

        self.currentTask = task
    }

    // MARK: Prompt budgeting
    private func trimHistoryToBudget(
        prefs: AppPrefs,
        reasoning: ReasoningEffort,
        toolSpec: String,
        history: [ChatMessage]
    ) -> [ChatMessage] {
        // Reserve tokens for generation and slack
        let gen = max(64, prefs.bucketedTokens())
        let budget = max(1024, contextWindowTokens - gen - 256)

        guard !history.isEmpty else { return history }

        func estimateTokens(_ s: String) -> Int { max(1, (s.utf8.count + 3) / 4) }
        func promptFor(_ hist: [ChatMessage]) -> String {
            PromptTemplate.buildPrompt(reasoning: reasoning, toolSpec: toolSpec, history: hist)
        }

        // Ensure we always keep the last user message and all that follows
        if let lastUserIdx = history.lastIndex(where: { $0.role == .user }) {
            var kept = Array(history[lastUserIdx...])
            var tokens = estimateTokens(promptFor(kept))
            if tokens <= budget {
                // Try to prepend earlier messages until we hit budget
                var i = lastUserIdx - 1
                while i >= 0 {
                    let candidate = [history[i]] + kept
                    let t = estimateTokens(promptFor(candidate))
                    if t > budget { break }
                    kept = candidate
                    tokens = t
                    i -= 1
                }
            }
            return kept
        }

        // No user messages? Fall back to tail-trimming from the end while keeping at least 2 messages
        var kept = history
        var tokens = estimateTokens(promptFor(kept))
        while tokens > budget && kept.count > 2 {
            kept.removeFirst()
            tokens = estimateTokens(promptFor(kept))
        }
        return kept
    }

    

    // MARK: Control
    func stop() {
        guard isRunning else { return }
        cancelled = true
        statusLine = "Cancelling…"
        currentTask?.cancel()
    }

    private func appendVisibleChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        visibleStreamRaw += chunk
        streamingVisible = Sanitizer.sanitizeLLM(visibleStreamRaw)
    }

    private func appendThinkChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        if thinkStartedAt == nil { thinkStartedAt = Date() }
        thinkStreamRaw += chunk
        var cleaned = Sanitizer.stripPromptArtifactsPreservingThink(thinkStreamRaw)
        // Prune echoed user content from the start of <think>
        if !didPruneUserEcho, !lastUserEcho.isEmpty {
            // Prefer a direct case-insensitive match in the original cleaned text
            if let r = cleaned.range(of: lastUserEcho, options: [.caseInsensitive]) {
                // Only prune if the echo appears near the very start (avoid cutting real reasoning later)
                let startIdx = cleaned.startIndex
                let maxOffset = cleaned.index(startIdx, offsetBy: min(64, cleaned.count), limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                if r.lowerBound <= maxOffset {
                    cleaned.removeSubrange(..<r.upperBound)
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    didPruneUserEcho = true
                }
            } else {
                // Fallback: build a whitespace-tolerant regex from lastUserEcho
                let pattern = NSRegularExpression.escapedPattern(for: lastUserEcho).replacingOccurrences(of: "\\ ", with: "\\s+")
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                   let match = regex.firstMatch(in: cleaned, options: [], range: NSRange(location: 0, length: (cleaned as NSString).length)) {
                    if let rr = Range(match.range, in: cleaned) {
                        // Only prune if echo is near beginning
                        let loc = rr.lowerBound
                        let startIdx = cleaned.startIndex
                        let maxOffset = cleaned.index(startIdx, offsetBy: min(64, cleaned.count), limitedBy: cleaned.endIndex) ?? cleaned.endIndex
                        if loc <= maxOffset {
                            cleaned.removeSubrange(..<rr.upperBound)
                            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                            didPruneUserEcho = true
                        }
                    }
                }
            }
        }
        streamingThink = cleaned
        // Keep accumulating raw stream (do not overwrite with cleaned)
        thinkEndedAt = Date()
    }

    // MARK: Tool helpers
    private struct ToolCallExtraction {
        var call: ToolCall?
        var malformed: String?
        var inferredQuery: String?
    }

    private func extractToolCall(from text: String) -> ToolCallExtraction {
        let trimmedAccum = streamedToolCallAccum.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        if !trimmedAccum.isEmpty { candidates.append(trimmedAccum) }
        if let r = text.range(of: #"<tool_call>([\s\S]*?)</tool_call>"#, options: .regularExpression) {
            let body = String(text[r])
                .replacingOccurrences(of: "<tool_call>", with: "")
                .replacingOccurrences(of: "</tool_call>", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { candidates.append(body) }
        }
        for raw in candidates {
            if let obj = decodeToolCall(from: raw) {
                return ToolCallExtraction(call: obj, malformed: nil, inferredQuery: nil)
            }
        }
        if let raw = candidates.last {
            let inferred = captureQuery(from: raw)
            return ToolCallExtraction(call: nil, malformed: raw, inferredQuery: inferred)
        }
        return ToolCallExtraction(call: nil, malformed: nil, inferredQuery: nil)
    }

    private func decodeToolCall(from raw: String) -> ToolCall? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8) {
            let decoder = JSONDecoder()
            if let obj = try? decoder.decode(ToolCall.self, from: data) {
                return obj
            }
        }

        var normalized = trimmed
        normalized = normalized.replacingOccurrences(of: #"'"#, with: "\"")
        normalized = normalized.replacingOccurrences(of: "\"topK\"", with: "\"top_k\"")
        normalized = normalized.replacingOccurrences(of: "\"TopK\"", with: "\"top_k\"")
        normalized = normalized.replacingOccurrences(of: "\"k\"", with: "\"top_k\"")
        normalized = normalized.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let data = normalized.data(using: .utf8) {
            let decoder = JSONDecoder()
            if let obj = try? decoder.decode(ToolCall.self, from: data) {
                return obj
            }
        }

        guard let query = captureQuery(from: normalized) else { return nil }
        if let toolName = captureToolName(from: normalized), toolName.lowercased() != "web_search" {
            return nil
        }
        let topK = captureTopK(from: normalized)
        return ToolCall(tool: "web_search", args: .init(query: query, topK: topK))
    }

    private func captureToolName(from raw: String) -> String? {
        if let r = raw.range(of: #"\"tool\"\s*:\s*\"([^\"]{1,128})\""#, options: .regularExpression) {
            let match = String(raw[r])
            if let first = match.firstIndex(of: "\"") {
                let tail = match[match.index(after: first)...]
                if let end = tail.firstIndex(of: "\"") { return String(tail[..<end]) }
            }
        }
        if let r = raw.range(of: #"'tool'\s*:\s*'([^']{1,128})'"#, options: .regularExpression) {
            let match = String(raw[r])
            if let first = match.firstIndex(of: "'") {
                let tail = match[match.index(after: first)...]
                if let end = tail.firstIndex(of: "'") { return String(tail[..<end]) }
            }
        }
        return nil
    }

    private func captureQuery(from raw: String) -> String? {
        if let r = raw.range(of: #"\"query\"\s*:\s*\"([^\"]{1,512})\""#, options: .regularExpression) {
            let match = String(raw[r])
            if let first = match.firstIndex(of: "\"") {
                let tail = match[match.index(after: first)...]
                if let end = tail.firstIndex(of: "\"") { return String(tail[..<end]) }
            }
        }
        if let r = raw.range(of: #"'query'\s*:\s*'([^']{1,512})'"#, options: .regularExpression) {
            let match = String(raw[r])
            if let first = match.firstIndex(of: "'") {
                let tail = match[match.index(after: first)...]
                if let end = tail.firstIndex(of: "'") { return String(tail[..<end]) }
            }
        }
        return nil
    }

    private func captureTopK(from raw: String) -> Int? {
        let patterns = [
            #"top_k\"?\s*:\s*([0-9]{1,3})"#,
            #"topK\"?\s*:\s*([0-9]{1,3})"#,
            #"\bk\b\s*:\s*([0-9]{1,3})"#
        ]
        for pattern in patterns {
            if let r = raw.range(of: pattern, options: .regularExpression) {
                let frag = String(raw[r])
                let digits = frag.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if let value = Int(digits) { return value }
            }
        }
        return nil
    }

    private func fallbackQuery(from history: [ChatMessage]) -> String {
        guard let last = history.last(where: { $0.role == .user }) else { return "" }
        return last.text
    }

    private func normalizeQueryHint(_ raw: String) -> String {
        let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "USER_QUERY_HERE" }
        return String(trimmed.prefix(256))
    }

    private func canonicalToolCallJSON(query: String, topK: Int) -> String {
        let call = ToolCall(tool: "web_search", args: .init(query: query, topK: topK))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(call), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"tool\":\"web_search\",\"args\":{\"query\":\"\(query)\",\"top_k\":\(topK)}}"
    }

    private func encodeMalformedToolResult(received: String, canonical: String) -> String {
        struct Payload: Codable {
            var ok: Bool
            var error: String
            var received: String
            var expected_format: String
            var instruction: String
            var needs_retry: Bool
        }
        let trimmedReceived = String(received.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
        let payload = Payload(
            ok: false,
            error: "web_search tool call JSON malformed",
            received: trimmedReceived,
            expected_format: canonical,
            instruction: "Resend the tool_call as valid JSON exactly matching expected_format.",
            needs_retry: true
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(payload), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"ok\":false,\"error\":\"web_search tool call JSON malformed\",\"expected_format\":\"\(canonical)\",\"instruction\":\"Resend the tool_call as valid JSON exactly matching expected_format.\",\"needs_retry\":true}"
    }

    private func cleanVisible(_ raw: String) -> String {
        Sanitizer.sanitizeLLM(raw)
    }

    private func searchStatusText(for error: Error, query: String) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Search failed for \(query)"
        }
        if detail.lowercased().hasPrefix("search failed") {
            return detail
        }
        return "Search failed: \(detail)"
    }

    private func searchErrorBanner(for error: Error, query: String, prefs: AppPrefs) -> String {
        if !prefs.showDetailedErrors {
            if let stageText = stageDescription(for: error) {
                return "Web search failed during \(stageText). The assistant will continue without live sources."
            }
            return "Web search failed. The assistant will continue without live sources."
        }
        let stageText = stageDescription(for: error)
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        var pieces: [String] = []
        var base = "Web search failed for query \"\(query)\""
        if let stageText {
            base += " during \(stageText)"
        }
        pieces.append(base)
        if !detail.isEmpty {
            pieces.append("Details: \(detail)")
        }
        pieces.append("Tips: check your internet connection, wait a few seconds, or adjust the query. The assistant will continue without live sources.")
        return pieces.joined(separator: " ")
    }

    private func stageDescription(for error: Error) -> String? {
        if let searchError = error as? WebSearchError {
            switch searchError.stage {
            case "planning": return "query planning"
            case "ddg_html": return "DuckDuckGo HTML search"
            case "dedupe": return "result deduplication"
            case "rank": return "result ranking"
            case "previews": return "preview fetching"
            case "summarize": return "content summarization"
            case "summarize_fallback": return "summarization fallback"
            case "complete": return "result assembly"
            default: return searchError.stage.replacingOccurrences(of: "_", with: " ")
            }
        }
        if let ws = error as? WSError {
            switch ws {
            case .httpStatus: return "HTTP fetch"
            case .transport: return "network request"
            case .parsing: return "parsing"
            }
        }
        return nil
    }

    private func searchDebugInfo(from error: Error, query: String, topK: Int) -> [String: String] {
        var info: [String: String] = [
            "query": query,
            "top_k": String(topK)
        ]
        if let searchError = error as? WebSearchError {
            info.merge(searchError.debug) { current, _ in current }
        } else if let ws = error as? WSError {
            info.merge(ws.debugInfo) { current, _ in current }
        } else {
            let ns = error as NSError
            info["error_domain"] = ns.domain
            info["error_code"] = String(ns.code)
            let desc = ns.localizedDescription
            if !desc.isEmpty {
                info["error_description"] = desc
            }
        }
        return info
    }

    private func encodeSearchPayloadCompacted(_ p: WSPayload) -> String {
        func encode(_ payload: WSPayload) -> String {
            let enc = JSONEncoder(); enc.outputFormatting = [.withoutEscapingSlashes]
            let data = try? enc.encode(payload)
            return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        }
        // Initial encode
        var payload = p
        var s = encode(payload)
        // Hard cap: keep payload under ~10k chars to respect context budget
        let limit = 10000
        if s.count <= limit { return s }
        // Step 1: trim previews to top 3 and 600 chars each
        if !payload.previews.isEmpty {
            payload.previews = Array(payload.previews.prefix(3)).map { String($0.prefix(600)) }
        }
        if payload.results.count > 3 { payload.results = Array(payload.results.prefix(3)) }
        s = encode(payload)
        if s.count <= limit { return s }
        // Step 2: drop previews entirely, keep summaries only
        payload.previews = []
        s = encode(payload)
        if s.count <= limit { return s }
        // Step 3: trim summaries too
        if !payload.summaries.isEmpty {
            payload.summaries = Array(payload.summaries.prefix(3)).map { String($0.prefix(400)) }
        }
        s = encode(payload)
        if s.count <= limit { return s }
        // Final fallback: only include minimal fields
        let minimal = WSPayload(
            ok: payload.ok,
            query: payload.query,
            source: payload.source,
            results: Array(payload.results.prefix(2)),
            previews: [],
            summaries: [],
            recommendedOpen: payload.recommendedOpen,
            queryHints: Array(payload.queryHints.prefix(2)),
            summarized: payload.summarized,
            debug: payload.debug,
            error: payload.error
        )
        return encode(minimal)
    }

    private func encodeSearchFailurePayload(query: String, topK: Int, error: Error) -> String {
        struct FailurePayload: Codable {
            var ok: Bool
            var query: String
            var source: String
            var error: String
            var debug: [String: String]
            var fallback: String
            var tips: [String]
            var stage: String?
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let debug = searchDebugInfo(from: error, query: query, topK: topK)
        let payload = FailurePayload(
            ok: false,
            query: query,
            source: "error",
            error: message.isEmpty ? "Search failed without further detail." : message,
            debug: debug,
            fallback: "Respond using existing knowledge; do not rely on live web sources.",
            tips: [
                "Check network connectivity.",
                "Retry after waiting a few seconds.",
                "Adjust the query wording if automated scraping was blocked."
            ],
            stage: stageDescription(for: error)
        )
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(payload), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{\"ok\":false,\"source\":\"error\",\"error\":\"Search failed\"}"
    }

    private func updateLastError(with message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let current = lastError, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if current.contains(trimmed) { return }
            self.lastError = current + "\n" + trimmed
        } else {
            self.lastError = trimmed
        }
    }

    private func samplingTemp(for effort: ReasoningEffort) -> String {
        switch effort {
        case .low: return "0.3"
        case .medium: return "0.7"
        case .high: return "0.9"
        }
    }

    // MARK: MLX helpers
    private func resolveModelURL(prefs: AppPrefs) -> URL? {
        // Prefer bundled folder reference "mlx-q5" (app ships with model)
        if let url = try? ModelLocation.bundled(name: "mlx-q5").url() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        // Try Application Support default
        if let url = try? ModelLocation.appSupport(relative: "agent-lux/Models/DistilQwen3-4B-mlx-q5").url() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        // If MLX backend is available, allow proceeding even without a concrete path
        #if canImport(MLXLLM)
        // Use Caches directory as a benign, existing directory token
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return caches
        }
        #endif
        return nil
    }

    private func ensureEngine(modelURL: URL, prefs: AppPrefs) {
        // Recreate only if path changed
        if let _ = mlxEngine, mlxEngineModelPath == modelURL.path { return }
        let tempVal = Double(samplingTemp(for: prefs.reasoningEffort)) ?? 0.7
        let cfg = MLXEngine.Config(
            modelURL: modelURL,
            stop: ["<|im_end|>", "<|endoftext|>"],
            temperature: tempVal,
            topP: 0.9,
            maxNewTokens: max(64, prefs.bucketedTokens())
        )
        mlxEngine = MLXEngine(cfg: cfg)
        mlxEngineModelPath = modelURL.path
    }
}
