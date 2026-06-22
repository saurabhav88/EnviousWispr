import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// Telemetry Bible Phase 0 (#1169): `flushTelemetry(reason:)` must emit
  /// `telemetry.flush_requested` carrying the reason (request-attempted, not
  /// delivery). Delivery itself is unobservable app-side (G3), so there is no
  /// seam to assert `flush()` ran — that is structural (the line after capture).
  @Suite("Telemetry flush reason", .serialized)
  struct TelemetryFlushReasonTests {

    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var events: [CapturedTelemetryEvent] = []
      func append(_ event: CapturedTelemetryEvent) { lock.withLock { events.append(event) } }
      var all: [CapturedTelemetryEvent] { lock.withLock { events } }
    }

    @MainActor
    @Test("flushTelemetry(reason:) emits one telemetry.flush_requested carrying the reason")
    func flushEmitsRequestedEventWithReason() {
      let box = EventBox()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "telemetry.flush_requested" { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.flushTelemetry(reason: .updateInstall)

      #expect(box.all.count == 1)
      #expect(box.all.first?.stringProps["reason"] == "update_install")
    }

    @Test("FlushReason raw values are the bounded expected set")
    func flushReasonRawValuesBounded() {
      // Only `.updateInstall` is live today; future reasons are added with their
      // real call sites (Telemetry Bible Phase 1), never as un-emitted cases.
      #expect(TelemetryService.FlushReason.updateInstall.rawValue == "update_install")
    }
  }

#endif
