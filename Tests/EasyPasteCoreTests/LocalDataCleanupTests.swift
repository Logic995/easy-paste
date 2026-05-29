import Foundation
import Testing

@testable import EasyPasteCore

@Test func localDataCleanupUsesOnlyEasyPasteApplicationSupportDirectory() throws {
    let stateFile = URL(fileURLWithPath: "/Users/test/Library/Application Support/EasyPaste/state.json")
    var trashedURL: URL?

    try LocalDataCleanup.clearSupportDirectory(
        forStateFile: stateFile,
        fileExists: { $0 == "/Users/test/Library/Application Support/EasyPaste" },
        trash: { trashedURL = $0 }
    )

    #expect(trashedURL?.path == "/Users/test/Library/Application Support/EasyPaste")
}

@Test func localDataCleanupRejectsUnsafeDirectory() throws {
    let stateFile = URL(fileURLWithPath: "/Users/test/Documents/state.json")

    #expect(throws: LocalDataCleanupError.self) {
        try LocalDataCleanup.clearSupportDirectory(
            forStateFile: stateFile,
            fileExists: { _ in true },
            trash: { _ in }
        )
    }
}

@Test func localDataCleanupReportsMissingSupportDirectory() throws {
    let stateFile = URL(fileURLWithPath: "/Users/test/Library/Application Support/EasyPaste/state.json")

    #expect(throws: LocalDataCleanupError.self) {
        try LocalDataCleanup.clearSupportDirectory(
            forStateFile: stateFile,
            fileExists: { _ in false },
            trash: { _ in }
        )
    }
}
