---
name: macos-platform
model: sonnet
description: macOS permissions, accessibility, menu bar, global hotkeys, paste simulation, SwiftUI conventions.
---

# macOS Platform

## Domain

Source dirs: `Services/` (PasteService, PermissionsService, HotkeyService), `Views/MenuBar/`, `Views/Onboarding/`.

## Permissions (TCC)

**Microphone**: `AVCaptureDevice.requestAccess(for: .audio)`. Check: `.authorizationStatus(for: .audio) == .authorized`. Import: `@preconcurrency import AVFoundation`.

**Accessibility**: `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions(options)`. C global workaround: `"AXTrustedCheckOptionPrompt" as CFString`. Import: `ApplicationServices`. Required for global hotkeys + paste.

## Key Patterns

- **NSEvent monitors**: HotkeyService registers 4 monitors (global+local × keyDown+flagsChanged). Extract Sendable values (keyCode, modifierFlags) before `Task { @MainActor in }` dispatch
- **Paste**: CGEvent Cmd+V via `kVK_ANSI_V` posted to `.cghidEventTap`. Requires Accessibility
- **Menu bar**: `MenuBarExtra` with dynamic icon. Window targeting by ID. Settings: `Selector(("showSettingsWindow:"))`. Activation: `NSApplication.shared.activate(ignoringOtherApps: true)`
- **SwiftUI (macOS 14+)**: `@Observable`, `@Environment(AppState.self)`, `@Bindable var state`, `Form.formStyle(.grouped)`, native `Settings { }` scene, `NavigationSplitView`

## Skills → `.claude/skills/`

- `handle-macos-permissions`
- `review-swiftui-conventions`
- `check-accessibility-labels`
- `validate-menu-bar-patterns`

## Coordination

- Permission build errors → **build-compile**
- UI security (API key display) → **quality-security**
- New views/tabs → **feature-scaffolding** scaffolds, this agent reviews UX
