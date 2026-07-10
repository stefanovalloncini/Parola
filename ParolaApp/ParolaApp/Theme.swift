import SwiftUI
import AppKit

/// An sRGB color with separate light/dark values, or a reference to a system semantic color.
/// `color` resolves through a dynamic `NSColor` so a single value repaints when the effective
/// appearance flips, without any view reading `colorScheme`.
enum ThemeColor: Sendable, Codable, Equatable {
    case dynamic(light: RGBA, dark: RGBA)
    case system(SystemColor)

    static func uniform(_ rgba: RGBA) -> ThemeColor { .dynamic(light: rgba, dark: rgba) }

    var color: Color {
        switch self {
        case .system(let semantic):
            return semantic.color
        case .dynamic(let light, let dark):
            return Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return (isDark ? dark : light).nsColor
            })
        }
    }

    /// White or near-black, chosen per appearance for legibility on top of this color.
    var legibleForeground: Color {
        Color(nsColor: NSColor(name: nil) { [self] appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base: RGBA = switch self {
            case .dynamic(let light, let dark): isDark ? dark : light
            case .system(let semantic): RGBA(semantic.color)
            }
            return base.relativeLuminance > 0.55
                ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
                : .white
        })
    }
}

struct RGBA: Sendable, Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    /// WCAG relative luminance in [0, 1]; used to pick a legible foreground on a colored fill.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Max-min RGB spread — a cheap saturation proxy, near zero for greys.
    var chroma: Double { Swift.max(r, g, b) - Swift.min(r, g, b) }

    /// Parses `#RRGGBB` / `#RRGGBBAA` (with or without the leading `#`). Returns nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
    }

    var hex: String {
        let ri = Int((r * 255).rounded()), gi = Int((g * 255).rounded()), bi = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }
}

/// System semantic colors that adapt to appearance and accessibility settings on their own.
/// Used for text so presets keep the OS's contrast/Increase-Contrast behavior.
enum SystemColor: String, Sendable, Codable {
    case primary
    case secondary
    case red

    var color: Color {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .red: return .red
        }
    }
}

/// The full set of element colors one theme drives. Non-color design tokens (spacing, radius,
/// fonts) and intrinsic colors (speaker palette, confidence, waveform) live on `DS`, not here.
struct ThemePalette: Sendable, Codable, Equatable {
    var accent: ThemeColor
    var canvas: ThemeColor
    var surface: ThemeColor
    var surfaceElevated: ThemeColor
    var divider: ThemeColor
    var textPrimary: ThemeColor
    var textSecondary: ThemeColor
    var success: ThemeColor
    var warning: ThemeColor
    var danger: ThemeColor
}

extension ThemePalette {
    /// Neutrals shared by every built-in preset, matching the values the asset catalog shipped.
    static let sharedNeutrals = (
        canvas: ThemeColor.dynamic(light: RGBA(0.972, 0.972, 0.970), dark: RGBA(0.039, 0.039, 0.039)),
        surface: ThemeColor.dynamic(light: RGBA(1, 1, 1), dark: RGBA(0.086, 0.086, 0.086)),
        surfaceElevated: ThemeColor.dynamic(light: RGBA(0.945, 0.945, 0.945), dark: RGBA(0.118, 0.118, 0.118)),
        divider: ThemeColor.dynamic(light: RGBA(0, 0, 0, 0.08), dark: RGBA(1, 1, 1, 0.08)),
        success: ThemeColor.uniform(RGBA(0.32, 0.74, 0.42)),
        warning: ThemeColor.uniform(RGBA(0.95, 0.66, 0.20))
    )

    /// A preset that recolors only the accent, keeping the system text colors and shared neutrals
    /// — preserving today's behavior where switching accent doesn't touch backgrounds or contrast.
    static func accented(_ accent: ThemeColor) -> ThemePalette {
        ThemePalette(
            accent: accent,
            canvas: sharedNeutrals.canvas,
            surface: sharedNeutrals.surface,
            surfaceElevated: sharedNeutrals.surfaceElevated,
            divider: sharedNeutrals.divider,
            textPrimary: .system(.primary),
            textSecondary: .system(.secondary),
            success: sharedNeutrals.success,
            warning: sharedNeutrals.warning,
            danger: .system(.red)
        )
    }

