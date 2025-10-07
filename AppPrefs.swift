//
//  AppPrefs.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//

import Foundation
import Combine

public enum ReasoningEffort: String, CaseIterable, Codable, Identifiable {
    case low, medium, high
    public var id: String { rawValue }
}

public enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case monoDark
    public var id: String { rawValue }
}

public enum ResponseStyle: String, CaseIterable, Codable, Identifiable {
    case friendly, concise, technical, narrative
    public var id: String { rawValue }
}

@MainActor
final class AppPrefs: ObservableObject {
    // MARK: - Published properties
    @Published var reasoningEffort: ReasoningEffort = .medium
    @Published var maxTokens: Int = 4096
    @Published var threads: Int = max(1, ProcessInfo.processInfo.processorCount / 2)
    @Published var usePTYStreaming: Bool = false
    @Published var enableDebugLogging: Bool = false
    @Published var useUltraDarkBlue: Bool = true
    @Published var showDetailedErrors: Bool = false
    @Published var progressiveRevealOnAnswer: Bool = true
    @Published var theme: AppTheme = .monoDark
    // Chat UI appearance
    @Published var chatBackgroundOpacity: Double = 0.92
    // User profile preferences
    @Published var preferredName: String = ""
    @Published var userBio: String = ""
    @Published var userProfession: String = ""
    @Published var userResponseStyle: ResponseStyle = .friendly
    // Model path preference removed; app ships with embedded models

    // MARK: - Storage
    private let prefix = "app_prefs."
    private var bag = Set<AnyCancellable>()

    init() {
        load()
        // Auto-save on any change
        objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
    }

    // MARK: - Persistence
    func load() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: key("reasoningEffort")), let val = ReasoningEffort(rawValue: raw) { reasoningEffort = val }
        let mt = d.integer(forKey: key("maxTokens")); if mt > 0 { maxTokens = mt }
        let th = d.integer(forKey: key("threads")); if th > 0 { threads = th }
        usePTYStreaming = d.bool(forKey: key("usePTYStreaming"))
        enableDebugLogging = d.bool(forKey: key("enableDebugLogging"))
        useUltraDarkBlue = d.object(forKey: key("useUltraDarkBlue")) as? Bool ?? useUltraDarkBlue
        showDetailedErrors = d.bool(forKey: key("showDetailedErrors"))
        if d.object(forKey: key("progressiveRevealOnAnswer")) != nil {
            progressiveRevealOnAnswer = d.bool(forKey: key("progressiveRevealOnAnswer"))
        }
        if let raw = d.string(forKey: key("theme")), let t = AppTheme(rawValue: raw) { theme = t }
        if d.object(forKey: key("chatBackgroundOpacity")) != nil {
            let v = d.double(forKey: key("chatBackgroundOpacity"))
            if v > 0 { chatBackgroundOpacity = max(0.6, min(1.0, v)) }
        }
        preferredName = d.string(forKey: key("preferredName")) ?? preferredName
        userBio = d.string(forKey: key("userBio")) ?? userBio
        userProfession = d.string(forKey: key("userProfession")) ?? userProfession
        if let rs = d.string(forKey: key("userResponseStyle")), let val = ResponseStyle(rawValue: rs) { userResponseStyle = val }
    }

    func save() {
        let d = UserDefaults.standard
        d.set(reasoningEffort.rawValue, forKey: key("reasoningEffort"))
        d.set(maxTokens, forKey: key("maxTokens"))
        d.set(threads, forKey: key("threads"))
        d.set(usePTYStreaming, forKey: key("usePTYStreaming"))
        d.set(enableDebugLogging, forKey: key("enableDebugLogging"))
        d.set(useUltraDarkBlue, forKey: key("useUltraDarkBlue"))
        d.set(showDetailedErrors, forKey: key("showDetailedErrors"))
        d.set(progressiveRevealOnAnswer, forKey: key("progressiveRevealOnAnswer"))
        d.set(theme.rawValue, forKey: key("theme"))
        d.set(chatBackgroundOpacity, forKey: key("chatBackgroundOpacity"))
        d.set(preferredName, forKey: key("preferredName"))
        d.set(userBio, forKey: key("userBio"))
        d.set(userProfession, forKey: key("userProfession"))
        d.set(userResponseStyle.rawValue, forKey: key("userResponseStyle"))
    }

    // MARK: - Helpers
    func bucketedTokens() -> Int {
        // Clamp to [256, 65536] and round down to nearest 256 to avoid over-asking
        let clamped = max(256, min(65536, maxTokens))
        return (clamped / 256) * 256
    }

    private func key(_ s: String) -> String { prefix + s }
}
