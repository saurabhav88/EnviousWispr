import AppKit
import SwiftUI

/// AppDelegate that manages the menu bar status item using NSStatusItem.
///
/// SwiftUI's MenuBarExtra has known click-routing issues when launched
/// outside Xcode or as a bare binary. NSStatusItem is the battle-tested
/// native approach that reliably handles clicks on all macOS versions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    /// Shared app state — created here so it's available before any SwiftUI scene loads.
    let appState = AppState()

    /// Callbacks set by SwiftUI to open windows (since openWindow env is only available in views).
    var openMainWindowAction: (() -> Void)?
    var openSettingsAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement=true in Info.plist hides the dock icon.
        // Do NOT call setActivationPolicy(.accessory) — it breaks SwiftUI window management.
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VibeWhisper")

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
        let backend = appState.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit"
        let statusMenuItem = NSMenuItem(title: "\(state.statusText) — \(backend)", action: nil, keyEquivalent: "")
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
        let openItem = NSMenuItem(title: "Open VibeWhisper", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit VibeWhisper", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Update the status item icon based on pipeline state.
    func updateIcon() {
        let iconName = appState.pipelineState.menuBarIconName
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VibeWhisper")
    }

    @objc private func toggleRecording() {
        Task {
            await appState.toggleRecording()
            updateIcon()
        }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let action = openMainWindowAction {
            action()
        } else {
            // Fallback: find and show an existing window
            for window in NSApp.windows where window.title == "VibeWhisper" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let action = openSettingsAction {
            action()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
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
