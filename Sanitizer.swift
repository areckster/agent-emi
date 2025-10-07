//
//  Sanitizer.swift
//  agent-beta
//
//  Created by agent on 10/2/25.
//

import Foundation

/// Utilities to sanitize large language model output for safe UI rendering.
enum Sanitizer {
    private static let rolePattern = try! NSRegularExpression(pattern: "^(?i)(user|assistant|system)\\b.*$", options: [.anchorsMatchLines])
    private static let metaPatterns: [NSRegularExpression] = {
        return [
            try! NSRegularExpression(pattern: "(?i)^You are Agent Lux.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Follow the PRIVATE POLICY.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Reasoning effort.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Tools available:.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Tool protocol:.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Then WAIT.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^After tool_result.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^When current information is needed.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Wait for <tool_result.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Use web_search for anything.*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^Only include \"query\" and optional \"top_k\".*$", options: [.anchorsMatchLines]),
            try! NSRegularExpression(pattern: "(?i)^\\[\\[policy.*\\]\\]$", options: [.anchorsMatchLines])
        ]
    }()

    private static let guidancePatterns: [NSRegularExpression] = {
        [
            "(?im)^When responding, begin with <think>.*$",
            "(?im)^Keep the <think>.*$",
            "(?im)^Always include the <think>.*$",
            "(?im)^In the <think>.*$",
            "(?im)^Produce exactly one <think>.*$",
            "(?im)^Immediately after </think>.*$",
            "(?im)^Do not expose .*<think>.*$",
            "(?im)^Before answering, think privately inside <think>.*$",
            "(?im)^Only include your final answer outside of <think>.*$"
        ].map { pattern in try! NSRegularExpression(pattern: pattern, options: []) }
    }()

    private static let cliInstructionPatterns: [NSRegularExpression] = {
        [
            "(?i)^- Press Return to return control to the AI\\.$",
            "(?i)^- To return control without starting a new line, end your input with '/'\\.$",
            "(?i)^- If you want to submit another line, end your input with '\\\\'\\.$",
            "(?i)^- Not using system message\\. To change it, set a different value via -sys PROMPT$"
        ].map { pattern in try! NSRegularExpression(pattern: pattern, options: []) }
    }()

    private static let chatmlTokens: [String] = [
        "<|im_start|>assistant",
        "<|im_start|>user",
        "<|im_start|>system",
        "<|im_start|>",
        "<|im_end|>"
    ]

    private static let policySentinels: [String] = ["[[POLICY_START]]", "[[POLICY_END]]"]
    private static let policyBlockRegex = #"\[\[POLICY_START\]\][\s\S]*?\[\[POLICY_END\]\]"#

    private static func shouldDropLine(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let fullRange = NSRange(location: 0, length: (trimmed as NSString).length)
        if rolePattern.firstMatch(in: trimmed, options: [], range: fullRange) != nil { return true }
        for pattern in metaPatterns {
            if pattern.firstMatch(in: trimmed, options: [], range: fullRange) != nil { return true }
        }
        for pattern in guidancePatterns {
            if pattern.firstMatch(in: trimmed, options: [], range: fullRange) != nil { return true }
        }
        for pattern in cliInstructionPatterns {
            if pattern.firstMatch(in: trimmed, options: [], range: fullRange) != nil { return true }
        }
        return false
    }

    /// Returns only the assistant's content, removing any scaffolding like role labels
    /// (user/assistant/system), debug headers (Reasoning effort/Tools available/Then WAIT),
    /// and trimming whitespace. Also auto-closes unclosed code fences and limits blank lines.
    static func sanitizeLLM(_ raw: String) -> String {
        if raw.isEmpty { return raw }

        // Normalize line endings
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // Remove any leaked private <think> content if present in final visible text
        text = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?think>"#, with: "", options: .regularExpression)

        for token in chatmlTokens {
            text = text.replacingOccurrences(of: token, with: "")
        }
        for sentinel in policySentinels { text = text.replacingOccurrences(of: sentinel, with: "") }
        // Remove any leaked private policy block wholesale if it appears in output
        text = text.replacingOccurrences(of: policyBlockRegex, with: "", options: .regularExpression)

        // Strip everything before the last standalone line "assistant"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.lowercased() == "assistant" { start = i + 1 }
        }
        var selected: [String] = Array(lines.dropFirst(start))

