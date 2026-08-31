import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// Telemetry Bible Phase 3 (#1172): `refreshAccessibilityStatus()` emits a
  /// `permission.status context=changed` event on a real grant/revoke flip, at
  /// the detection points the app already runs (background poll / onboarding /
  /// launch / pre-record). The injected `accessibilityReader` drives the flip
  /// deterministically. Bodies are synchronous (set hook -> flip -> refresh ->
  /// read -> restore, no await), so the process-global `testEventHook` stays
  /// flake-immune per swift-patterns RULE: tests-no-process-global-mutable-delegate.
  @Suite("Permissions service permission.status", .serialized)
  struct PermissionsServiceTests {
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ event: CapturedTelemetryEvent) { lock.withLock { stored.append(event) } }
      var events: [CapturedTelemetryEvent] { lock.withLock { stored } }
    }

    @MainActor
    @Test("revoke flip emits accessibility/denied/changed and re-arms the warning")
    func revokeEmitsAndRearms() {
      var granted = true
      let svc = PermissionsService(accessibilityReader: { granted })
      svc.dismissAccessibilityWarning()
      #expect(svc.accessibilityWarningDismissed == true)

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "permission.status" { box.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      granted = false
      svc.refreshAccessibilityStatus()

      #expect(box.events.count == 1)
      let event = box.events.first
      #expect(event?.stringProps["permission"] == "accessibility")
      #expect(event?.stringProps["status"] == "denied")
      #expect(event?.stringProps["context"] == "changed")
      // Revocation re-arms the warning so it shows again.
      #expect(svc.accessibilityWarningDismissed == false)
    }

    @MainActor
    @Test("grant flip emits accessibility/granted/changed")
    func grantEmits() {
      var granted = false
      let svc = PermissionsService(accessibilityReader: { granted })

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "permission.status" { box.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      granted = true
      svc.refreshAccessibilityStatus()

      #expect(box.events.count == 1)
      #expect(box.events.first?.stringProps["status"] == "granted")
      #expect(box.events.first?.stringProps["context"] == "changed")
    }

    @MainActor
    @Test("no state change emits nothing (idempotent)")
    func noChangeNoEmit() {
      let svc = PermissionsService(accessibilityReader: { true })

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "permission.status" { box.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      // No flip: state stays granted across repeated refreshes.
      svc.refreshAccessibilityStatus()
      svc.refreshAccessibilityStatus()

      #expect(box.events.isEmpty)
    }

    @MainActor
    @Test(
      "accessibilityGrantedLive reflects a fresh grant the cache hasn't seen, with no side effect")
    func liveReadDivergesFromStaleCacheWithoutSideEffect() {
      // #1176 cloud Codex review r3: the onboarding-abandon posture must observe the
      // RESOLVED accessibility value, not the lagging cache.
      var live = false
      let svc = PermissionsService(accessibilityReader: { live })
      #expect(svc.accessibilityGranted == false)  // cached at init

      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "permission.status" { box.add(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      live = true  // user grants in System Settings, before any poll refresh
      #expect(svc.accessibilityGrantedLive == true)  // live read sees it
      #expect(svc.accessibilityGranted == false)  // pure read did NOT mutate the cache
      #expect(box.events.isEmpty)  // and did NOT emit a flip event
    }

    // #2549: `requestMicrophoneAccessOrOpenSettings()` — the denied branch is
    // fully injectable and testable. The not-denied branch calls the real,
    // un-injectable `AVCaptureDevice.requestAccess` (a pre-existing limit of
    // `requestMicrophoneAccess()` this change does not alter), so it is not
    // exercised here — matches the existing untested shape of that call.
    @MainActor
    @Test("requestMicrophoneAccessOrOpenSettings opens System Settings when already denied")
    func deniedOpensSystemSettings() async {
      final class OpenedURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?
        func set(_ url: URL) { lock.withLock { stored = url } }
        var opened: URL? { lock.withLock { stored } }
      }
      let box = OpenedURLBox()
      let svc = PermissionsService(
        microphoneReader: { .denied },
        openMicrophoneSettings: { box.set($0) }
      )

      await svc.requestMicrophoneAccessOrOpenSettings()

      #expect(
        box.opened?.absoluteString
          == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
  }

#endif
