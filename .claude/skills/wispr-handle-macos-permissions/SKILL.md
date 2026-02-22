---
name: wispr-handle-macos-permissions
description: "Use when adding, modifying, or debugging microphone permission checks in EnviousWispr — including PermissionsService or any call to AVCaptureDevice."
---

# Handle macOS Permissions

## Permission Map

| Feature | Permission Required |
|---|---|
| Audio recording (AVAudioEngine) | Microphone |
| Global hotkeys (Carbon RegisterEventHotKey) | None |
| PasteService (CGEvent session-level posting) | None |

## Microphone Permission

```swift
// Request (async, call from MainActor)
let granted = await AVCaptureDevice.requestAccess(for: .audio)

// Check current status (synchronous)
let status = AVCaptureDevice.authorizationStatus(for: .audio)
// .authorized | .denied | .restricted | .notDetermined
```

## PermissionsService Pattern

```swift
@preconcurrency import AVFoundation

@MainActor
@Observable
final class PermissionsService {
    private(set) var microphoneStatus: AVAuthorizationStatus = .notDetermined

    init() {
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return granted
    }

    var hasMicrophonePermission: Bool {
        microphoneStatus == .authorized
    }
}
```

## Checklist

- [ ] Microphone request uses `await AVCaptureDevice.requestAccess(for: .audio)`
- [ ] `PermissionsService` methods called from `@MainActor` context
- [ ] Accessibility permission is NOT required — hotkeys use Carbon, paste uses session-level CGEvent
