import AppKit
import ApplicationServices
import EasyPasteCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ClipboardStore!
    private var clipboardController: ClipboardController!
    private var hotKeyController: HotKeyController!
    private var panelController: PanelController!
    private var statusItem: NSStatusItem!
    private var lastTargetApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var isClearingLocalData = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let debugArg = ProcessInfo.processInfo.arguments.contains("--debug-performance")
        EasyPasteDiagnostics.isEnabled = debugArg
        store = ClipboardStore(fileURL: Self.stateURL())

        let loadStart = EasyPasteDiagnostics.now()
        let hadSQLite = FileManager.default.fileExists(atPath: store.databaseURL.path)
        let hadLegacyJSON = FileManager.default.fileExists(atPath: store.fileURL.path)
        do {
            try store.load()
        } catch {
            NSLog("Failed to load clipboard history: \(error.localizedDescription)")
        }
        EasyPasteDiagnostics.log("app.storeLoad", [
            "backend": FileManager.default.fileExists(atPath: store.databaseURL.path) ? "sqlite" : "json",
            "hadSQLite": "\(hadSQLite)",
            "hadLegacyJSON": "\(hadLegacyJSON)",
            "items": "\(store.items.count)",
            "ms": EasyPasteDiagnostics.elapsedMS(since: loadStart)
        ])
        EasyPasteDiagnostics.isEnabled = store.preferences.debugPerformance
            || debugArg
        EasyPasteDiagnostics.log("app.launch", [
            "items": "\(store.items.count)",
            "debugArg": "\(debugArg)"
        ])

        clipboardController = ClipboardController(store: store) { [weak self] in
            self?.panelController.storeDidChange()
        }

        panelController = PanelController(
            store: store,
            clipboardController: clipboardController,
            onPreferencesChanged: { [weak self] in
                self?.preferencesDidChange()
            },
            onClearLocalData: { [weak self] in
                self?.confirmAndClearLocalData()
            }
        )
        hotKeyController = HotKeyController { [weak self] in
            self?.togglePanel()
        }

        let launchTarget = currentExternalApplication()
        setupStatusItem()
        LoginItemManager.setEnabled(store.preferences.openAtLogin)
        requestAccessibilityPermissionIfNeeded()
        clipboardController.start()
        hotKeyController.register(shortcut: store.preferences.activationShortcut)
        startTrackingTargetApplication()

        if ProcessInfo.processInfo.arguments.contains("--show-on-launch") {
            let target = launchTarget ?? currentExternalApplication() ?? lastTargetApplication
            panelController.show(targetApplication: target)
        }
        if ProcessInfo.processInfo.arguments.contains("--show-settings-on-launch") {
            panelController.openSettingsFromMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        clipboardController.stop(save: !isClearingLocalData)
        hotKeyController.unregister()
    }

    @objc private func togglePanel() {
        let target = currentExternalApplication() ?? lastTargetApplication

        panelController.toggle(targetApplication: target)
    }

    @objc private func showPanelFromMenu() {
        togglePanel()
    }

    @objc private func openSettingsFromMenu() {
        panelController.openSettingsFromMenu()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func clearLocalDataAndQuitFromMenu() {
        confirmAndClearLocalData()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "EP"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .semibold)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L10n.t("menu.show"), action: #selector(showPanelFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.clearLocalDataAndQuit"), action: #selector(clearLocalDataAndQuitFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func confirmAndClearLocalData() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("cleanup.confirmTitle")
        alert.informativeText = L10n.t("cleanup.confirmText")
        alert.addButton(withTitle: L10n.t("cleanup.confirmButton"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        performLocalDataCleanupAndQuit()
    }

    private func performLocalDataCleanupAndQuit() {
        let stateFile = store.fileURL
        do {
            try LocalDataCleanup.validateSupportDirectory(
                LocalDataCleanup.supportDirectory(forStateFile: stateFile)
            )
        } catch {
            showLocalDataCleanupError(error)
            return
        }

        panelController.prepareForLocalDataCleanup()
        let restoreLoginItem = store.preferences.openAtLogin
        clipboardController.stop(save: false)
        hotKeyController.unregister()
        LoginItemManager.setEnabled(false)

        do {
            try LocalDataCleanup.clearSupportDirectory(forStateFile: stateFile) { url in
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            }
            isClearingLocalData = true
            NSApp.terminate(nil)
        } catch LocalDataCleanupError.supportDirectoryMissing {
            isClearingLocalData = true
            NSApp.terminate(nil)
        } catch {
            clipboardController.start()
            hotKeyController.register(shortcut: store.preferences.activationShortcut)
            LoginItemManager.setEnabled(restoreLoginItem)
            showLocalDataCleanupError(error)
        }
    }

    private func showLocalDataCleanupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.t("cleanup.errorTitle")
        alert.informativeText = String(format: L10n.t("cleanup.errorText"), error.localizedDescription)
        alert.addButton(withTitle: L10n.t("cleanup.errorButton"))
        alert.runModal()
    }

    private func startTrackingTargetApplication() {
        lastTargetApplication = currentExternalApplication()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return
            }
            Task { @MainActor [weak self] in
                self?.lastTargetApplication = app
            }
        }
    }

    private func currentExternalApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
        }
    }

    private func requestAccessibilityPermissionIfNeeded() {
        guard AXIsProcessTrusted() == false else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func preferencesDidChange() {
        EasyPasteDiagnostics.isEnabled = store.preferences.debugPerformance
            || ProcessInfo.processInfo.arguments.contains("--debug-performance")
        LoginItemManager.setEnabled(store.preferences.openAtLogin)
        hotKeyController.register(shortcut: store.preferences.activationShortcut)
    }

    private static func stateURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("EasyPaste", isDirectory: true).appendingPathComponent("state.json")
    }
}
