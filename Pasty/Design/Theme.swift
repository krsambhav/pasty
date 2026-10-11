import AppKit
import CoreText
import SwiftUI

/// Pasty's design tokens: shadcn/ui's "zinc" theme, rebuilt natively.
///
/// Colors are dynamic `NSColor`s, so they follow the system appearance and Pasty's
/// Light/Dark override without any view needing to know which one is active.
enum Theme {
    // MARK: Colors (shadcn zinc, HSL tokens converted to sRGB)

    static let background = dynamic(light: 0xFFFFFF, dark: 0x09090B)
    static let foreground = dynamic(light: 0x09090B, dark: 0xFAFAFA)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x09090B)
    static let popover = dynamic(light: 0xFFFFFF, dark: 0x0C0C0E)
    static let muted = dynamic(light: 0xF4F4F5, dark: 0x27272A)
    static let mutedForeground = dynamic(light: 0x71717A, dark: 0xA1A1AA)
    static let accent = dynamic(light: 0xF4F4F5, dark: 0x27272A)
    static let accentForeground = dynamic(light: 0x18181B, dark: 0xFAFAFA)
    static let border = dynamic(light: 0xE4E4E7, dark: 0x27272A)
    static let input = dynamic(light: 0xE4E4E7, dark: 0x27272A)
    static let ring = dynamic(light: 0xA1A1AA, dark: 0x52525B)
    static let primary = dynamic(light: 0x18181B, dark: 0xFAFAFA)
    static let primaryForeground = dynamic(light: 0xFAFAFA, dark: 0x18181B)
    static let secondary = dynamic(light: 0xF4F4F5, dark: 0x27272A)
    static let destructive = dynamic(light: 0xEF4444, dark: 0xDC2626)
    static let destructiveForeground = Color.white
    static let success = dynamic(light: 0x16A34A, dark: 0x22C55E)
    static let warning = dynamic(light: 0xD97706, dark: 0xF59E0B)
    /// Search-match emphasis: the foreground, plus a faint highlight behind it.
    static let highlight = dynamic(light: 0xFEF08A, dark: 0x854D0E, lightAlpha: 0.7, darkAlpha: 0.55)

    // MARK: Radius (shadcn --radius: 0.5rem)

    static let radiusLarge: CGFloat = 12 // rounded-xl
    static let radius: CGFloat = 8 // rounded-lg
    static let radiusMedium: CGFloat = 6 // rounded-md
    static let radiusSmall: CGFloat = 4 // rounded-sm

    // MARK: Helpers

    /// The foreground token as a dynamic `NSColor`, usable off the main thread.
    static let foregroundNS = dynamicNS(light: 0x09090B, dark: 0xFAFAFA)

    /// The same tokens as dynamic `NSColor`s, for AppKit views (text fields, text views).
    @MainActor
    enum NS {
        static let foreground = dynamicNS(light: 0x09090B, dark: 0xFAFAFA)
        static let mutedForeground = dynamicNS(light: 0x71717A, dark: 0xA1A1AA)
        static let accent = dynamicNS(light: 0xF4F4F5, dark: 0x27272A)
        static let border = dynamicNS(light: 0xE4E4E7, dark: 0x27272A)
        static let popover = dynamicNS(light: 0xFFFFFF, dark: 0x0C0C0E)
        static let background = dynamicNS(light: 0xFFFFFF, dark: 0x09090B)
    }

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static func dynamicNS(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Typography

/// Plus Jakarta Sans, bundled with the app (SIL Open Font License) and registered at launch.
/// Every call falls back to the system font if registration ever fails, so text never disappears.
enum Typeface {
    enum Weight: String, CaseIterable {
        case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold"

        var postScriptName: String { "PlusJakartaSans-\(rawValue)" }

        var system: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    /// Registers the bundled fonts for this process. Safe to call more than once.
    @discardableResult
    static func registerBundledFonts(in bundle: Bundle = .main) -> Bool {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("PlusJakartaSans") {
            // Already-registered fonts report an error we can ignore.
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return isAvailable
    }

    static var isAvailable: Bool {
        Weight.allCases.allSatisfy { NSFont(name: $0.postScriptName, size: 12) != nil }
    }

    static func nsFont(_ size: CGFloat, _ weight: Weight = .regular) -> NSFont {
        NSFont(name: weight.postScriptName, size: size) ?? .systemFont(ofSize: size, weight: weight.system)
    }

    static func font(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        Font(nsFont(size, weight) as CTFont)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> Font {
        .system(size: size, weight: Font.Weight(weight), design: .monospaced)
    }
}

private extension Font.Weight {
    init(_ weight: NSFont.Weight) {
        switch weight {
        case .medium: self = .medium
        case .semibold: self = .semibold
        case .bold: self = .bold
        default: self = .regular
        }
    }
}

/// shadcn's type scale (text-xs … text-lg), in points.
extension Font {
    static var shadXS: Font { Typeface.font(12) }
    static var shadXSMedium: Font { Typeface.font(12, .medium) }
    static var shadSM: Font { Typeface.font(13.5) }
    static var shadSMMedium: Font { Typeface.font(13.5, .medium) }
    static var shadSMSemibold: Font { Typeface.font(13.5, .semibold) }
    static var shadBase: Font { Typeface.font(15) }
    static var shadLGSemibold: Font { Typeface.font(17, .semibold) }
}
