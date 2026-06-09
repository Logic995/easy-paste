import Foundation
import Testing

@testable import EasyPasteCore

@MainActor
private func makePreferencesStore() -> ClipboardStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return ClipboardStore(fileURL: dir.appendingPathComponent("state.json"))
}

@MainActor
private func prefItem(_ title: String, updatedAt: Date, pinned: Bool = false) -> ClipboardItem {
    ClipboardItem(
        kind: .text,
        title: title,
        preview: title,
        sourceApp: "Tests",
        text: title,
        pinned: pinned,
        updatedAt: updatedAt,
        hash: title
    )
}

@Test @MainActor func preferencesPersistAndDefaultForOldState() throws {
    let store = makePreferencesStore()
    #expect(store.preferences.pasteDestination == .activeApp)
    try store.updatePreferences {
        $0.pasteDestination = .clipboard
        $0.quickPanelStyle = .cardHandExperimental
        $0.alwaysPastePlainText = true
        $0.activationShortcut = KeyboardShortcut(keyCode: 8, carbonModifiers: 768)
    }

    let reloaded = ClipboardStore(fileURL: store.fileURL)
    try reloaded.load()
    #expect(reloaded.preferences.pasteDestination == .clipboard)
    #expect(reloaded.preferences.quickPanelStyle == .cardHandExperimental)
    #expect(reloaded.preferences.alwaysPastePlainText)
    #expect(reloaded.preferences.activationShortcut == KeyboardShortcut(keyCode: 8, carbonModifiers: 768))
}

@Test @MainActor func missingShortcutDefaultsToActivationShortcut() throws {
    let store = makePreferencesStore()
    let oldState = """
    {
      "schemaVersion" : 1,
      "items" : [],
      "pinboards" : [],
      "activeBoardSelector" : { "all" : {} },
      "preferences" : {
        "openAtLogin" : false,
        "runInBackground" : true
      }
    }
    """
    try FileManager.default.createDirectory(
        at: store.fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try oldState.data(using: .utf8)?.write(to: store.fileURL)

    try store.load()
    #expect(store.preferences.activationShortcut == .defaultActivation)
    #expect(store.preferences.quickPanelStyle == .classic)
}

@Test @MainActor func historyRetentionRemovesExpiredDisposableItems() throws {
    let store = makePreferencesStore()
    let old = Date().addingTimeInterval(-9 * 24 * 60 * 60)
    let fresh = Date().addingTimeInterval(-60)

    try store.upsert(prefItem("old", updatedAt: old))
    try store.upsert(prefItem("fresh", updatedAt: fresh))
    try store.upsert(prefItem("pinned-old", updatedAt: old, pinned: true))
    try store.updatePreferences { $0.historyRetention = .week }

    #expect(!store.items.contains { $0.hash == "old" })
    #expect(store.items.contains { $0.hash == "fresh" })
    #expect(store.items.contains { $0.hash == "pinned-old" })
}

@Test @MainActor func ignoredApplicationsArePersistedAndMatchedByBundleID() throws {
    let store = makePreferencesStore()
    try store.addIgnoredApplication(IgnoredApplication(name: "Secret", bundleIdentifier: "com.example.secret"))

    #expect(store.isIgnoredApplication(bundleIdentifier: "com.example.secret"))
    #expect(!store.isIgnoredApplication(bundleIdentifier: "com.example.other"))

    try store.removeIgnoredApplication(bundleIdentifier: "com.example.secret")
    #expect(!store.isIgnoredApplication(bundleIdentifier: "com.example.secret"))
}

@Test func contentPrivacyFiltersDefaultOffBecauseIgnoredAppsAreTheBoundary() {
    let preferences = EasyPastePreferences()
    #expect(preferences.quickPanelStyle == .classic)
    #expect(!preferences.debugPerformance)
    #expect(preferences.panelGlassOpacity == 1.0)
    #expect(!preferences.ignoreConfidentialContent)
    #expect(!preferences.ignoreTransientContent)
}
