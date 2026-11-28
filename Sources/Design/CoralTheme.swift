import SwiftUI

/// Exact Primer Web `coral-0` palette from Figma node `5648:19883`
/// paired with Riff 05 (`1:15607`) 3-face isometric shading math (Top 100%, Left 78%, Right 60%).
public struct RGBColor: Sendable, Hashable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(hex: UInt32) {
        self.r = Double((hex >> 16) & 0xFF) / 255.0
        self.g = Double((hex >> 8) & 0xFF) / 255.0
        self.b = Double(hex & 0xFF) / 255.0
    }

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public func scaled(_ factor: Double) -> RGBColor {
        RGBColor(
            r: min(1.0, max(0.0, r * factor)),
            g: min(1.0, max(0.0, g * factor)),
            b: min(1.0, max(0.0, b * factor))
        )
    }

    public var color: Color {
        Color(red: r, green: g, blue: b)
    }
}

public struct PrismPalette: Sendable {
    public let flat: Color
    public let top: Color
    public let left: Color
    public let right: Color
    public let raw: RGBColor

    public init(base: RGBColor) {
        self.raw = base
        self.flat = base.color
        self.top = base.color
        self.left = base.scaled(0.78).color
        self.right = base.scaled(0.60).color
    }
}

public enum CoralPalette {
    // Exact Primer Web coral-0 shades (50..900)
    public static let c50  = RGBColor(hex: 0xFFF0EB)
    public static let c100 = RGBColor(hex: 0xFFD6CC)
    public static let c200 = RGBColor(hex: 0xFFB4A1)
    public static let c300 = RGBColor(hex: 0xFD8C73)
    public static let c400 = RGBColor(hex: 0xEC6547)
    public static let c500 = RGBColor(hex: 0xC4432B)
    public static let c600 = RGBColor(hex: 0x9E2F1C)
    public static let c700 = RGBColor(hex: 0x801F0F)
    public static let c800 = RGBColor(hex: 0x691105)
    public static let c900 = RGBColor(hex: 0x510901)

    // Exact idle neutral bases from DESIGN_SPEC.md
    public static let idleLight = RGBColor(hex: 0xEFF0F1)
    public static let idleDark  = RGBColor(hex: 0x1D1A1C)

    public static func tiers(for colorScheme: ColorScheme) -> [PrismPalette] {
        if colorScheme == .dark {
            // Dark Liquid Glass: dark obsidian idle rising into luminous peach-coral peaks
            return [
                PrismPalette(base: idleDark),
                PrismPalette(base: c700),
                PrismPalette(base: c500),
                PrismPalette(base: c300),
                PrismPalette(base: c100)
            ]
        } else {
            // Light Liquid Glass (1:1 Riff 05 logic): soft light base rising into deep terracotta peaks
            return [
                PrismPalette(base: idleLight),
                PrismPalette(base: c100),
                PrismPalette(base: c200),
                PrismPalette(base: c400),
                PrismPalette(base: c600)
            ]
        }
    }

    /// Adaptive coral accent for text, icons, and active tab underlines (WCAG AA compliant in both modes).
    public static func primaryAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? c300.color : c500.color
    }

    /// Prominent filled button tint ensuring >= 5.0:1 contrast with white label text in both modes (DESIGN_SPEC.md).
    public static func prominentButtonFill(for colorScheme: ColorScheme) -> Color {
        c500.color
    }

    /// Adaptive provider accent for Claude Code (>= 4.8:1 in Light & Dark).
    public static func claudeAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? c300.color : c500.color
    }

    /// Adaptive provider accent for OpenAI Codex CLI (>= 5.0:1 in Light & Dark).
    public static func codexAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.25, green: 0.85, blue: 0.62)
            : Color(red: 0.05, green: 0.52, blue: 0.36)
    }

    /// Adaptive provider accent for Antigravity (>= 5.2:1 in Light & Dark).
    public static func agyAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.36, green: 0.74, blue: 0.98)
            : Color(red: 0.05, green: 0.43, blue: 0.76)
    }

    /// Adaptive semantic green for cache savings & ready quotas (>= 5.1:1 in Light & Dark).
    public static func cacheAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.42, green: 0.84, blue: 0.56)
            : Color(red: 0.08, green: 0.48, blue: 0.24)
    }

    public static func brightPeak(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? c100.color : c600.color
    }

    public static func curveStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? c300.color : c500.color
    }

    public static func shadowTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? c400.color.opacity(0.24) : c700.color.opacity(0.14)
    }
}

public enum AppTypography {
    public static func heroNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .default).width(.expanded)
    }

    public static func metricNumber(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default).width(.expanded)
    }

    public static func monoCaption(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }
}

/// Shared native macOS 27 card surface (16pt corner radius, semantic fill, Increase Contrast support).
public struct DashboardCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    let padding: CGFloat
    let tinted: Bool

    public init(padding: CGFloat = 16, tinted: Bool = false) {
        self.padding = padding
        self.tinted = tinted
    }

    public func body(content: Content) -> some View {
        let borderOpacity: Double = contrast == .increased ? 0.28 : (tinted ? 0.30 : 0.09)
        let borderColor = tinted
            ? CoralPalette.primaryAccent(for: colorScheme).opacity(borderOpacity)
            : Color.primary.opacity(borderOpacity)

        content
            .padding(padding)
            .background(
                tinted
                    ? AnyShapeStyle(CoralPalette.primaryAccent(for: colorScheme).opacity(colorScheme == .dark ? 0.09 : 0.06))
                    : AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.58 : 0.82))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: contrast == .increased ? 1.25 : 1)
            )
    }
}

public extension View {
    func dashboardCard(padding: CGFloat = 16, tinted: Bool = false) -> some View {
        modifier(DashboardCardModifier(padding: padding, tinted: tinted))
    }
}
