import AppKit
@preconcurrency import Sparkle
import SwiftUI

/// AppDelegate that manages the menu bar status item using NSStatusItem.
///
/// SwiftUI's MenuBarExtra has known click-routing issues when launched
/// outside Xcode or as a bare binary. NSStatusItem is the battle-tested
/// native approach that reliably handles clicks on all macOS versions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private(set) var updaterController: SPUStandardUpdaterController?
    private let iconAnimator = MenuBarIconAnimator()
    private weak var mainWindow: NSWindow?
    private var windowCloseObserver: (any NSObjectProtocol)?

    /// Shared app state — created here so it's available before any SwiftUI scene loads.
    let appState = AppState()

    /// Callback set by SwiftUI to open the main window (since openWindow env is only available in views).
    var openMainWindowAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon on launch — we're a menu bar utility
        NSApp.setActivationPolicy(.accessory)

        // When the unified window closes, revert to .accessory immediately.
        // There's only one window now, so no need for the 200ms re-check delay.
        // Store token so we can remove on termination (H11 observer leak fix).
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Capture the main window reference on first titled window appearance.
                if self.mainWindow == nil, window.styleMask.contains(.titled),
                   window.title == AppConstants.appName {
                    self.mainWindow = window
                }
                // Match by identity so status-bar/panel windows never trigger the reset.
                guard window === self.mainWindow else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupStatusItem()

        // Update menu bar icon whenever pipeline state or accessibility changes
        appState.onPipelineStateChange = { [weak self] _ in
            self?.updateIcon()
        }
        appState.onAccessibilityChange = { [weak self] in
            self?.updateIcon()
        }

        // Start hotkeys now that the event loop is running.
        // Carbon RegisterEventHotKey requires an active run loop for event delivery.
        appState.startHotkeyServiceIfEnabled()

        // Check Accessibility permission on launch (query only — never auto-prompt).
        appState.refreshAccessibilityOnLaunch()
        updateIcon() // Reflect accessibility warning state in menu bar icon

        // Begin smart polling if Accessibility is not yet granted.
        appState.startAccessibilityMonitoring()

        // Pre-warm LLM network connection (TLS + HTTP/2 setup).
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: appState.settings.llmProvider,
            keychainManager: appState.keychainManager
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Re-warm LLM connection when app comes to foreground.
        LLMNetworkSession.shared.preWarmIfConfigured(
            provider: appState.settings.llmProvider,
            keychainManager: appState.keychainManager
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        let idleImage = loadMenuBarImage(named: "menubar-idle", isTemplate: true)
        button.image = idleImage
        iconAnimator.configure(button: button, idleImage: idleImage)
        iconAnimator.audioLevelProvider = { [weak self] in self?.appState.audioCapture.audioLevel ?? 0 }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        populateMenu(menu)
    }

    /// Load a menu bar icon from the app bundle's Resources directory.
    /// At runtime the bundle is a proper .app with Contents/Resources/;
    /// during development we fall back to the source Resources/ directory.
    ///
    /// Resolution order:
    ///   1. Bundle.main.resourceURL  (production .app bundle)
    ///   2. Derived from executable path (fallback when Bundle.main mis-resolves)
    ///   3. Source tree via #filePath (development / bare binary)
    ///   4. SF Symbol "mic" (last resort)
    private func loadMenuBarImage(named name: String, isTemplate: Bool) -> NSImage? {
        // Build an ordered list of directories to search.
        var searchDirs = [URL]()

        // Primary: Bundle.main.resourceURL (correct for .app bundles)
        if let bundleRes = Bundle.main.resourceURL {
            searchDirs.append(bundleRes)
        }

        // Secondary: derive from the executable path.
        // Contents/MacOS/Binary → up twice → Contents/Resources/
        // Handles cases where Bundle.main doesn't point to the .app (e.g.,
        // bare binary invocation, SPM build tree).
        let execURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let derivedRes = execURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        if !searchDirs.contains(where: { $0.path == derivedRes.path }) {
            searchDirs.append(derivedRes)
        }

        // Tertiary: source tree (development only; #filePath bakes in the
        // compile-time path so this only works on the build machine).
        let srcRes = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()        // App/
            .deletingLastPathComponent()        // EnviousWispr/
            .appendingPathComponent("Resources")
        if !searchDirs.contains(where: { $0.path == srcRes.path }) {
            searchDirs.append(srcRes)
        }

        // Try each directory in order.
        for dir in searchDirs {
            let url1x = dir.appendingPathComponent("\(name).png")
            guard FileManager.default.fileExists(atPath: url1x.path),
                  let img = NSImage(contentsOf: url1x) else { continue }

            // Attach the @2x representation if available.
            // Set its point size to match the 1x (18pt) so NSImage treats
            // the 36px variant as a true Retina representation.
            let url2x = dir.appendingPathComponent("\(name)@2x.png")
            if let rep2x = NSImageRep(contentsOf: url2x) {
                rep2x.size = NSSize(width: 18, height: 18)
                img.addRepresentation(rep2x)
            }

            img.isTemplate = isTemplate
            img.size = NSSize(width: 18, height: 18)
            return img
        }

        // Final fallback: SF Symbol
        let fallback = NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "EnviousWispr Local"
        )
        fallback?.isTemplate = isTemplate
        fallback?.size = NSSize(width: 18, height: 18)
        return fallback
    }

    /// Populate the given menu with items reflecting current AppState.
    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = appState.pipelineState

        // Status: ASR model — LLM model
        let asrModel = appState.activeModelName
        let llmInfo = appState.activeLLMDisplayName
        let statusTitle = "\(asrModel) — \(llmInfo)"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // Record / Stop
        let recordTitle = state == .recording ? "Stop Recording" : "Start Recording"
        let recordSymbol = state == .recording ? "stop.circle" : "mic.fill"
        let recordDescription = state == .recording ? "Stop" : "Record"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.image = NSImage(systemSymbolName: recordSymbol, accessibilityDescription: recordDescription)
        recordItem.target = self
        recordItem.isEnabled = !(state.isActive && state != .recording)
        menu.addItem(recordItem)

        // Accessibility warning — shown only when paste is unavailable and not dismissed.
        if appState.permissions.shouldShowAccessibilityWarning {
            let warningItem = NSMenuItem(
                title: "Paste disabled — Accessibility required",
                action: #selector(openPermissionsSettings),
                keyEquivalent: ""
            )
            warningItem.image = NSImage(systemSymbolName: "exclamationmark.shield.fill", accessibilityDescription: "Accessibility required")
            warningItem.target = self
            menu.addItem(warningItem)
        }

        menu.addItem(.separator())

        // Settings (opens unified window to Speech Engine tab)
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Check for Updates
        if let updaterController {
            let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Update")
            updateItem.target = updaterController
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit EnviousWispr Local", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Update the status item icon based on pipeline state.
    func updateIcon() {
        let state = appState.pipelineState
        let needsAccessWarning = state == .idle && appState.permissions.shouldShowAccessibilityWarning

        if needsAccessWarning {
            iconAnimator.transition(to: .error)
        } else if case .error = state {
            iconAnimator.transition(to: .error)
        } else if state == .recording {
            iconAnimator.transition(to: .recording)
        } else if state == .transcribing || state == .polishing {
            iconAnimator.transition(to: .processing)
        } else {
            iconAnimator.transition(to: .idle)
        }
    }

    @objc private func toggleRecording() {
        Task {
            await appState.toggleRecording()
            updateIcon()
        }
    }

    /// Show the unified window: bring it to front, set .regular, activate.
    private func showWindow() {
        if let action = openMainWindowAction {
            action()
        } else {
            // Fallback: find and show an existing window
            for window in NSApp.windows where window.title == "EnviousWispr Local" {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        appState.pendingNavigationSection = .speechEngine
        showWindow()
    }

    @objc private func openPermissionsSettings() {
        appState.pendingNavigationSection = .permissions
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        appState.ollamaSetup.cleanup()
        appState.hotkeyService.stop()
        LLMNetworkSession.shared.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app — keep running when windows close.
        // User quits via "Quit EnviousWispr" in the status bar menu.
        return false
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    /// Repopulate menu items each time the menu opens so state is fresh.
    /// NSMenu delegate methods are always called on the main thread.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            if let currentMenu = self.statusItem?.menu {
                self.populateMenu(currentMenu)
            }
            self.updateIcon()
        }
    }
}
