import Foundation

public enum PasteDestination: String, Codable, Equatable, CaseIterable, Sendable {
    case activeApp
    case clipboard
}

public enum QuickPanelStyle: String, Codable, Equatable, CaseIterable, Sendable {
    case classic
    case cardHandExperimental
}

public enum HistoryRetention: String, Codable, Equatable, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
    case forever

    public func cutoffDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .day:
            return calendar.date(byAdding: .day, value: -1, to: now)
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now)
        case .forever:
            return nil
        }
    }
}

public struct IgnoredApplication: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var bundleIdentifier: String
    public var path: String?

    public init(name: String, bundleIdentifier: String, path: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}

public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    public static let defaultActivation = KeyboardShortcut(keyCode: 9, carbonModifiers: 768)
}

public struct EasyPastePreferences: Codable, Equatable, Sendable {
    public var openAtLogin: Bool
    public var runInBackground: Bool
    public var soundEffects: Bool
    public var activationShortcut: KeyboardShortcut
    public var pasteDestination: PasteDestination
    public var quickPanelStyle: QuickPanelStyle
    public var alwaysPastePlainText: Bool
    public var historyRetention: HistoryRetention
    public var showDuringScreenSharing: Bool
    public var generateLinkPreviews: Bool
    public var debugPerformance: Bool
    public var panelGlassOpacity: Double
    public var ignoreConfidentialContent: Bool
    public var ignoreTransientContent: Bool
    public var ignoredApplications: [IgnoredApplication]

    public init(
        openAtLogin: Bool = false,
        runInBackground: Bool = true,
        soundEffects: Bool = false,
        activationShortcut: KeyboardShortcut = .defaultActivation,
        pasteDestination: PasteDestination = .activeApp,
        quickPanelStyle: QuickPanelStyle = .classic,
        alwaysPastePlainText: Bool = false,
        historyRetention: HistoryRetention = .forever,
        showDuringScreenSharing: Bool = true,
        generateLinkPreviews: Bool = true,
        debugPerformance: Bool = false,
        panelGlassOpacity: Double = 1.0,
        ignoreConfidentialContent: Bool = false,
        ignoreTransientContent: Bool = false,
        ignoredApplications: [IgnoredApplication] = []
    ) {
        self.openAtLogin = openAtLogin
        self.runInBackground = runInBackground
        self.soundEffects = soundEffects
        self.activationShortcut = activationShortcut
        self.pasteDestination = pasteDestination
        self.quickPanelStyle = quickPanelStyle
        self.alwaysPastePlainText = alwaysPastePlainText
        self.historyRetention = historyRetention
        self.showDuringScreenSharing = showDuringScreenSharing
        self.generateLinkPreviews = generateLinkPreviews
        self.debugPerformance = debugPerformance
        self.panelGlassOpacity = panelGlassOpacity
        self.ignoreConfidentialContent = ignoreConfidentialContent
        self.ignoreTransientContent = ignoreTransientContent
        self.ignoredApplications = ignoredApplications
    }

