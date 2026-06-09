import AppKit

@MainActor
enum EasyPasteThemeMode: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "自动跟随系统"
        case .light: return "亮色"
        case .dark: return "暗色"
        }
    }
}

@MainActor
enum EasyPasteThemeStore {
    static let changedNotification = Notification.Name("EasyPasteThemeChanged")

    private static let defaultsKey = "themeMode"

    static var mode: EasyPasteThemeMode {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey)
            return raw.flatMap(EasyPasteThemeMode.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static var effectiveTheme: EasyPasteTheme {
        let isDark: Bool
        switch mode {
        case .dark:
            isDark = true
        case .light:
            isDark = false
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            isDark = match == .darkAqua
        }
        return EasyPasteTheme(isDark: isDark)
    }

    static var appearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
struct EasyPasteTheme {
    let isDark: Bool

    var panelMaterial: NSVisualEffectView.Material { isDark ? .hudWindow : .popover }
    var panelBackground: NSColor {
        panelBackground(opacity: 1.0)
    }

    func panelBackground(opacity: Double) -> NSColor {
        let clamped = min(1.0, max(0.0, opacity))
        let darkAlpha = 0.04 + 0.52 * clamped
        let lightAlpha = 0.06 + 0.70 * clamped
        return isDark
            ? NSColor.black.withAlphaComponent(darkAlpha)
            : NSColor.white.withAlphaComponent(lightAlpha)
    }
    var panelSolidBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.070, green: 0.078, blue: 0.090, alpha: 0.98)
            : NSColor(calibratedRed: 0.955, green: 0.965, blue: 0.980, alpha: 0.98)
    }
    var panelBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.10)
    }

    var cardBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.070, green: 0.078, blue: 0.090, alpha: 0.78)
            : NSColor(calibratedWhite: 0.96, alpha: 0.82)
    }
    var cardBodyBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.074, green: 0.083, blue: 0.096, alpha: 0.98)
            : NSColor(calibratedWhite: 0.985, alpha: 0.96)
    }
    var primaryText: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.black.withAlphaComponent(0.78)
    }
    var secondaryText: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.84)
            : NSColor.black.withAlphaComponent(0.56)
    }
    var footerText: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.58)
            : NSColor.black.withAlphaComponent(0.44)
    }
    var imageInfoText: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor.black.withAlphaComponent(0.58)
    }
    var imageInfoChipBackground: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.085)
            : NSColor.black.withAlphaComponent(0.055)
    }

    var handCardBase: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.050, green: 0.054, blue: 0.064, alpha: 1.0)
            : NSColor(calibratedRed: 0.985, green: 0.988, blue: 0.994, alpha: 1.0)
    }
    var handCardTop: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.116, green: 0.120, blue: 0.134, alpha: 1.0)
            : NSColor(calibratedRed: 1.000, green: 1.000, blue: 1.000, alpha: 1.0)
    }
    var handCardMiddle: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.070, green: 0.074, blue: 0.088, alpha: 1.0)
            : NSColor(calibratedRed: 0.964, green: 0.970, blue: 0.982, alpha: 1.0)
    }
    var handCardBottom: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.036, green: 0.039, blue: 0.049, alpha: 1.0)
            : NSColor(calibratedRed: 0.922, green: 0.932, blue: 0.948, alpha: 1.0)
    }
    var handPreviewTop: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.054, green: 0.058, blue: 0.069, alpha: 1.0)
            : NSColor(calibratedRed: 0.974, green: 0.978, blue: 0.986, alpha: 1.0)
    }
    var handPreviewBottom: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.031, green: 0.034, blue: 0.043, alpha: 1.0)
            : NSColor(calibratedRed: 0.934, green: 0.942, blue: 0.956, alpha: 1.0)
    }
    var handImageFrameBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.045, green: 0.049, blue: 0.058, alpha: 1.0)
            : NSColor(calibratedRed: 0.965, green: 0.970, blue: 0.980, alpha: 1.0)
    }
    var handImageStageBackground: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.034, green: 0.038, blue: 0.047, alpha: 1.0)
            : NSColor(calibratedRed: 0.940, green: 0.948, blue: 0.962, alpha: 1.0)
    }
    var handPrimaryText: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 0.94)
            : NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.88)
    }
    var handSecondaryText: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 0.78)
            : NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.70)
    }
    var handMutedText: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 0.42)
            : NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.46)
    }
    var handQuietBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.11)
    }
    var handHoverBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.24)
            : NSColor.black.withAlphaComponent(0.18)
    }
    var handSelectedBorder: NSColor {
        isDark
            ? NSColor(calibratedRed: 0.85, green: 0.73, blue: 0.47, alpha: 0.82)
            : NSColor(calibratedRed: 0.58, green: 0.42, blue: 0.15, alpha: 0.70)
    }
    var handHighlight: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.white.withAlphaComponent(0.62)
    }
    var handBadgeBackground: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.72)
    }
    var handBadgeBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.11)
            : NSColor.black.withAlphaComponent(0.08)
    }

    var toolbarIcon: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.92)
            : NSColor.black.withAlphaComponent(0.62)
    }
    var pillBackground: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.64)
    }
    var pillBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.18)
            : NSColor.black.withAlphaComponent(0.08)
    }
    var pillText: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.96)
            : NSColor.black.withAlphaComponent(0.72)
    }
    var toolbarButtonBackgroundBase: NSColor { isDark ? .white : .black }

    var searchBackground: NSColor {
        isDark
            ? NSColor.black.withAlphaComponent(0.28)
            : NSColor.white.withAlphaComponent(0.74)
    }
    var searchBorder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.20)
            : NSColor.black.withAlphaComponent(0.10)
    }
    var searchText: NSColor {
        isDark
            ? .white
            : NSColor.black.withAlphaComponent(0.78)
    }
    var searchPlaceholder: NSColor {
        isDark
            ? NSColor.white.withAlphaComponent(0.45)
            : NSColor.black.withAlphaComponent(0.36)
    }
}