        // Remove any lines that start with role labels or meta headers
        selected.removeAll(where: shouldDropLine)

        text = selected.joined(separator: "\n")

        // Strip <think> and tool tags if they slipped through
        text = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?tool_call>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"</?tool_result.*?>"#, with: "", options: .regularExpression)

        // Remove any leaked system guidance lines about reasoning tags
        for pattern in guidancePatterns {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }

        // Limit consecutive blank lines to max 1
        text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)

        // Remove trailing blank-only lines at end
        var endLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = endLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            endLines.removeLast()
        }
        text = endLines.joined(separator: "\n")

        // Remove trivial heading lines like **Response** or **Final answer:** at the top
        let headingPatterns = [
            #"(?im)^(\*\*)?(response|final answer|answer)(:)?(\*\*)?\s*$\n?"#
        ]
        for pat in headingPatterns {
            text = text.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }

        // Auto-close unclosed triple backtick code fences
        let fenceCount = text.components(separatedBy: "```").count - 1
        if fenceCount % 2 == 1 {
            if !text.hasSuffix("\n") { text.append("\n") }
            text.append("```")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes prompt scaffolding while retaining any <think> content so the streaming view
    /// can show reasoning without duplicating system/tool directives.
    static func stripPromptArtifactsPreservingThink(_ raw: String) -> String {
        if raw.isEmpty { return raw }

        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")

        // Remove ChatML role markers; they are never user-visible
        for token in chatmlTokens {
            text = text.replacingOccurrences(of: token, with: "")
        }
        for sentinel in policySentinels { text = text.replacingOccurrences(of: sentinel, with: "") }
        text = text.replacingOccurrences(of: policyBlockRegex, with: "", options: .regularExpression)

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        lines.removeAll(where: shouldDropLine)

        // Collapse redundant blank lines introduced by removals
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankRun += 1
                if blankRun <= 2 { collapsed.append("") }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }

        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitizes the reasoning stream while keeping genuine plan content.
    static func sanitizeThink(_ raw: String) -> String {
        if raw.isEmpty { return raw }

        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // Remove any explicit think tags if present
        text = text.replacingOccurrences(of: #"</?think>"#, with: "", options: .regularExpression)
        for sentinel in policySentinels { text = text.replacingOccurrences(of: sentinel, with: "") }
        text = text.replacingOccurrences(of: policyBlockRegex, with: "", options: .regularExpression)
        // Strip tool tags and content if any leaked into <think>
        text = text.replacingOccurrences(of: #"<tool_call>[\s\S]*?</tool_call>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<tool_result[^>]*>[\s\S]*?</tool_result>"#, with: "", options: .regularExpression)
        // Remove ChatML tokens if present
        for token in chatmlTokens { text = text.replacingOccurrences(of: token, with: "") }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll(where: shouldDropLine)

        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blankRun += 1
                if blankRun <= 1 { collapsed.append("") }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }

        // Heuristic: drop leading noise (punctuation-only or very short echoes)
        func isNoiseLine(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return true }
            // Only treat punctuation-only lines as noise; do not drop short, meaningful lines
            if t.range(of: #"^[\p{Punct}\s]+$"#, options: .regularExpression) != nil { return true }
            return false
        }
        var pruned = collapsed
        var dropCount = 0
        while let first = pruned.first, isNoiseLine(first), dropCount < 8 {
            pruned.removeFirst(); dropCount += 1
        }

        return pruned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Lightweight self-check (only used for manual sanity if invoked)
@discardableResult
func _sanitizerSelfTest() -> Bool {
    let input = """
    user system You are a helpful assistant
    Reasoning effort: medium Tools available...
    Then WAIT for...
    user write an essay...

    assistant
    Why Cats Are the Best Animal*
    From the ancient world...
    """
    let out = Sanitizer.sanitizeLLM(input)
    let expectedPrefix = "Why Cats Are the Best Animal*\nFrom the ancient world..."
    return out.hasPrefix(expectedPrefix)
}
