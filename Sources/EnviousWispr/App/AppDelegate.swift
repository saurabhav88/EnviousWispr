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

    /// Callbacks set by SwiftUI to open windows (since openWindow env is only available in views).
    var openMainWindowAction: (() -> Void)?
    var openSettingsAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon on launch — we're a menu bar utility
        NSApp.setActivationPolicy(.accessory)

        // When all visible windows close, revert to accessory to hide dock icon
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Delay check so the window has time to close
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                let hasVisibleWindows = NSApp.windows.contains { $0.isVisible && !($0.className.contains("StatusBar")) }
                if !hasVisibleWindows {
                    NSApp.setActivationPolicy(.accessory)
                }
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

        // Status line
        let state = appState.pipelineState
        let modelState: String
        if !appState.asrManager.isModelLoaded && state != .recording && state != .transcribing {
            modelState = "Model unloaded"
        } else {
            modelState = appState.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
        }
        let statusMenuItem = NSMenuItem(title: "\(state.statusText) — \(modelState)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // Record / Stop
        let recordTitle = state == .recording ? "Stop Recording" : "Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.isEnabled = !(state.isActive && state != .recording)
        menu.addItem(recordItem)

        menu.addItem(.separator())

        // Open main window
        let openItem = NSMenuItem(title: "Open EnviousWispr", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit EnviousWispr", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Update the status item icon based on pipeline state.
    func updateIcon() {
        let state = appState.pipelineState
        let iconName = state.menuBarIconName
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

    @objc private func openMainWindow() {
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
        if let action = openSettingsAction {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
