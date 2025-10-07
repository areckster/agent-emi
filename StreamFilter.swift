//
//  StreamFilter.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//


import Foundation

/// Splits a streaming byte stream into visible tokens and <think> tokens.
/// Robust against chunk boundaries around the tags.
final class StreamFilter {
    private var buffer = ""
    private var inThink = false
    private var inToolCall = false
    private var inToolResult = false

    func feed(
        _ chunk: String,
        onVisible: (String) -> Void,
        onThink: (String) -> Void,
        onToolCall: ((String) -> Void)? = nil,
        onToolResult: ((String) -> Void)? = nil
    ) {
        buffer += chunk
        while !buffer.isEmpty {
            if inThink {
                if let range = buffer.range(of: "</think>") {
                    let part = String(buffer[..<range.lowerBound])
                    if !part.isEmpty { onThink(part) }
                    buffer.removeSubrange(..<range.upperBound)
                    inThink = false
                } else {
                    onThink(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            } else if inToolCall {
                if let range = buffer.range(of: "</tool_call>") {
                    let part = String(buffer[..<range.lowerBound])
                    if !part.isEmpty { onToolCall?(part) }
                    buffer.removeSubrange(..<range.upperBound)
                    inToolCall = false
                } else {
                    if !buffer.isEmpty { onToolCall?(buffer) }
                    buffer.removeAll(keepingCapacity: true)
                }
            } else if inToolResult {
                if let range = buffer.range(of: "</tool_result>") {
                    let part = String(buffer[..<range.lowerBound])
                    if !part.isEmpty { onToolResult?(part) }
                    buffer.removeSubrange(..<range.upperBound)
                    inToolResult = false
                } else {
                    if !buffer.isEmpty { onToolResult?(buffer) }
                    buffer.removeAll(keepingCapacity: true)
                }
            } else {
                // Find the next opening tag among <think>, <tool_call>, <tool_result>
                let nextThink = buffer.range(of: "<think>")?.lowerBound
                let nextToolCall = buffer.range(of: "<tool_call>")?.lowerBound
                let nextToolResult = buffer.range(of: "<tool_result")?.lowerBound // may include name="..."

                // Choose earliest index if any
                let candidates = [nextThink, nextToolCall, nextToolResult].compactMap { $0 }
                if let earliest = candidates.min(by: { buffer.distance(from: buffer.startIndex, to: $0) < buffer.distance(from: buffer.startIndex, to: $1) }) {
                    let pre = String(buffer[..<earliest])
                    if !pre.isEmpty { onVisible(pre) }
                    buffer.removeSubrange(..<earliest)
                    if buffer.hasPrefix("<think>") {
                        buffer.removeFirst("<think>".count)
                        inThink = true
                    } else if buffer.hasPrefix("<tool_call>") {
                        buffer.removeFirst("<tool_call>".count)
                        inToolCall = true
                    } else if buffer.hasPrefix("<tool_result") {
                        // Skip any attributes up to the closing '>'
                        if let closeIdx = buffer.firstIndex(of: ">") {
                            buffer.removeSubrange(..<buffer.index(after: closeIdx))
                        } else {
                            // malformed; break to wait for more input
                            break
                        }
                        inToolResult = true
                    }
                } else {
                    onVisible(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
    }

    func flush(
        onVisible: (String) -> Void,
        onThink: (String) -> Void,
        onToolCall: ((String) -> Void)? = nil,
        onToolResult: ((String) -> Void)? = nil
    ) {
        if !buffer.isEmpty {
            if inThink { onThink(buffer) }
            else if inToolCall { onToolCall?(buffer) }
            else if inToolResult { onToolResult?(buffer) }
            else { onVisible(buffer) }
            buffer.removeAll()
        }
        inThink = false; inToolCall = false; inToolResult = false
    }
}
