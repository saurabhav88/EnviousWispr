import EnviousWisprServices
import Foundation
import Testing

#if DEBUG

  /// Telemetry Bible Phase 0 (#1169) + Phase 1 (#1170): `flushTelemetry(reason:)`
  /// must emit `telemetry.flush_requested` carrying the reason (request-attempted,
  /// not delivery — delivery is unobservable app-side, G3) plus the Phase 1
  /// diagnostic context `active_recording` / `app_phase`, sourced from the
  /// `flushContextProvider` closure with a `(false, "unknown")` fallback.
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
      TelemetryService.shared.flushContextProvider = nil
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
      // `.updateInstall` (Sparkle pre-relaunch) + `.appTerminate` (normal quit,
      // Phase 1) are the only live reasons; a crash reason is intentionally absent.
      #expect(TelemetryService.FlushReason.updateInstall.rawValue == "update_install")
      #expect(TelemetryService.FlushReason.appTerminate.rawValue == "app_terminate")
    }

    @MainActor
    @Test("flushTelemetry falls back to (false, unknown) when no context provider is wired")
    func flushUsesFallbackContextWhenProviderNil() {
      let box = EventBox()
      TelemetryService.shared.flushContextProvider = nil
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "telemetry.flush_requested" { box.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }

      TelemetryService.shared.flushTelemetry(reason: .appTerminate)

      #expect(box.all.count == 1)
      let event = box.all.first
      #expect(event?.stringProps["reason"] == "app_terminate")
      #expect(event?.boolProps["active_recording"] == false)
      #expect(event?.stringProps["app_phase"] == "unknown")
    }

    @MainActor
    @Test("flushTelemetry carries active_recording / app_phase from the context provider")
    func flushCarriesProviderContext() {
      let box = EventBox()
      TelemetryService.shared.flushContextProvider = {
        TelemetryService.FlushContext(activeRecording: true, appPhase: "recording")
      }
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name == "telemetry.flush_requested" { box.append(event) }
      }
      defer {
        TelemetryService.shared.testEventHook = nil
        TelemetryService.shared.flushContextProvider = nil
      }

      TelemetryService.shared.flushTelemetry(reason: .appTerminate)

      #expect(box.all.count == 1)
      let event = box.all.first
      #expect(event?.boolProps["active_recording"] == true)
      #expect(event?.stringProps["app_phase"] == "recording")
    }
  }

#endif
