import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

enum OrbitTheme {
    static let background = Color(hex: 0x161618)
    static let accent = Color(hex: 0xFF6B35)

    static let success = Color(hex: 0x4ADE80)
    static let warning = Color(hex: 0xFBBF24)
    static let array = Color(hex: 0x63B3ED)
    static let danger = Color(hex: 0xEF4444)

    static let textPrimary = Color.white.opacity(0.78)
    static let textSecondary = Color.white.opacity(0.50)
    static let textLabel = Color.white.opacity(0.25)
    static let textTimestamp = Color.white.opacity(0.15)
    static let divider = Color.white.opacity(0.05)
    static let mutedFill = Color.white.opacity(0.06)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if canImport(AppKit)
        if NSFont(name: "IBM Plex Mono", size: size) != nil {
            return .custom("IBM Plex Mono", size: size).weight(weight)
        }
        #endif
        return .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        #if canImport(AppKit)
        if NSFont(name: "IBM Plex Sans", size: size) != nil {
            return .custom("IBM Plex Sans", size: size).weight(weight)
        }
        #endif
        return .system(size: size, weight: weight, design: .default)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
