//
//  HubApi+Default.swift
//  agent-beta
//
//  Provides a default Hub cache/download location compatible with MLX examples.
//

import Foundation
#if canImport(Hub)
@preconcurrency import Hub

extension HubApi {
    #if os(macOS)
    static let `default`: HubApi = {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads")
        return HubApi(downloadBase: base.appending(path: "huggingface"))
    }()
    #else
    static let `default`: HubApi = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return HubApi(downloadBase: base.appending(path: "huggingface"))
    }()
    #endif
}
#endif
