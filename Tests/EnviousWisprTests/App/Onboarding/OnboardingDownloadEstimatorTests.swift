import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4845 D-A: the time left on Getting ready, from the measured download speed.
///
/// **Product Outcome.** When this fails, a person on slow internet is told the wrong time left,
/// sees the Skip ahead offer too late or not at all, or a person on fast internet is offered to
/// skip a download that is about to finish.
@Suite(.tags(.productOutcome))
struct OnboardingDownloadEstimatorTests {
  private static let mb: Int64 = 1_000_000

  private static func speech(
    _ phase: OnboardingDownloadPhase, done: Int64?, total: Int64? = 600 * mb
  ) -> OnboardingDownloadSnapshot.Pick {
    .init(id: "speech:parakeet", phase: phase, downloadedBytes: done, totalBytes: total)
  }

  private static func polish(
    _ phase: OnboardingDownloadPhase, done: Int64?, total: Int64? = 2_000 * mb,
    id: String = "polish:eg1.mini"
  ) -> OnboardingDownloadSnapshot.Pick {
    .init(id: id, phase: phase, downloadedBytes: done, totalBytes: total)
  }

  @Test("no estimate until a full 10 second window has been measured")
  func unknownUntilMeasured() {
    var e = OnboardingDownloadEstimator()
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.1), done: 200 * Self.mb)), at: 0)
    #expect(e.secondsLeft == nil)
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.15), done: 300 * Self.mb)), at: 5)
    #expect(e.secondsLeft == nil)
  }

  @Test("a steady download gives time left as remaining bytes over the measured speed")
  func steadyEstimate() throws {
    // 10 MB/s; 1,800 MB left at t = 10 → 180 s.
    var e = OnboardingDownloadEstimator()
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.05), done: 100 * Self.mb)), at: 0)
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.1), done: 200 * Self.mb)), at: 10)
    let left = try #require(e.secondsLeft)
    #expect(abs(left - 180) < 0.001)
  }

  @Test("the speech download's speed carries into the queued polish download, through the gap")
  func serialCarry() throws {
    // When this fails, the offer waits a full minute for a polish download whose speed is
    // already known from the speech download on the same connection.
    var e = OnboardingDownloadEstimator()
    let queued = Self.polish(.notStarted, done: nil)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.5), done: 300 * Self.mb), polish: queued,
        queuedPolishID: "eg1.mini"), at: 0)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.6), done: 360 * Self.mb), polish: queued,
        queuedPolishID: "eg1.mini"), at: 10)  // 6 MB/s; left = 240 MB speech + 2,000 MB polish
    #expect(abs(try #require(e.secondsLeft) - 2_240.0 / 6.0) < 0.01)
    // Gap: speech verifying, polish still queued.
    e.record(
      .init(speech: Self.speech(.verifying, done: nil), polish: queued, queuedPolishID: "eg1.mini"),
      at: 12)
    #expect(abs(try #require(e.secondsLeft) - 2_000.0 / 6.0) < 0.01)
    // Polish starts: no full window of its own yet, the carried 6 MB/s still answers.
    e.record(
      .init(
        speech: Self.speech(.installed, done: nil),
        polish: Self.polish(.downloading(fraction: 0.01), done: 20 * Self.mb)), at: 14)
    #expect(abs(try #require(e.secondsLeft) - 1_980.0 / 6.0) < 0.01)
  }

  @Test("a change in which downloads run resets the measurement unless it is the serial handover")
  func setChangeResets() {
    var e = OnboardingDownloadEstimator()
    // Both running in parallel, then speech finishes: not the serial case, so no carry.
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.5), done: 300 * Self.mb),
        polish: Self.polish(.downloading(fraction: 0.1), done: 200 * Self.mb)), at: 0)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.6), done: 360 * Self.mb),
        polish: Self.polish(.downloading(fraction: 0.12), done: 240 * Self.mb)), at: 10)
    #expect(e.secondsLeft != nil)
    e.record(
      .init(
        speech: Self.speech(.installed, done: nil),
        polish: Self.polish(.downloading(fraction: 0.13), done: 260 * Self.mb)), at: 12)
    #expect(e.secondsLeft == nil)
  }

  @Test("a polish download that never waited in the queue does not inherit the speech speed")
  func directHandoffWithoutQueueDoesNotCarry() {
    // When this fails, a polish download that started on its own shows the speech download's
    // time left and can trigger the offer early.
    var e = OnboardingDownloadEstimator()
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.5), done: 300 * Self.mb),
        polish: Self.polish(.verifying, done: nil)), at: 0)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.6), done: 360 * Self.mb),
        polish: Self.polish(.verifying, done: nil)), at: 10)
    e.record(
      .init(
        speech: Self.speech(.installed, done: nil),
        polish: Self.polish(.downloading(fraction: 0.01), done: 20 * Self.mb)), at: 12)
    #expect(e.secondsLeft == nil)
  }

  @Test("a new polish pick or a reopened window drops what was measured")
  func pickChangeAndNewVisitDrop() {
    var e = OnboardingDownloadEstimator()
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.05), done: 100 * Self.mb)), at: 0)
    e.record(.init(polish: Self.polish(.downloading(fraction: 0.1), done: 200 * Self.mb)), at: 10)
    #expect(e.secondsLeft != nil)
    var picked = e
    picked.record(
      .init(
        polish: Self.polish(.downloading(fraction: 0.01), done: 50 * Self.mb, id: "polish:eg1.full")
      ),
      at: 12)
    #expect(picked.secondsLeft == nil)
    var reopened = e
    reopened.newVisit()
    reopened.record(
      .init(polish: Self.polish(.downloading(fraction: 0.11), done: 220 * Self.mb)), at: 12)
    #expect(reopened.secondsLeft == nil)
  }

  @Test("a running download with no new bytes for 30 seconds loses its carried estimate")
  func stallExpires() throws {
    // When this fails, a polish download that never really started keeps showing the speech
    // download's time left forever.
    var e = OnboardingDownloadEstimator()
    let queued = Self.polish(.notStarted, done: nil)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.5), done: 300 * Self.mb), polish: queued,
        queuedPolishID: "eg1.mini"), at: 0)
    e.record(
      .init(
        speech: Self.speech(.downloading(fraction: 0.6), done: 360 * Self.mb), polish: queued,
        queuedPolishID: "eg1.mini"), at: 10)
    let stuck = Self.polish(.downloading(fraction: 0), done: 0)
    e.record(.init(speech: Self.speech(.installed, done: nil), polish: stuck), at: 14)
    #expect(e.secondsLeft != nil)  // carried 6 MB/s
    e.record(.init(speech: Self.speech(.installed, done: nil), polish: stuck), at: 43)
    #expect(e.secondsLeft != nil)  // 29 s without bytes: still carried
    e.record(.init(speech: Self.speech(.installed, done: nil), polish: stuck), at: 44)
    #expect(e.secondsLeft == nil)  // 30 s without bytes: stalled
  }

  @Test("unknown sizes or a paused download give no estimate")
  func unknownRemaining() {
    var e = OnboardingDownloadEstimator()
    e.record(
      .init(polish: Self.polish(.downloading(fraction: 0.05), done: 100 * Self.mb, total: nil)),
      at: 0)
    e.record(
      .init(polish: Self.polish(.downloading(fraction: 0.1), done: 200 * Self.mb, total: nil)),
      at: 10)
    #expect(e.secondsLeft == nil)
    #expect(
      OnboardingDownloadEstimator.remainingBytes(.init(polish: Self.polish(.paused, done: nil)))
        == nil)
  }
}
