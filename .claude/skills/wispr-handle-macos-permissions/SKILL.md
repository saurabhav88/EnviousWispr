---
name: wispr-handle-macos-permissions
description: "Use when adding, modifying, or debugging microphone or accessibility permission checks in EnviousWispr — including PermissionsService, permission-gated feature guards, or any call to AVCaptureDevice or AXIsProcessTrusted."
---

# Handle macOS Permissions

## Permission Map

| Feature | Permission Required |
|---|---|
| Audio recording (AVAudioEngine) | Microphone |
| Global hotkey observation (NSEvent global monitors) | Accessibility |
| PasteService (CGEvent Cmd+V simulation) | Accessibility |
| Local NSEvent monitors only | None |

## Microphone Permission

```swift
// Request (async, call from MainActor)
let granted = await AVCaptureDevice.requestAccess(for: .audio)

// Check current status (synchronous)
let status = AVCaptureDevice.authorizationStatus(for: .audio)
// .authorized | .denied | .restricted | .notDetermined
```

## Accessibility Permission

```swift
// Check without prompting
let trusted = AXIsProcessTrusted()

// Check AND prompt (Swift 6: kAXTrustedCheckOptionPrompt unavailable as C global)
// Use string literal workaround:
let key = "AXTrustedCheckOptionPrompt" as CFString
let options = [key: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
```

Never write `kAXTrustedCheckOptionPrompt` — it is not bridged in Swift 6 CLI builds.

## PermissionsService Pattern

```swift
@MainActor
@Observable
final class PermissionsService {
    var microphoneAuthorized: Bool = false
    var accessibilityAuthorized: Bool = false

    func checkAll() {
        microphoneAuthorized =
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAuthorized = AXIsProcessTrusted()
    }

    func requestMicrophone() async {
        microphoneAuthorized =
            await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openAccessibilityPrefs() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
```

## Checklist

- [ ] Microphone request uses `await AVCaptureDevice.requestAccess(for: .audio)`
- [ ] Accessibility check uses `AXIsProcessTrusted()` or `AXIsProcessTrustedWithOptions(_:)` with string literal key
- [ ] No use of `kAXTrustedCheckOptionPrompt` (Swift 6 build breakage)
- [ ] `PermissionsService` methods called from `@MainActor` context
- [ ] `checkAll()` called on app launch and on `NSWorkspace.didActivateApplicationNotification`
- [ ] UI guards gated on `permissionsService.accessibilityAuthorized` before activating hotkeys or paste
