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
  }

#endif
