//
//  UIComponents.swift
//  agent-beta
//
//  Created by a reck on 9/30/25.
//

import SwiftUI
import AppKit

// Removed custom button styles; using native bordered/borderedProminent styles to match macOS

// Glass card container with rounded corners, thin material, quiet stroke, and inner highlight
struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let contentPadding: EdgeInsets?
    var backgroundOpacity: Double?
    @ViewBuilder let content: Content
    
    init(cornerRadius: CGFloat = LG.radius,
         contentPadding: EdgeInsets? = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
         backgroundOpacity: Double? = nil,
         @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.contentPadding = contentPadding
        self.backgroundOpacity = backgroundOpacity
        self.content = content()
    }
    
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Make cards 5% less transparent (more opaque) than the main background
        let base = AppEnv.prefs?.chatBackgroundOpacity ?? 0.92
        let glassOpacity = min(1.0, (backgroundOpacity ?? (base + 0.05)))
        Group {
            if let pad = contentPadding {
                content.padding(pad)
            } else {
                content
            }
        }
        .background(
            shape.fill(.ultraThinMaterial).opacity(glassOpacity)
        )
        .glassEffect(.regular, in: shape)
        .overlay(shape.stroke(LG.stroke, lineWidth: 1))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }
}

// Small icon button wrapper (labels should be used elsewhere per spec; kept for attach in composer)
struct IconButton: View {
    let system: String
    var size: CGFloat = 28
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .imageScale(.medium)
                .frame(width: size, height: size)
        }
        .buttonStyle(.borderless)
    }
}

// Glass circle used behind the send icon
struct GlassCircle: View {
    var size: CGFloat
    var body: some View {
        // Circle glass also tracks 5% less transparency than background
        let base = AppEnv.prefs?.chatBackgroundOpacity ?? 0.92
        let glassOpacity = min(1.0, base + 0.05)
        Group {
            Circle()
                .fill(.ultraThinMaterial)
                .opacity(glassOpacity)
                .background(
                    Circle().fill(Color.clear)
                )
                .glassEffect(.regular, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

struct SidebarRowButton: View {
    let title: String
    let systemName: String
    var selected: Bool = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .frame(height: 34)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? LG.quartz(0.24)
                         : (hovered ? LG.quartz(0.16) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if selected { Rectangle().fill(LG.accent).frame(width: 2) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// All components adhere to the minimal spec and Apple-native guidelines.
