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
        case .dynamic:
            return Color(nsColor: nsColor)
        }
    }

    /// The same color for AppKit drawing, such as a menu bar title.
    var nsColor: NSColor {
        switch self {
        case .system(let semantic):
            return semantic.nsColor
        case .dynamic(let light, let dark):
            return NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return (isDark ? dark : light).nsColor
            }
        }
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

    /// White or near-black, whichever gives the higher contrast against this fill.
    var legibleForeground: RGBA {
        contrast(against: Self.white) >= contrast(against: Self.nearBlack) ? Self.white : Self.nearBlack
    }

    static let white = RGBA(1, 1, 1)
    /// #141414 — the relative luminance crossover against this ink sits at ≈0.195, not the visual midpoint.
    static let nearBlack = RGBA(0.08, 0.08, 0.08)

    /// WCAG relative luminance in [0, 1]; used to pick a legible foreground on a colored fill.
    var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// Max-min RGB spread — a cheap saturation proxy, near zero for greys.
    var chroma: Double { Swift.max(r, g, b) - Swift.min(r, g, b) }

    /// WCAG contrast ratio, 1 (identical) to 21 (black on white), between two opaque tokens.
    func contrast(against other: RGBA) -> Double {
        let (high, low) = (Swift.max(relativeLuminance, other.relativeLuminance),
                           Swift.min(relativeLuminance, other.relativeLuminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// WCAG AA for small text.
    static let textContrastMinimum = 4.5

    func blended(toward target: RGBA, amount: Double) -> RGBA {
        RGBA(r + (target.r - r) * amount, g + (target.g - g) * amount, b + (target.b - b) * amount, a)
    }

    /// Moved toward black or white, whichever the backdrop isn't, by the smallest amount that clears `textContrastMinimum`.
    func legible(on backdrop: RGBA) -> RGBA {
        guard contrast(against: backdrop) < Self.textContrastMinimum else { return self }
        let target = backdrop.relativeLuminance > relativeLuminance ? RGBA(0, 0, 0) : RGBA(1, 1, 1)
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if blended(toward: target, amount: mid).contrast(against: backdrop) >= Self.textContrastMinimum {
                high = mid
            } else {
                low = mid
            }
        }
        return blended(toward: target, amount: high)
    }

    /// Hue (0–360) and saturation/value from HSV, so a fill can be darkened without shifting its hue.
    private var hsv: (h: Double, s: Double, v: Double) {
        let maxC = Swift.max(r, g, b), minC = Swift.min(r, g, b)
        let delta = maxC - minC
        let v = maxC
        let s = maxC == 0 ? 0 : delta / maxC
        guard delta > 0 else { return (0, s, v) }
        var h: Double
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, v)
    }

    /// The inverse of `hsv`: rebuilds an opaque color from hue/saturation/value.
    private static func fromHSV(h: Double, s: Double, v: Double) -> RGBA {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let parts: (Double, Double, Double)
        switch h {
        case 0..<60: parts = (c, x, 0)
        case 60..<120: parts = (x, c, 0)
        case 120..<180: parts = (0, c, x)
        case 180..<240: parts = (0, x, c)
        case 240..<300: parts = (x, 0, c)
        default: parts = (c, 0, x)
        }
        return RGBA(parts.0 + m, parts.1 + m, parts.2 + m)
    }

    /// White ink by default: darkens this fill (same hue/saturation) until white clears AA, unless that costs more than `maxCost` of its own value (Amber and its neighbours), in which case near-black inks the fill unchanged.
    func solvedForOnAccent(maxCost: Double = 0.26) -> (fill: RGBA, ink: RGBA) {
        let opaque = RGBA(r, g, b, 1)
        if opaque.contrast(against: Self.white) >= Self.textContrastMinimum {
            return (opaque, Self.white)
        }
        let (h, s, v) = hsv
        guard v > 0 else { return (opaque, Self.nearBlack) }
        var low = 0.0
        var high = v
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if RGBA.fromHSV(h: h, s: s, v: mid).contrast(against: Self.white) >= Self.textContrastMinimum {
                low = mid
            } else {
                high = mid
            }
        }
        guard (v - low) / v <= maxCost else { return (opaque, Self.nearBlack) }
        return (RGBA.fromHSV(h: h, s: s, v: low), Self.white)
    }

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
/// Only `textPrimary` still uses one: every other token needs a value the app can measure.
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

    var nsColor: NSColor {
        switch self {
        case .primary: return .labelColor
        case .secondary: return .secondaryLabelColor
        case .red: return .systemRed
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
    /// Neutrals shared by every preset: the dark surfaces sit above the window's #1E1E1E so a raised card reads raised, and textSecondary is fixed because .secondary is 3.95 on white.
    static let sharedNeutrals = (
        canvas: ThemeColor.dynamic(light: RGBA(0.972, 0.972, 0.970), dark: RGBA(0.098, 0.098, 0.098)),
        surface: ThemeColor.dynamic(light: RGBA(1, 1, 1), dark: RGBA(0.157, 0.157, 0.157)),
        surfaceElevated: ThemeColor.dynamic(light: RGBA(0.945, 0.945, 0.945), dark: RGBA(0.196, 0.196, 0.196)),
        divider: ThemeColor.dynamic(light: RGBA(0, 0, 0, 0.08), dark: RGBA(1, 1, 1, 0.08)),
        textSecondary: ThemeColor.dynamic(light: RGBA(0.412, 0.412, 0.412), dark: RGBA(0.63, 0.63, 0.63)),
        success: ThemeColor.uniform(RGBA(0.32, 0.74, 0.42)),
        warning: ThemeColor.uniform(RGBA(0.95, 0.66, 0.20)),
        // `Color.red`'s two resolved values, spelled out so derived text doesn't wait for a drawing appearance.
        danger: ThemeColor.dynamic(light: RGBA(1.0, 0.220, 0.235), dark: RGBA(1.0, 0.259, 0.271))
    )

    /// Recolors only the accent, keeping the shared neutrals, so switching accent never moves a contrast ratio.
    static func accented(_ accent: ThemeColor) -> ThemePalette {
        ThemePalette(
            accent: accent,
            canvas: sharedNeutrals.canvas,
            surface: sharedNeutrals.surface,
            surfaceElevated: sharedNeutrals.surfaceElevated,
            divider: sharedNeutrals.divider,
            textPrimary: .system(.primary),
            textSecondary: sharedNeutrals.textSecondary,
            success: sharedNeutrals.success,
            warning: sharedNeutrals.warning,
            danger: sharedNeutrals.danger
        )
    }

    /// How much accent a live readout's fill carries; opaque, so its text clears AA wherever it lands.
    static let accentWashOpacity = 0.15

    var accentWash: ThemeColor {
        let tint = accent.appearanceVariants
        let behind = surface.appearanceVariants
        return .dynamic(
            light: tint.light.blended(toward: behind.light, amount: 1 - Self.accentWashOpacity),
            dark: tint.dark.blended(toward: behind.dark, amount: 1 - Self.accentWashOpacity)
        )
    }

    /// The opaque fill every surface draws under `onAccent`. Matched against Sage by accent value, not stored, so a custom palette never keeps Sage's fill after its own accent changes.
    var accentFill: ThemeColor {
        accent == ThemePreset.sage.accent ? Self.sageAccentFill : solvedAccent.fill
    }

    /// The ink `accentFill` was solved for, alongside it so the two can't disagree.
    var onAccent: ThemeColor {
        accent == ThemePreset.sage.accent ? .uniform(.white) : solvedAccent.ink
    }

    private var solvedAccent: (fill: ThemeColor, ink: ThemeColor) {
        let variants = accent.appearanceVariants
        let light = variants.light.solvedForOnAccent()
        let dark = variants.dark.solvedForOnAccent()
        return (.dynamic(light: light.fill, dark: dark.fill), .dynamic(light: light.ink, dark: dark.ink))
    }

    private static let sageAccentFill = ThemeColor.dynamic(light: RGBA(0.290, 0.439, 0.337), dark: RGBA(0.373, 0.490, 0.408))
    private static let sageAccentInk = ThemeColor.dynamic(light: RGBA(0.247, 0.376, 0.282), dark: RGBA(0.663, 0.761, 0.651))

    /// The accent as small text on a surface: legible on the card fill, the accent wash, and the darkest material chrome composites to (#E5E5E7 light / #2C2B2A dark — no token matches it).
    var accentInk: ThemeColor {
        accent == ThemePreset.sage.accent
            ? Self.sageAccentInk
            : accent.legibleText(on: surfaceElevated).legibleText(on: accentWash).legibleText(on: Self.chromeMaterial)
    }

    private static let chromeMaterial = ThemeColor.dynamic(light: RGBA(0.898, 0.898, 0.906), dark: RGBA(0.173, 0.169, 0.165))

    /// Red, green and amber as small text — the raw system red only reaches 3.7 on a card, green was under AA in light mode.
    var dangerText: ThemeColor { danger.legibleText(on: surfaceElevated) }
    var successText: ThemeColor { success.legibleText(on: surfaceElevated) }
    var warningText: ThemeColor { warning.legibleText(on: surfaceElevated) }

    /// A status colour's chip: the wash `accentWash` puts under accent text, over a card, and the tint made legible on it.
    func statusChip(_ tint: ThemeColor) -> (fill: ThemeColor, text: ThemeColor) {
        let front = tint.appearanceVariants
        let behind = surfaceElevated.appearanceVariants
        let fill = ThemeColor.dynamic(
            light: front.light.blended(toward: behind.light, amount: 1 - Self.accentWashOpacity),
            dark: front.dark.blended(toward: behind.dark, amount: 1 - Self.accentWashOpacity)
        )
        return (fill, tint.legibleText(on: fill))
    }

    /// `dangerText` pinned to its dark value, for chrome that paints its own dark scrim regardless of appearance.
    var dangerOnDark: ThemeColor { .uniform(dangerText.appearanceVariants.dark) }

    /// Active-segment highlight tint: the accent, unless it's too grey to stand out (Mono) — then azure.
    var highlight: ThemeColor { accent.asHighlight }
}

extension ThemeColor {
    /// Darkened or lightened per appearance until small text on `backdrop` clears AA there.
    func legibleText(on backdrop: ThemeColor) -> ThemeColor {
        let tint = appearanceVariants
        let behind = backdrop.appearanceVariants
        return .dynamic(
            light: tint.light.legible(on: behind.light),
            dark: tint.dark.legible(on: behind.dark)
        )
    }

    /// The light and dark values behind this color; a system color answers with one value for both.
    var appearanceVariants: (light: RGBA, dark: RGBA) {
        switch self {
        case .dynamic(let light, let dark):
            return (light, dark)
        case .system(let semantic):
            let resolved = RGBA(semantic.color)
            return (resolved, resolved)
        }
    }

    /// Below this RGB chroma a colour reads as grey, not a tint — Mono 0.035–0.047, Sage ink 0.110–0.129.
    private static let highlightChromaFloor = 0.08
    private static let highlightFallback = RGBA(0.30, 0.56, 0.98)

    /// True when this color is saturated enough to read as a tint on text rather than as lighter body text.
    var readsAsTint: Bool {
        let variants = appearanceVariants
        return min(variants.light.chroma, variants.dark.chroma) >= Self.highlightChromaFloor
    }

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

/// The built-in accents, in the order the Customization pane's swatch row shows them: the default first.
enum ThemePreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case sage
    case slate
    case terracotta
    case blue
    case teal
    case indigo
    case mint
    case purple
    case pink
    case yellow
    case graphite

    /// What the app paints with until somebody stores a choice: the brand colour on the icon and the site.
    static let defaultPreset: ThemePreset = .sage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sage: return "Sage"
        case .slate: return "Slate"
        case .terracotta: return "Terracotta"
        case .blue: return "Ocean"
        case .teal: return "Sea"
        case .indigo: return "Indigo"
        case .mint: return "Forest"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .yellow: return "Amber"
        case .graphite: return "Mono"
        }
    }

    var localizedLabel: LocalizedStringKey { LocalizedStringKey(label) }

    var accent: ThemeColor {
        switch self {
        case .sage: return .dynamic(light: RGBA(0.36, 0.53, 0.42), dark: RGBA(0.55, 0.72, 0.60))
        case .slate: return .dynamic(light: RGBA(0.33, 0.45, 0.62), dark: RGBA(0.52, 0.64, 0.80))
        case .terracotta: return .dynamic(light: RGBA(0.78, 0.42, 0.25), dark: RGBA(0.93, 0.58, 0.41))
        case .blue: return .uniform(RGBA(0.20, 0.49, 0.96))
        case .teal: return .dynamic(light: RGBA(0.13, 0.52, 0.58), dark: RGBA(0.33, 0.70, 0.76))
        case .indigo: return .dynamic(light: RGBA(0.35, 0.34, 0.84), dark: RGBA(0.49, 0.48, 0.93))
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
    /// The palette with one token set from an editor well, alpha included, for both appearances.
    func setting(_ keyPath: WritableKeyPath<ThemePalette, ThemeColor>, to color: Color) -> ThemePalette {
        var palette = self
        palette[keyPath: keyPath] = .uniform(RGBA(color))
        return palette
    }

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
            danger: sharedNeutrals.danger
        )
    }
}
