@preconcurrency import AVFoundation
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

    // #2549: runs the monitor loop for real (fast injected interval, no
    // mocked comparison logic) through the exact transition class two
    // cloud-review rounds found broken: a not-yet-authorized mic status
    // changing to a DIFFERENT not-yet-authorized status. Round 1's bug and
    // round 2's bug both collapsed the four real statuses to a yes/no
    // "authorized" flag somewhere in this loop, so a not-determined-to-denied
    // change looked like no change at all under either buggy version. This
    // test fails against both prior versions and only passes once the loop
    // compares the real status value, closing the class rather than the one
    // reported instance of it. Uses `CountWaiters` (Pipeline/TestSupport) to
    // park on the callback firing instead of polling real time.
    @MainActor
    @Test("permission monitor notices a change between two not-yet-authorized mic states")
    func monitorNoticesNotDeterminedToDeniedTransition() async {
      final class MicStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AVAuthorizationStatus = .notDetermined
        func set(_ status: AVAuthorizationStatus) { lock.withLock { stored = status } }
        var current: AVAuthorizationStatus { lock.withLock { stored } }
      }

      let micStatus = MicStatusBox()
      var observed: [AVAuthorizationStatus] = []
      var waiters = CountWaiters("permission-monitor-changes")
      let svc = PermissionsService(
        accessibilityReader: { true },
        microphoneReader: { micStatus.current },
        permissionPollIntervalNanoseconds: 5_000_000  // 5ms: fast, deterministic ticks
      )
      svc.onPermissionChange = {
        observed.append(svc.microphoneStatus)
        waiters.notify(reached: observed.count)
      }

      func waitForChange(count: Int) async {
        if observed.count >= count { return }
        let id = UUID()
        let timeoutTask = Task {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: fail fast if the monitor tick never fires
          waiters.resume(id: id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          waiters.install(id: id, target: count, continuation)
        }
        timeoutTask.cancel()
      }

      svc.startMonitoring()
      micStatus.set(.denied)
      await waitForChange(count: 1)

      #expect(observed == [.denied])
      #expect(svc.microphoneStatus == .denied)

      micStatus.set(.authorized)
      await waitForChange(count: 2)

      #expect(observed == [.denied, .authorized])
    }
  }

#endif
