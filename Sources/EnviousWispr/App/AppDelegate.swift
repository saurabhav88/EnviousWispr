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
    private(set) var updaterController: SPUStandardUpdaterController!
    private var pulseTimer: Timer?
    private var pulsePhase: Bool = false

    /// Shared app state — created here so it's available before any SwiftUI scene loads.
    let appState = AppState()

    /// Callback set by SwiftUI to open the main window (since openWindow env is only available in views).
    var openMainWindowAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon on launch — we're a menu bar utility
        NSApp.setActivationPolicy(.accessory)

        // When the unified window closes, revert to .accessory immediately.
        // There's only one window now, so no need for the 200ms re-check delay.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            // Access title on main queue (observer queue is .main above).
            // Match by title (set from Window scene declaration) and styled mask
            // so status-bar/panel windows never trigger the policy reset.
            MainActor.assumeIsolated {
                guard window.styleMask.contains(.titled),
                      window.title == AppConstants.appName else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        setupStatusItem()

        // Update menu bar icon whenever pipeline state changes
        appState.onPipelineStateChange = { [weak self] _ in
            self?.updateIcon()
        }

        // Start hotkeys now that the event loop is running.
        // Carbon RegisterEventHotKey requires an active run loop for event delivery.
        appState.startHotkeyServiceIfEnabled()

        // Check Accessibility permission on launch (query only — never auto-prompt).
        appState.refreshAccessibilityOnLaunch()

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
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "EnviousWispr")

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        populateMenu(menu)
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
            warningItem.image = NSImage(systemSymbolName: "lock.open.fill", accessibilityDescription: "Accessibility required")
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
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Update")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit EnviousWispr", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Update the status item icon based on pipeline state.
    func updateIcon() {
        let state = appState.pipelineState
        // Show mic.slash when accessibility is missing and the app is idle,
        // to signal that paste will not work until the user grants permission.
        let iconName: String
        if state == .idle && appState.permissions.shouldShowAccessibilityWarning {
            iconName = "mic.slash"
        } else {
            iconName = state.menuBarIconName
        }
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "EnviousWispr")
        statusItem?.button?.alphaValue = 1.0

        if state.shouldPulseIcon {
            startPulse()
        } else {
            stopPulse()
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulsePhase = false
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let button = self.statusItem?.button else { return }
                self.pulsePhase.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.5
                    button.animator().alphaValue = self.pulsePhase ? 0.3 : 1.0
                }
            }
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = false
        statusItem?.button?.alphaValue = 1.0
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
            for window in NSApp.windows where window.title == "EnviousWispr" {
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