    private enum CodingKeys: String, CodingKey {
        case openAtLogin
        case runInBackground
        case soundEffects
        case activationShortcut
        case pasteDestination
        case quickPanelStyle
        case alwaysPastePlainText
        case historyRetention
        case showDuringScreenSharing
        case generateLinkPreviews
        case debugPerformance
        case panelGlassOpacity
        case ignoreConfidentialContent
        case ignoreTransientContent
        case ignoredApplications
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        openAtLogin = try c.decodeIfPresent(Bool.self, forKey: .openAtLogin) ?? false
        runInBackground = try c.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? true
        soundEffects = try c.decodeIfPresent(Bool.self, forKey: .soundEffects) ?? false
        activationShortcut = try c.decodeIfPresent(KeyboardShortcut.self, forKey: .activationShortcut) ?? .defaultActivation
        pasteDestination = try c.decodeIfPresent(PasteDestination.self, forKey: .pasteDestination) ?? .activeApp
        quickPanelStyle = try c.decodeIfPresent(QuickPanelStyle.self, forKey: .quickPanelStyle) ?? .classic
        alwaysPastePlainText = try c.decodeIfPresent(Bool.self, forKey: .alwaysPastePlainText) ?? false
        historyRetention = try c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention) ?? .forever
        showDuringScreenSharing = try c.decodeIfPresent(Bool.self, forKey: .showDuringScreenSharing) ?? true
        generateLinkPreviews = try c.decodeIfPresent(Bool.self, forKey: .generateLinkPreviews) ?? true
        debugPerformance = try c.decodeIfPresent(Bool.self, forKey: .debugPerformance) ?? false
        let decodedOpacity = try c.decodeIfPresent(Double.self, forKey: .panelGlassOpacity) ?? 1.0
        panelGlassOpacity = min(1.0, max(0.0, decodedOpacity))
        ignoreConfidentialContent = try c.decodeIfPresent(Bool.self, forKey: .ignoreConfidentialContent) ?? false
        ignoreTransientContent = try c.decodeIfPresent(Bool.self, forKey: .ignoreTransientContent) ?? false
        ignoredApplications = try c.decodeIfPresent([IgnoredApplication].self, forKey: .ignoredApplications) ?? []
    }
}

public enum EasyPastePrivacyPolicy {
    public static let transientPasteboardTypes: Set<String> = [
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    public static let confidentialPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType"
    ]

    public static func containsTransientType(_ typeNames: [String]) -> Bool {
        !transientPasteboardTypes.isDisjoint(with: Set(typeNames))
    }

    public static func containsConfidentialType(_ typeNames: [String]) -> Bool {
        !confidentialPasteboardTypes.isDisjoint(with: Set(typeNames))
    }

    public static func looksConfidential(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return false }
        if ClipboardFormatter.isURLLike(trimmed) {
            return false
        }

        let lowered = trimmed.lowercased()
        let hardSecretMarkers = [
            "-----begin private key-----",
            "-----begin rsa private key-----",
            "-----begin openssh private key-----"
        ]
        if hardSecretMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }

        if trimmed.contains("\n") {
            let lineCount = trimmed.split(whereSeparator: \.isNewline).count
            if trimmed.count > 180 || lineCount >= 3 {
                return false
            }
        }

        let obviousKeys = [
            "password", "passwd", "secret", "api_key", "apikey", "access_token",
            "private_key", "bearer "
        ]
        if obviousKeys.contains(where: { lowered.contains($0) }),
           looksLikeCredentialSnippet(trimmed) {
            return true
        }

        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return false
        }
        if looksLikeDeveloperText(trimmed) {
            return false
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+=/."))
        let scalarCount = trimmed.unicodeScalars.count
        let allowedCount = trimmed.unicodeScalars.filter { allowed.contains($0) }.count
        guard scalarCount > 0, Double(allowedCount) / Double(scalarCount) > 0.92 else {
            return false
        }

        let uniqueCount = Set(trimmed.unicodeScalars).count
        return trimmed.count >= 32 && uniqueCount >= 12
    }

    private static func looksLikeCredentialSnippet(_ text: String) -> Bool {
        guard text.count <= 300 else { return false }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 4 else { return false }

        if text.range(of: #"(?i)(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key|bearer)\s*[:=]"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"(?i)^bearer\s+[-._~+/=A-Za-z0-9]{20,}$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func looksLikeDeveloperText(_ text: String) -> Bool {
        if text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("~/") {
            return true
        }
        if text.contains("/") && text.contains(".") {
            return true
        }
        if text.range(of: #"^[A-Za-z][A-Za-z0-9]+(?:-[A-Za-z0-9]+)+-\d{8,}$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^[A-Za-z][\w-]*-[A-Fa-f0-9]{7,}$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^[\w.-]+/[\w./-]+$"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"^[A-Za-z_][\w.-]*:[\w./:-]+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
