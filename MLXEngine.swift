//
//  MLXEngine.swift
//  agent-beta
//
//  Compile-safe MLX engine wrapper. This file avoids referencing MLXLLM symbols
//  that may not exist in your linked version to eliminate "cannot find type" errors.
//  Once MLXLLM APIs are confirmed (model loader + streaming generator), replace
//  the stream() implementation with the concrete calls.
//

import Foundation

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

actor MLXEngine {
    struct Config: Equatable {
        var modelURL: URL
        var stop: [String] = ["<|im_end|>", "<|endoftext|>"]
        var temperature: Double = 0.3
        var topP: Double = 0.9
        var maxNewTokens: Int = 1024
    }

    private var cfg: Config
    init(cfg: Config) { self.cfg = cfg }
    func updateConfig(_ cfg: Config) { self.cfg = cfg }

#if canImport(MLXLLM)
    // Cache a loaded container so we don't reload every call
    private var cachedContainer: ModelContainer?
    private var cachedModelKey: String = ""

    private func ensureModelContainer() async throws -> ModelContainer {
        // Note: MLXChatExample uses registry-based configs. Here we pick a default
        // small model from the registry to keep things simple.
        // If you prefer a specific model, swap the configuration symbol below.
        let key = "registry:qwen3_4b_4bit"
        if let c = cachedContainer, cachedModelKey == key { return c }

        // Keep GPU memory modest
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

        let container = try await LLMModelFactory.shared.loadContainer(
            hub: .default,
            configuration: LLMRegistry.qwen3_4b_4bit
        ) { _ in }

        cachedContainer = container
        cachedModelKey = key
        return container
    }
#endif

    // Streaming API. Uses MLX when available, otherwise falls back to a diagnostic.
    func stream(
        prompt: String,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        stop: [String]? = nil
    ) async throws -> AsyncStream<String> {
        #if canImport(MLXLLM)
        let t = temperature ?? cfg.temperature
        let _ = topP ?? cfg.topP
        let maxNew = maxTokens ?? cfg.maxNewTokens

        // Lazily ensure the model is ready
        let container = try await ensureModelContainer()

        return AsyncStream<String> { continuation in
            Task {
                do {
                    let genStream: AsyncStream<Generation> = try await container.perform { (context: ModelContext) in
                        // For text-only we can pass a single user message
                        let chat: [Chat.Message] = [
                            .init(role: .user, content: prompt, images: [], videos: [])
                        ]
                        let userInput = UserInput(chat: chat)

                        let prepared = try await context.processor.prepare(input: userInput)
                        let params = GenerateParameters(maxTokens: maxNew, temperature: Float(t))
                        return try MLXLMCommon.generate(input: prepared, parameters: params, context: context)
                    }

                    for await ev in genStream {
                        if Task.isCancelled { break }
                        switch ev {
                        case .chunk(let s):
                            if !s.isEmpty { continuation.yield(s) }
                        case .info(_):
                            // Ignore metrics in this bridge
                            break
                        case .toolCall(_):
                            // Tool calls are not surfaced yet; LLMRunner’s heuristics still work
                            break
                        }
                    }
                } catch {
                    continuation.yield("[MLX error] \(error.localizedDescription)")
                }
                continuation.finish()
            }
        }
        #else
        let message = "MLX engine integration pending. Please update MLX frameworks for streaming. Model path: \(cfg.modelURL.path)"
        return AsyncStream { continuation in
            continuation.yield(message)
            continuation.finish()
        }
        #endif
    }
}

