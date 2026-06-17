import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - VADMonitorLoopTests (#1060)
//
// Unit coverage for the one-shot approaching-cap warning added to the shared
// VAD monitor loop. Drives the XPC branch (detector == nil) with an injected
// `now` clock so threshold crossings are exercised without real-time waits in
// the assertions (the loop's inter-poll sleep still runs, kept to ≤2 iterations).

@MainActor
@Suite struct VADMonitorLoopTests {

  /// Records the loop's callbacks. `@MainActor` so the loop's `@MainActor`
  /// closures mutate it without data races; `keepRecording` flips it off.
  @MainActor final class Recorder {
    var warningRemaining: [TimeInterval] = []
    var stops: [VADStopReason] = []
    var keepRecording = true
    var ticks = 0
  }

  private static let start = Date(timeIntervalSince1970: 1_000_000)

  @Test("warning fires exactly once when elapsed crosses maxDuration - lead")
  func warningFiresOnceAtThreshold() async {
    let rec = Recorder()
    // elapsed 250s: past the 240s threshold (300 - 60), before the 300s cap.
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(250) },
      onApproachingMaxDuration: { remaining in
        rec.warningRemaining.append(remaining)
        rec.keepRecording = false  // exit the loop after the warning
      },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.count == 1)
    #expect(abs((rec.warningRemaining.first ?? 0) - 50) < 0.001)  // 300 - 250
    #expect(rec.stops.isEmpty)
  }

  @Test("no warning when recording stops before the threshold")
  func noWarningIfStoppedEarly() async {
    let rec = Recorder()
    rec.keepRecording = false  // loop body never runs
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(100) },
      onApproachingMaxDuration: { rec.warningRemaining.append($0) },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.isEmpty)
    #expect(rec.stops.isEmpty)
  }

  @Test("no warning when maxDuration is not greater than the lead")
  func noWarningWhenCapTooShort() async {
    let rec = Recorder()
    // maxDuration 30 <= lead 60 → warning disarmed. Run ≤2 body iterations.
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 30, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: {
        rec.ticks += 1
        return rec.ticks <= 2
      },
      now: { Self.start.addingTimeInterval(25) },  // past any threshold, below cap
      onApproachingMaxDuration: { rec.warningRemaining.append($0) },
      onStop: { rec.stops.append($0) }
    )
    #expect(rec.warningRemaining.isEmpty)
    #expect(rec.stops.isEmpty)
  }

  @Test("max-duration stop fires at the cap and pre-empts the warning")
  func stopFiresAtCapBeforeWarning() async {
    let rec = Recorder()
    await VADMonitorLoop.run(
      detector: nil, vadAutoStop: true,
      maxDuration: 300, warningLead: 60,
      recordingStartTime: Self.start,
      sampleProvider: { [] },
      isRecording: { rec.keepRecording },
      now: { Self.start.addingTimeInterval(300) },  // == cap
      onApproachingMaxDuration: {
        rec.warningRemaining.append($0)
        rec.keepRecording = false
      },
      onStop: {
        rec.stops.append($0)
        rec.keepRecording = false
      }
    )
    #expect(rec.stops == [.maxDuration])
    // The cap check precedes the warning check, so no warning fires at exactly the cap.
    #expect(rec.warningRemaining.isEmpty)
  }
}
