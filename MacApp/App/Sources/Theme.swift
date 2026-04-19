// Design tokens — accent / light+dark / density. Matches tokens.jsx from the design bundle.

import SwiftUI
import Observation

enum AccentKey: String, CaseIterable, Identifiable {
    case blue, graphite, magenta, green, orange
    var id: String { rawValue }
    var label: String {
        switch self {
        case .blue: return "Blue"
        case .graphite: return "Graphite"
        case .magenta: return "Magenta"
        case .green: return "Green"
        case .orange: return "Orange"
        }
    }
    var solid: Color {
        switch self {
        case .blue:     return Color(red: 0.00, green: 0.48, blue: 1.00)   // #007AFF
        case .graphite: return Color(red: 0.23, green: 0.23, blue: 0.24)   // #3A3A3C
        case .magenta:  return Color(red: 1.00, green: 0.18, blue: 0.57)   // #FF2D92
        case .green:    return Color(red: 0.19, green: 0.82, blue: 0.35)   // #30D158
        case .orange:   return Color(red: 1.00, green: 0.62, blue: 0.04)   // #FF9F0A
        }
    }
    var soft: Color { solid.opacity(0.14) }
    var ring: Color { solid.opacity(0.35) }
}

enum Density: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var rowPadY: CGFloat { self == .compact ? 6 : 10 }
    var thumbWidth: CGFloat { self == .compact ? 44 : 54 }
    var thumbHeight: CGFloat { self == .compact ? 62 : 78 }
    var fontTitle: CGFloat { self == .compact ? 13 : 14 }
    var fontMeta: CGFloat { self == .compact ? 11 : 12 }
    var expandedPad: CGFloat { self == .compact ? 10 : 14 }
}

@Observable
final class Tweaks {
    var accentKey: AccentKey = .blue {
        didSet { UserDefaults.standard.set(accentKey.rawValue, forKey: Self.kAccent) }
    }
    var dark: Bool = false {
        didSet { UserDefaults.standard.set(dark, forKey: Self.kDark) }
    }
    var density: Density = .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: Self.kDensity) }
    }

    var accent: AccentKey { accentKey }

    private static let kAccent = "tweaks.accent"
    private static let kDark = "tweaks.dark"
    private static let kDensity = "tweaks.density"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.kAccent),
           let a = AccentKey(rawValue: raw) { self.accentKey = a }
        if UserDefaults.standard.object(forKey: Self.kDark) != nil {
            self.dark = UserDefaults.standard.bool(forKey: Self.kDark)
        }
        if let raw = UserDefaults.standard.string(forKey: Self.kDensity),
           let d = Density(rawValue: raw) { self.density = d }
    }
}

/// Theme palette keyed on light/dark, matching the design's tokens.
struct Theme {
    let dark: Bool

    // Window background gradient
    var windowBg: LinearGradient {
        dark
            ? LinearGradient(colors: [Color(hex: 0x1C1C1E), Color(hex: 0x141416)],
                             startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: 0xEFF1F5), Color(hex: 0xE4E8EE)],
                             startPoint: .top, endPoint: .bottom)
    }
    // Chrome (titlebar, column headers, bottom bar)
    var chrome: Color {
        dark ? Color(hex: 0x26262A).opacity(0.78) : Color(hex: 0xF6F7FA).opacity(0.82)
    }
    var chromeBorder: Color {
        dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }
    var canvas: Color {
        dark ? Color(hex: 0x17171A) : Color(hex: 0xF5F6F9)
    }
    var panel: Color {
        dark ? Color(hex: 0x2C2C30).opacity(0.55) : Color.white.opacity(0.70)
    }
    var panelBorder: Color {
        dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
    var rowHover: Color { dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03) }
    var rowSelected: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05) }
    var divider: Color { dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07) }
    var text: Color { dark ? Color.white.opacity(0.92) : Color.black.opacity(0.88) }
    var textDim: Color { dark ? Color.white.opacity(0.58) : Color.black.opacity(0.56) }
    var textFaint: Color { dark ? Color.white.opacity(0.38) : Color.black.opacity(0.36) }
    var pill: Color { dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }
    var pillText: Color { dark ? Color.white.opacity(0.72) : Color.black.opacity(0.66) }

    // Chip colors for action tags (copy/transcode/skip-bitmap)
    var chipCopy: Color {
        dark ? Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.18)
             : Color(red: 0.19, green: 0.69, blue: 0.28).opacity(0.16)
    }
    var chipCopyText: Color {
        dark ? Color(hex: 0x5FE37B) : Color(hex: 0x1F7A33)
    }
    var chipTranscode: Color {
        dark ? Color(red: 1.0, green: 0.62, blue: 0.04).opacity(0.20)
             : Color(red: 0.92, green: 0.53, blue: 0.04).opacity(0.16)
    }
    var chipTranscodeText: Color {
        dark ? Color(hex: 0xFFB649) : Color(hex: 0xB25E00)
    }
    var chipSkip: Color {
        dark ? Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.18)
             : Color(red: 0.88, green: 0.20, blue: 0.16).opacity(0.14)
    }
    var chipSkipText: Color {
        dark ? Color(hex: 0xFF6A5F) : Color(hex: 0xB4261C)
    }
    // Remux = stream-copy via ffmpeg. Cheap, but not zero-cost. Blue to separate
    // from orange "transcode" (expensive) and green "copy" (nothing happens).
    var chipRemux: Color {
        dark ? Color(red: 0.38, green: 0.70, blue: 1.0).opacity(0.20)
             : Color(red: 0.00, green: 0.48, blue: 1.00).opacity(0.14)
    }
    var chipRemuxText: Color {
        dark ? Color(hex: 0x6FB4FF) : Color(hex: 0x0A5BCC)
    }

    var posterBg: LinearGradient {
        dark
            ? LinearGradient(colors: [Color(hex: 0x2A2A2E), Color(hex: 0x1E1E21)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [Color(hex: 0xE9ECF2), Color(hex: 0xD6DBE3)],
                             startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// Formatting helpers (match design's fmtSize / fmtDuration)
func fmtSizeMB(_ mb: Int) -> String {
    if mb >= 1024 { return String(format: "%.1f GB", Double(mb) / 1024.0) }
    return "\(mb) MB"
}

func fmtDuration(_ sec: Double) -> String {
    let total = Int(sec)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
