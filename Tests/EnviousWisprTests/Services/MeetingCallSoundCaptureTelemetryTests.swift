import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

#if DEBUG
  /// The `meeting.call_sound_capture` row's shape (#4121). When this fails, the weekly
  /// EnviousMeet launch check reads a call-sound property that is missing, renamed or typed
  /// wrong, the row carries something beyond its closed vocabulary, or the rows the call-sound
  /// capture sends never reach PostHog.
  @MainActor
  @Suite(
    "meeting.call_sound_capture: approved typed fields, nothing else (#4121)", .serialized,
    .tags(.observabilityContract))
  struct MeetingCallSoundCaptureTelemetryTests {
    final class Box: @unchecked Sendable {
      // Test-only capture box; the hook is called synchronously inside the emit on this actor.
      var events: [CapturedTelemetryEvent] = []
    }

    private func capture(
      outcome: String, reason: String?, configuredRateHz: Int?, nominalRateHz: Int?,
      measuredRateBucket: String?, outputTransport: String?
    ) -> CapturedTelemetryEvent? {
      let box = Box()
      let service = TelemetryService.shared
      let previous = service.testEventHook
      service.testEventHook = { captured in
        if captured.name == "meeting.call_sound_capture" { box.events.append(captured) }
      }
      defer { service.testEventHook = previous }
      service.trackMeetingCallSoundCapture(
        outcome: outcome, reason: reason, configuredRateHz: configuredRateHz,
        nominalRateHz: nominalRateHz, measuredRateBucket: measuredRateBucket,
        outputTransport: outputTransport)
      #expect(box.events.count == 1, "one emit sends exactly one row")
      return box.events.first
    }

    private func keys(_ row: CapturedTelemetryEvent) -> Set<String> {
      Set(row.stringProps.keys).union(row.intProps.keys).union(row.doubleProps.keys)
        .union(row.boolProps.keys)
    }

    @Test("a populated row: two rates as integers, three strings plus the outcome, nothing else")
    func populated() throws {
      let row = try #require(
        capture(
          outcome: "stopped_rate_mismatch", reason: "rate_mismatch", configuredRateHz: 48_000,
          nominalRateHz: 48_000, measuredRateBucket: "24000", outputTransport: "bluetooth"))
      #expect(
        row.stringProps == [
          "outcome": "stopped_rate_mismatch", "reason": "rate_mismatch",
          "measured_rate_bucket": "24000", "output_transport": "bluetooth",
        ])
      #expect(row.intProps == ["configured_rate_hz": 48_000, "nominal_rate_hz": 48_000])
      #expect(row.doubleProps.isEmpty && row.boolProps.isEmpty)
      #expect(
        keys(row) == [
          "outcome", "reason", "configured_rate_hz", "nominal_rate_hz", "measured_rate_bucket",
          "output_transport",
        ])
    }

    @Test("unknown facts are omitted, never guessed; a missing reason is sent as none")
    func omittedAndNone() throws {
      let row = try #require(
        capture(
          outcome: "stopped_layout", reason: nil, configuredRateHz: nil, nominalRateHz: nil,
          measuredRateBucket: nil, outputTransport: nil))
      #expect(row.stringProps == ["outcome": "stopped_layout", "reason": "none"])
      #expect(keys(row) == ["outcome", "reason"])
    }

    @MainActor @Observable
    final class Received {
      var reports: [CallSoundChangeReport] = []
      var onMainActor = true
    }

    @Test("the wiring hands each change row from the tap's thread to the main actor unchanged")
    func wiringForwardsAcrossTheHop() async {
      let sent = CallSoundChangeReport(
        outcome: "rebuilt", reason: "output_device", configuredRateHz: 24_000,
        nominalRateHz: 24_000, measuredRateBucket: nil, outputTransport: "bluetooth")
      let received = Received()
      let forward = MeetingWiring.callSoundReportForwarder { report in
        received.onMainActor = received.onMainActor && Thread.isMainThread
        received.reports.append(report)
      }
      DispatchQueue.global().async { forward(sent) }
      await MeetingCoordinatorTests.eventually("forwarded") { !received.reports.isEmpty }
      #expect(received.reports == [sent])
      #expect(received.onMainActor)
    }
  }
#endif
