//
//  SummarizerEngine.swift
//  agent-beta
//
//  Small MLX LLM used to summarize fetched web pages.
//  Resets context per request for reliability.
//

import Foundation

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

actor SummarizerEngine {
    struct Config: Equatable {
        var modelURL: URL
        var temperature: Double = 0.2
        var maxNewTokens: Int = 384
        var stop: [String] = ["<|im_end|>", "<|endoftext|>"]
    }

    private var cfg: Config
    init(cfg: Config) { self.cfg = cfg }
    func updateConfig(_ cfg: Config) { self.cfg = cfg }

#if canImport(MLXLLM)
    // Cache a loaded container so we don't reload every call
    private var cachedContainer: ModelContainer?
    private var cachedKey: String = ""

    private func ensureLoaded() async throws -> ModelContainer {
        // Use a distinct registry entry if available; otherwise, re-use a small Qwen model.
        // We keep using registry-based loading to avoid brittle local-folder assumptions.
        let key = "registry:summarizer:qwen3_1_7b_4bit"
        if let c = cachedContainer, cachedKey == key { return c }

        // Keep GPU memory modest
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        // Prefer a compact model for speed; adjust if you have a custom registry.
        let container = try await LLMModelFactory.shared.loadContainer(
            hub: .default,
            configuration: LLMRegistry.qwen3_1_7b_4bit
        ) { _ in }

        cachedContainer = container
        cachedKey = key
        return container
    }
#endif

    func summarize(query: String, title: String, host: String, content: String) async throws -> String {
        #if canImport(MLXLLM)
        let container = try await ensureLoaded()
        let sys = """
        You are a precise summarizer. Produce a short, faithful summary of the provided page content.
        - Focus on facts that answer the user query: \(query)
        - Use 4–8 concise bullets.
        - Avoid speculation; do not invent details not present in the text.
        - Keep total under ~1200 characters.
        - Ensure you capture the key details from the text, ignore the noise.
        """.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fresh context per request: create a new generation from scratch.
        let chat: [Chat.Message] = [
            .init(role: .system, content: sys, images: [], videos: []),
            .init(
                role: .user,
                content: """
                Page: \(title) — \(host)
                Content:
                \(content)
                
                Task: Summarize for the query above.
                """,
                images: [], videos: []
            )
        ]

        let userInput = UserInput(chat: chat)

        let maxTokens = cfg.maxNewTokens
        let temperature = Float(cfg.temperature)

        // Run and collect full output (non-streamed for convenience here)
        let output = try await container.perform { (context: ModelContext) -> String in
            let prepared = try await context.processor.prepare(input: userInput)
            let params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
            var acc = ""
            let stream = try MLXLMCommon.generate(input: prepared, parameters: params, context: context)
            for await ev in stream {
                if case .chunk(let s) = ev { acc += s }
            }
            return acc
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        // Fallback if MLX is not linked: return the first 6 sentences as bullets
        let sentences = content.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let picks = Array(sentences.prefix(6))
        return picks.map { "- \($0)" }.joined(separator: "\n")
        #endif
    }
}

enum SummarizerResolver {
    static func defaultConfig() -> SummarizerEngine.Config? {
        // Try bundled Summarizer-mlx-q5 folder if present; otherwise fall back to caches dir token
        if let url = try? ModelLocation.bundled(name: "Summarizer-mlx-q5").url() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return .init(modelURL: url)
            }
        }
        // Application Support default location (user may have placed it here)
        if let url = try? ModelLocation.appSupport(relative: "agent-lux/Models/Summarizer-mlx-q5").url() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return .init(modelURL: url)
            }
        }
        // If not present, return a benign URL so the actor can still initialize
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let c = caches { return .init(modelURL: c) }
        return nil
    }
}

