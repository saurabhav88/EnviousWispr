import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #4325: when this fails, a Universal download asked for during a meeting never starts when the
/// meeting ends, starts while the transcript is still being written, or starts more than once.
@MainActor
@Suite("Meeting idle observer (#4325)", .tags(.productOutcome))
struct MeetingIdleObserverTests {
  @Observable
  @MainActor
  final class Meeting {
    var recording = false
    var finalPassRunning = false
    var isActive: Bool { recording || finalPassRunning }
  }

  /// The observer's own reads, in order; `reached` resumes on the read itself, and a deadline
  /// fails loudly instead of hanging.
  @MainActor
  final class Reads {
    private(set) var values: [Bool] = []
    private var waiting: (Int, CheckedContinuation<Void, Never>)?

    func record(_ active: Bool) {
      values.append(active)
      if let (n, c) = waiting, values.count >= n {
        waiting = nil
        c.resume()
      }
    }

    func reached(_ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
      if values.count >= n { return }
      let deadline = Task { @MainActor [weak self] in
        // deadline-fallback: fail loudly and release a missing-signal wait.
        try? await Task.sleep(for: .seconds(5))
        // #4343: a cancelled sleep returns at once; without this the stale deadline would
        // fail and release the NEXT wait.
        guard !Task.isCancelled, let self, let (_, c) = self.waiting else { return }
        Issue.record("read #\(n) never happened", sourceLocation: sourceLocation)
        self.waiting = nil
        c.resume()
      }
      await withCheckedContinuation { waiting = (n, $0) }
      deadline.cancel()
    }
  }

  @Test("idle fires once when recording AND the final pass are both done, never before")
  func firesOnTheWholeActivityEnding() async {
    let meeting = Meeting()
    final class Count { var value = 0 }
    let idles = Count()
    let reads = Reads()
    meeting.recording = true
    meeting.finalPassRunning = true
    let observer = MeetingIdleObserver(isActive: { meeting.isActive }, onIdle: { idles.value += 1 })
    observer.onReadForTests = { reads.record($0) }

    // Recording stops while the final pass still runs: still active, no idle.
    meeting.recording = false
    await reads.reached(1)
    #expect(reads.values == [true])
    #expect(idles.value == 0, "the transcript is still being written")

    // The final pass ends: exactly one idle.
    meeting.finalPassRunning = false
    await reads.reached(2)
    #expect(reads.values == [true, false])
    #expect(idles.value == 1)

    // A later meeting starts and ends: one more idle.
    meeting.recording = true
    await reads.reached(3)
    meeting.recording = false
    await reads.reached(4)
    #expect(idles.value == 2)
    // The observer holds itself only weakly in its callbacks (production keeps it on the
    // bootstrapper), so the test keeps it alive to the end.
    withExtendedLifetime(observer) {}
  }
}
