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

    private let toolSpec = "Use web_search for anything time-sensitive, 'latest', news, specs, products, errors."
    private let filter = StreamFilter()
    private var cancellables = Set<AnyCancellable>()
    private var mlxEngine: MLXEngine?
    private var mlxEngineModelPath: String = ""
    private let contextWindowTokens: Int = 8192 // conservative default for small local models

    // MARK: Public orchestration
    func generateWithToolsStreaming(
        prefs: AppPrefs,
        history: [ChatMessage],
        forceSearchIfUserAsked: Bool,
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
        self.streamedToolCallAccum = ""
        self.didPruneUserEcho = false
        self.isSearching = false
        self.justCompletedMessageID = nil
        self.usedSearchThisAnswer = false
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
                if let tool = self.extractToolCall(from: out1) ?? (forceSearchIfUserAsked ? self.makeToolCallFromUser(history: history) : nil),
                   tool.tool == "web_search" {
                    onEvent(.toolStarted("web_search"))
                    self.statusLine = "Searching…"
                    self.isSearching = true
                    self.usedSearchThisAnswer = true
                    WebSearchService.shared.web_search(
                        query: tool.args.query,
                        k: tool.args.k ?? 5,
                        summarize: tool.args.summarize ?? true,
                        previewChars: tool.args.preview_chars ?? 2000,
                        progress: { ev in
                            DispatchQueue.main.async {
                                switch ev {
                                case let .opened(t, u, h):
                                    self.visitedSites.append((t,u,h))
                                    onEvent(.siteOpened(title: t, url: u, host: h))
                                case .status(let s):
                                    self.statusLine = s
                                    onEvent(.status(s))
                                }
                            }
                        },
                        completion: { wsResult in
                            DispatchQueue.main.async {
                                if self.cancelled { self.finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion); return }
                                switch wsResult {
                                case .failure(let err):
                                    onEvent(.toolFinished("web_search"))
                                    self.statusLine = "Search failed"
                                    self.isSearching = false
                                    // Show error banner using existing system (UI manages dismissal timing)
                                    let msg: String
                                    if prefs.showDetailedErrors {
                                        msg = "Web search failed for query \"\(tool.args.query)\" (DuckDuckGo). Details: \(err.localizedDescription). Tips: check your internet connection or try again shortly. The assistant will continue without sources."
                                    } else {
                                        msg = "Web search failed. Continuing without sources."
                                    }
                                    self.lastError = msg
                                    // Continue anyway; model will admit insufficiency
                                    // Reset visible stream for second pass to avoid mixing partial text
                                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                                    let extendedRaw = trimmed + [
                                        ChatMessage(role: .assistant, text: "<tool_call>{\"tool\":\"web_search\",\"args\":{\"query\":\"\(tool.args.query)\"}}</tool_call>"),
                                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">{\"ok\":false,\"query\":\"\(tool.args.query)\",\"source\":\"error\",\"results\":[],\"previews\":[],\"summaries\":[],\"summarized\":false}</tool_result>")
                                    ]
                                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                                case .success(let payload):
                                    onEvent(.toolFinished("web_search"))
                                    self.isSearching = false
                                    let encoded = self.encodeSearchPayloadCompacted(payload)
                                    // Reset visible stream for second pass to avoid mixing partial text
                                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                                    let extendedRaw = trimmed + [
                                        ChatMessage(role: .assistant, text: "<tool_call>{\"tool\":\"web_search\",\"args\":{\"query\":\"\(tool.args.query)\",\"k\":\(tool.args.k ?? 5),\"summarize\":true,\"preview_chars\":\(tool.args.preview_chars ?? 2000)}}</tool_call>"),
                                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">\(encoded)</tool_result>")
                                    ]
                                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                                }
                            }
                        }
                    )
                } else if out1.range(of: "<tool_call", options: .caseInsensitive) != nil || out1.range(of: "web_search", options: .caseInsensitive) != nil {
                    // Heuristic fallback: model attempted a tool call but JSON was malformed
                    onEvent(.toolStarted("web_search"))
                    self.statusLine = "Searching…"
                    self.isSearching = true
                    self.usedSearchThisAnswer = true
                    let lastUserQ = history.last(where: { $0.role == .user })?.text ?? ""
                    let fallback = self.makeToolCallFromUser(history: history) ?? ToolCall(tool: "web_search", args: .init(query: lastUserQ, k: 5, summarize: true, preview_chars: 2000))
                    WebSearchService.shared.web_search(
                        query: fallback.args.query,
                        k: fallback.args.k ?? 5,
                        summarize: fallback.args.summarize ?? true,
                        previewChars: fallback.args.preview_chars ?? 2000,
                        progress: { ev in
                            DispatchQueue.main.async {
                                switch ev {
                                case let .opened(t, u, h):
                                    self.visitedSites.append((t,u,h))
                                    onEvent(.siteOpened(title: t, url: u, host: h))
                                case .status(let s):
                                    self.statusLine = s
                                    onEvent(.status(s))
                                }
                            }
                        },
                        completion: { wsResult in
                            DispatchQueue.main.async {
                                if self.cancelled { self.finish(.failure(RunnerError.processFailed("Cancelled")), prefs: prefs, completion: completion); return }
                                switch wsResult {
                                case .failure:
                                    onEvent(.toolFinished("web_search"))
                                    self.isSearching = false
                                    // Continue without sources
                                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                                    let extendedRaw = trimmed + [
                                        ChatMessage(role: .assistant, text: "<tool_call>{\"tool\":\"web_search\",\"args\":{\"query\":\"\(fallback.args.query)\"}}</tool_call>"),
                                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">{\"ok\":false,\"query\":\"\(fallback.args.query)\",\"source\":\"error\",\"results\":[],\"previews\":[],\"summaries\":[],\"summarized\":false}</tool_result>")
                                    ]
                                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                                case .success(let payload):
                                    onEvent(.toolFinished("web_search"))
                                    self.isSearching = false
                                    let encoded = self.encodeSearchPayloadCompacted(payload)
                                    self.visibleStreamRaw = ""; self.streamingVisible = ""; self.streamedToolCallAccum = ""
                                    let extendedRaw = trimmed + [
                                        ChatMessage(role: .assistant, text: "<tool_call>{\"tool\":\"web_search\",\"args\":{\"query\":\"\(fallback.args.query)\",\"k\":\(fallback.args.k ?? 5),\"summarize\":true,\"preview_chars\":\(fallback.args.preview_chars ?? 2000)}}</tool_call>"),
                                        ChatMessage(role: .assistant, text: "<tool_result name=\"web_search\">\(encoded)</tool_result>")
                                    ]
                                    let extended = self.trimHistoryToBudget(prefs: prefs, reasoning: prefs.reasoningEffort, toolSpec: self.toolSpec, history: extendedRaw)
                                    self.secondPass(prefs: prefs, extendedHistory: extended, onEvent: onEvent, completion: completion)
                                }
                            }
                        }
                    )
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
            self.lastError = message
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
    private func extractToolCall(from text: String) -> ToolCall? {
        let trimmedAccum = streamedToolCallAccum.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAccum.isEmpty {
            if let obj = decodeToolCall(from: trimmedAccum) { return obj }
        }
        // Prefer explicit tag
        if let r = text.range(of: #"<tool_call>([\s\S]*?)</tool_call>"#, options: .regularExpression) {
            let body = String(text[r])
                .replacingOccurrences(of: "<tool_call>", with: "")
                .replacingOccurrences(of: "</tool_call>", with: "")
            if let obj = decodeToolCall(from: body) { return obj }
        }
        return nil
    }

    private func decodeToolCall(from raw: String) -> ToolCall? {
        // Strict JSON first
        if let d = raw.data(using: .utf8), let obj = try? JSONDecoder().decode(ToolCall.self, from: d) { return obj }
        // Lenient normalization: single quotes, trailing commas, camelCase keys
        var s = raw
        s = s.replacingOccurrences(of: #"'"#, with: "\"")
        s = s.replacingOccurrences(of: "\"previewChars\"", with: "\"preview_chars\"")
        s = s.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        if let d2 = s.data(using: .utf8), let obj2 = try? JSONDecoder().decode(ToolCall.self, from: d2) { return obj2 }
        // Minimal regex to salvage query (required)
        func captureQuery(_ str: String) -> String? {
            if let r = str.range(of: #"\"query\"\s*:\s*\"([^\"]{1,512})\""#, options: .regularExpression) {
                let match = String(str[r])
                if let qStart = match.firstIndex(of: "\"") {
                    let tail = match[match.index(after: qStart)...]
                    if let qEnd = tail.firstIndex(of: "\"") { return String(tail[..<qEnd]) }
                }
            }
            if let r2 = str.range(of: #"'query'\s*:\s*'([^']{1,512})'"#, options: .regularExpression) {
                let match = String(str[r2])
                if let qStart = match.firstIndex(of: "'") {
                    let tail = match[match.index(after: qStart)...]
                    if let qEnd = tail.firstIndex(of: "'") { return String(tail[..<qEnd]) }
                }
            }
            return nil
        }
        if let q = captureQuery(raw) {
            var kVal: Int? = nil
            if let kr = raw.range(of: #"\"k\"\s*:\s*([0-9]{1,3})"#, options: .regularExpression) {
                let frag = String(raw[kr])
                if let n = Int(frag.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { kVal = n }
            }
            var pcVal: Int? = nil
            if let pr = raw.range(of: #"(preview_chars|previewChars)\"?\s*:\s*([0-9]{2,5})"#, options: .regularExpression) {
                let frag = String(raw[pr])
                if let n = Int(frag.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) { pcVal = n }
            }
            return ToolCall(tool: "web_search", args: .init(query: q, k: kVal, summarize: nil, preview_chars: pcVal))
        }
        return nil
    }

    private func makeToolCallFromUser(history: [ChatMessage]) -> ToolCall? {
        guard let lastUser = history.last(where: { $0.role == .user }) else { return nil }
        let q = lastUser.text
        let hints = ["latest", "today", "news", "price", "spec", "release", "who is", "define", "error", "how to"]
        let asked = hints.contains { q.lowercased().contains($0) }
        if asked {
            return ToolCall(tool: "web_search", args: .init(query: q, k: 5, summarize: true, preview_chars: 2000))
        }
        return nil
    }

    private func cleanVisible(_ raw: String) -> String {
        Sanitizer.sanitizeLLM(raw)
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
            debug: payload.debug
        )
        return encode(minimal)
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
