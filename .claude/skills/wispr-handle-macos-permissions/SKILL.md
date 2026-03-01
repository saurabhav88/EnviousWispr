---
name: wispr-handle-macos-permissions
description: "Use when adding, modifying, or debugging microphone or Accessibility permission checks in EnviousWispr — including PermissionsService, PasteService, or any call to AVCaptureDevice / AXIsProcessTrusted."
---

# Handle macOS Permissions

## Permission Map

| Feature | Permission Required |
|---|---|
| Audio recording (AVAudioEngine) | Microphone |
| Global hotkeys (Carbon RegisterEventHotKey) | **None** — Carbon does not require Accessibility |
| PasteService (CGEvent.post via .cghidEventTap) | **Accessibility** — required on macOS 14+ |

> CRITICAL: `CGEvent.post()` requires Accessibility permission on modern macOS (14+) regardless
> of tap level. Both `.cghidEventTap` and `.cgSessionEventTap` require `AXIsProcessTrusted()`.
> Without it, events post silently but are never delivered to the target app.

## Microphone Permission

```swift
@preconcurrency import AVFoundation

// Request (async, call from MainActor)
let granted = await AVCaptureDevice.requestAccess(for: .audio)

// Check current status (synchronous)
let status = AVCaptureDevice.authorizationStatus(for: .audio)
// .authorized | .denied | .restricted | .notDetermined
```

## Accessibility Permission

```swift
import ApplicationServices

// Check (does NOT prompt user)
let trusted = AXIsProcessTrusted()

// Check AND prompt user to open System Settings
let options = ["AXTrustedCheckOptionPrompt" as CFString: true as CFBoolean]
let trustedWithPrompt = AXIsProcessTrustedWithOptions(options as CFDictionary)
```

> Note: `kAXTrustedCheckOptionPrompt` is not a Swift symbol — use the string literal
> `"AXTrustedCheckOptionPrompt" as CFString` workaround (see gotchas.md).

## PermissionsService Pattern

```swift
@preconcurrency import AVFoundation
import ApplicationServices

@MainActor
@Observable
final class PermissionsService {
    private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined
    private(set) var accessibilityGranted: Bool = false

    init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return granted
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }
}
```

## Runtime Revocation Monitoring (Re-arm Pattern)

Accessibility permission can be revoked at runtime (e.g., user removes app from System Settings).
The app monitors with a 5-second poll and re-arms the warning UI on revocation.

```swift
// In AppState or PermissionsService — call on app activate and on a timer
func startAccessibilityMonitoring() {
    Timer.scheduledTimer(withTimeInterval: TimingConstants.accessibilityPollIntervalSec,
                         repeats: true) { [weak self] _ in
        Task { @MainActor in
            let nowTrusted = AXIsProcessTrusted()
            if let self, self.permissionsService.accessibilityGranted, !nowTrusted {
                // Revoked — re-arm warning UI
                self.permissionsService.refreshAccessibilityStatus()
                self.resetAccessibilityWarningDismissal()
            }
        }
    }
}
```

> Always call `refreshAccessibilityStatus()` on `applicationDidBecomeActive` as well,
> since the user may have toggled the grant in System Settings while the app was backgrounded.

## Checklist

- [ ] Microphone request uses `await AVCaptureDevice.requestAccess(for: .audio)`
- [ ] `AVFoundation` imported with `@preconcurrency import AVFoundation`
- [ ] `PermissionsService` methods called from `@MainActor` context
- [ ] Accessibility IS required for `PasteService` (`CGEvent.post`) — check `AXIsProcessTrusted()`
- [ ] Carbon hotkeys (`RegisterEventHotKey`) do NOT require Accessibility permission
- [ ] Runtime revocation monitoring in place (5s poll, re-arm warning on revocation)
- [ ] `refreshAccessibilityStatus()` called on `applicationDidBecomeActive`
- [ ] `kAXTrustedCheckOptionPrompt` referenced as string literal `"AXTrustedCheckOptionPrompt" as CFString`
