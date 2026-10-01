import AppKit
import SwiftUI

/// User-selectable appearance. `system` follows macOS.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum ReaderFontDesign: String, CaseIterable, Identifiable {
    case system, serif

    var id: String { rawValue }
    var title: String { self == .system ? "San Francisco" : "New York" }
}

enum ReadingWidth: String, CaseIterable, Identifiable {
    case narrow, standard, wide, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: "Narrow"
        case .standard: "Standard"
        case .wide: "Wide"
        case .full: "Full Window"
        }
    }

    var points: CGFloat {
        switch self {
        case .narrow: 640
        case .standard: 780
        case .wide: 980
        case .full: .greatestFiniteMagnitude
        }
    }
}

/// UserDefaults keys for reader settings, shared by `@AppStorage` users.
enum SettingsKey {
    static let appearance = "appearance"
    static let fontSize = "readerFontSize"
    static let fontDesign = "readerFontDesign"
    static let readingWidth = "readingWidth"
    static let sidebarWidth = "sidebarWidth"
}

/// Rendering parameters derived from the user's settings.
struct ReaderStyle: Equatable {
    static let defaultFontSize: CGFloat = 15
    static let fontSizeRange: ClosedRange<CGFloat> = 11...26

    var baseFontSize: CGFloat = ReaderStyle.defaultFontSize
    var fontDesign: ReaderFontDesign = .system
    var maxContentWidth: CGFloat = ReadingWidth.standard.points

    static let `default` = ReaderStyle()
}

@MainActor
enum ThemeManager {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Reader colors

extension NSColor {
    /// A color that resolves differently in light and dark appearances at draw time.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Colors used by the Markdown renderer. All are dynamic so light/dark switches apply live
/// without re-rendering.
enum ReaderPalette {
    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let link = NSColor.linkColor
    static let codeBackground = NSColor.dynamic(light: NSColor(hex: 0xF6F8FA), dark: NSColor(white: 1, alpha: 0.055))
    static let codeBorder = NSColor.dynamic(light: NSColor(hex: 0xE4E7EB), dark: NSColor(white: 1, alpha: 0.08))
    static let inlineCodeBackground = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.1))
    static let quoteBorder = NSColor.dynamic(light: NSColor(hex: 0xD0D7DE), dark: NSColor(hex: 0x3D444D))
    static let rule = NSColor.dynamic(light: NSColor(hex: 0xD8DEE4), dark: NSColor(hex: 0x3D444D))
    static let headingRule = NSColor.dynamic(light: NSColor(hex: 0xD8DEE4, alpha: 0.8), dark: NSColor(hex: 0x3D444D, alpha: 0.8))
    static let tableBorder = NSColor.dynamic(light: NSColor(hex: 0xD0D7DE), dark: NSColor(hex: 0x3D444D))
    static let tableHeaderBackground = NSColor.dynamic(light: NSColor(hex: 0xF6F8FA), dark: NSColor(white: 1, alpha: 0.06))
    static let tableStripe = NSColor.dynamic(light: NSColor(hex: 0xF6F8FA, alpha: 0.6), dark: NSColor(white: 1, alpha: 0.025))
    static let keyboardBackground = NSColor.dynamic(light: NSColor(hex: 0xF6F8FA), dark: NSColor(white: 1, alpha: 0.08))
    static let keyboardBorder = NSColor.dynamic(light: NSColor(hex: 0xC8CDD3), dark: NSColor(white: 1, alpha: 0.22))
    static let highlight = NSColor.dynamic(light: NSColor(hex: 0xFFF3A3), dark: NSColor(hex: 0xBB8009, alpha: 0.4))
    static let placeholderBorder = NSColor.dynamic(light: NSColor(white: 0, alpha: 0.15), dark: NSColor(white: 1, alpha: 0.18))

    private static let alertColors: [MarkdownAlertKind: NSColor] = [
        .note: .dynamic(light: NSColor(hex: 0x0969DA), dark: NSColor(hex: 0x4493F8)),
        .tip: .dynamic(light: NSColor(hex: 0x1A7F37), dark: NSColor(hex: 0x3FB950)),
        .important: .dynamic(light: NSColor(hex: 0x8250DF), dark: NSColor(hex: 0xAB7DF8)),
        .warning: .dynamic(light: NSColor(hex: 0x9A6700), dark: NSColor(hex: 0xD29922)),
        .caution: .dynamic(light: NSColor(hex: 0xCF222E), dark: NSColor(hex: 0xF85149)),
    ]

    static func alert(_ kind: MarkdownAlertKind) -> NSColor {
        alertColors[kind] ?? .labelColor
    }

    /// Xcode-inspired syntax colors. Created once: the renderer looks these up per token.
    private static let keywordColor = NSColor.dynamic(light: NSColor(hex: 0x9B2393), dark: NSColor(hex: 0xFF7AB2))
    private static let stringColor = NSColor.dynamic(light: NSColor(hex: 0xC41A16), dark: NSColor(hex: 0xFF8170))
    private static let commentColor = NSColor.dynamic(light: NSColor(hex: 0x5D6C79), dark: NSColor(hex: 0x7F8C98))
    private static let numberColor = NSColor.dynamic(light: NSColor(hex: 0x1C00CF), dark: NSColor(hex: 0xD9C97C))
    private static let typeColor = NSColor.dynamic(light: NSColor(hex: 0x3900A0), dark: NSColor(hex: 0xDABAFF))
    private static let functionColor = NSColor.dynamic(light: NSColor(hex: 0x326D74), dark: NSColor(hex: 0x67B7A4))
    private static let attributeColor = NSColor.dynamic(light: NSColor(hex: 0x815F03), dark: NSColor(hex: 0xCC9768))
    private static let propertyColor = NSColor.dynamic(light: NSColor(hex: 0x0F68A0), dark: NSColor(hex: 0x41A1C0))
    private static let metaColor = NSColor.dynamic(light: NSColor(hex: 0x643820), dark: NSColor(hex: 0xFFA14F))
    private static let additionColor = NSColor.dynamic(light: NSColor(hex: 0x116329), dark: NSColor(hex: 0x7EE787))
    private static let deletionColor = NSColor.dynamic(light: NSColor(hex: 0x82071E), dark: NSColor(hex: 0xFFA198))
    private static let additionBackground = NSColor.dynamic(light: NSColor(hex: 0xDAFBE1), dark: NSColor(hex: 0x2EA043, alpha: 0.18))
    private static let deletionBackground = NSColor.dynamic(light: NSColor(hex: 0xFFEBE9), dark: NSColor(hex: 0xF85149, alpha: 0.18))

    static func syntax(_ kind: SyntaxToken.Kind) -> NSColor {
        switch kind {
        case .keyword, .tag: keywordColor
        case .string: stringColor
        case .comment: commentColor
        case .number: numberColor
        case .type: typeColor
        case .function: functionColor
        case .attribute: attributeColor
        case .property, .variable: propertyColor
        case .meta: metaColor
        case .addition: additionColor
        case .deletion: deletionColor
        }
    }

    static func syntaxBackground(_ kind: SyntaxToken.Kind) -> NSColor? {
        switch kind {
        case .addition: additionBackground
        case .deletion: deletionBackground
        default: nil
        }
    }
}