    /// Active-segment highlight tint: the accent, unless it's too grey to stand out (Mono) — then azure.
    var highlight: ThemeColor { accent.asHighlight }
}

extension ThemeColor {
    /// Accents below this RGB chroma read as grey and fail as a highlight; substitute azure instead.
    private static let highlightChromaFloor = 0.15
    private static let highlightFallback = RGBA(0.30, 0.56, 0.98)

    var asHighlight: ThemeColor {
        func legible(_ rgba: RGBA) -> RGBA {
            rgba.chroma >= Self.highlightChromaFloor ? rgba : Self.highlightFallback
        }
        switch self {
        case .system:
            return self
        case .dynamic(let light, let dark):
            return .dynamic(light: legible(light), dark: legible(dark))
        }
    }
}

enum ThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case terracotta
    case blue
    case mint
    case purple
    case pink
    case yellow
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terracotta: return "Terracotta"
        case .blue: return "Ocean"
        case .mint: return "Forest"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .yellow: return "Amber"
        case .graphite: return "Mono"
        }
    }

    var accent: ThemeColor {
        switch self {
        case .terracotta: return .dynamic(light: RGBA(0.78, 0.42, 0.25), dark: RGBA(0.93, 0.58, 0.41))
        case .blue: return .uniform(RGBA(0.20, 0.49, 0.96))
        case .mint: return .uniform(RGBA(0.20, 0.70, 0.55))
        case .purple: return .uniform(RGBA(0.55, 0.35, 0.84))
        case .pink: return .uniform(RGBA(0.92, 0.38, 0.62))
        case .yellow: return .uniform(RGBA(0.96, 0.78, 0.20))
        case .graphite: return .uniform(RGBA(0.42, 0.43, 0.47))
        }
    }

    var palette: ThemePalette { .accented(accent) }
}

/// Which palette is active: a built-in preset or a fully custom one.
enum ThemeSelection: Equatable, Sendable {
    case preset(ThemePreset)
    case custom(ThemePalette)

    var palette: ThemePalette {
        switch self {
        case .preset(let preset): return preset.palette
        case .custom(let palette): return palette
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent), Double(ns.alphaComponent))
    }
}

extension ThemeColor {
    /// A single editable Color (the light variant for dynamic colors, resolved for system ones).
    var editableColor: Color {
        switch self {
        case .system(let semantic): return semantic.color
        case .dynamic(let light, _): return Color(nsColor: light.nsColor)
        }
    }

    /// The variant matching the given appearance, for seeding the custom-palette editor.
    func editableColor(dark: Bool) -> Color {
        switch self {
        case .system(let semantic): return semantic.color
        case .dynamic(let light, let darkVariant): return Color(nsColor: (dark ? darkVariant : light).nsColor)
        }
    }
}

extension ThemePalette {
    /// A custom palette from flat editable colors. Each token applies to both appearances;
    /// success/warning/danger keep the shared semantic defaults.
    static func custom(
        accent: Color, canvas: Color, surface: Color, surfaceElevated: Color,
        divider: Color, textPrimary: Color, textSecondary: Color
    ) -> ThemePalette {
        ThemePalette(
            accent: .uniform(RGBA(accent)),
            canvas: .uniform(RGBA(canvas)),
            surface: .uniform(RGBA(surface)),
            surfaceElevated: .uniform(RGBA(surfaceElevated)),
            divider: .uniform(RGBA(divider)),
            textPrimary: .uniform(RGBA(textPrimary)),
            textSecondary: .uniform(RGBA(textSecondary)),
            success: sharedNeutrals.success,
            warning: sharedNeutrals.warning,
            danger: .system(.red)
        )
    }
}
