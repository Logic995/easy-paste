import Foundation

public enum LocalDataCleanupError: LocalizedError, Equatable {
    case unsafeSupportDirectory(URL)
    case supportDirectoryMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .unsafeSupportDirectory(let url):
            return "Refusing to clear unsafe support directory: \(url.path)"
        case .supportDirectoryMissing(let url):
            return "EasyPaste support directory does not exist: \(url.path)"
        }
    }
}

public enum LocalDataCleanup {
    public static func supportDirectory(forStateFile fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
    }

    public static func validateSupportDirectory(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.lastPathComponent == "EasyPaste",
              standardized.path.contains("/Library/Application Support/") else {
            throw LocalDataCleanupError.unsafeSupportDirectory(standardized)
        }
    }

    public static func clearSupportDirectory(
        forStateFile fileURL: URL,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        trash: (URL) throws -> Void
    ) throws {
        let supportDirectory = supportDirectory(forStateFile: fileURL)
        try validateSupportDirectory(supportDirectory)
        guard fileExists(supportDirectory.path) else {
            throw LocalDataCleanupError.supportDirectoryMissing(supportDirectory)
        }
        try trash(supportDirectory)
    }
}
