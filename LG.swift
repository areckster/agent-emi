import SwiftUI

// Liquid Glass token shim. Tries to mirror LiquidGlassDocs tokens; falls back to local defaults.
enum LG {
    // Theme-aware tokens
    static var bg: Color { palette.bg }
    static var panel: Color { palette.panel }
    static var stroke: Color { palette.stroke }
    static var text: Color { palette.text }
    static var textSecondary: Color { palette.textSecondary }
    static var accent: Color { palette.accent }
    static var ring: Color { color(hex: 0x4C8DFF, alpha: 0.33) }
    static let radius: CGFloat = 12

    static var backgroundGradientStart: Color { palette.bgStart }
    static var backgroundGradientEnd: Color { palette.bgEnd }

    static var material: Material { .ultraThinMaterial }
    static var thinMaterial: Material { .thinMaterial }

    static func quartz(_ opacity: Double) -> Color { Color.white.opacity(opacity) }

    private struct Palette {
        var bg: Color, panel: Color, stroke: Color, text: Color, textSecondary: Color, accent: Color, bgStart: Color, bgEnd: Color
    }
    private static var palette: Palette {
        // Single theme: monoDark
        return palettes.monoDark
    }
    private struct Palettes { let monoDark: Palette }
    private static let palettes: Palettes = {
        let monoDark = Palette(
            bg: color(hex: 0x0B0B0C), panel: color(hex: 0x121212), stroke: Color.white.opacity(0.10),
            text: color(hex: 0xEDEEEF), textSecondary: color(hex: 0xB6BBC2), accent: color(hex: 0x9AA4B2),
            bgStart: color(hex: 0x0B0B0C), bgEnd: color(hex: 0x151515)
        )
        return Palettes(monoDark: monoDark)
    }()

    private static func color(hex: Int, alpha: Double = 1.0) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
