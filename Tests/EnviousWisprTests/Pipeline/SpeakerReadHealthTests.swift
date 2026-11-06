import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #4013 reading resilience §3.4: when these fail, `meeting.ended` reports a share of unusable
/// speaker reads from one segment instead of the whole recording, counts skipped ticks as
/// attempts, invents a zero for a counter an older log never kept, or loses the read health
/// between the saved log and the committed summary.
///
/// Logs are SYNTHETIC: segments with hand-written health counts.
@Suite("Speaker read health from the saved log", .tags(.observabilityContract))
struct SpeakerReadHealthTests {

  private func health(
    attempts: Int, unreadable: Int = 0, truncated: Int = 0, unresolved: Int = 0,
    tolerated: Int? = 0, skipped: Int = 0
  ) -> CallCaptureHealth {
    var health = CallCaptureHealth()
    health.captureAttempts = attempts
    health.unreadableCaptures = unreadable
    health.truncatedCaptures = truncated
    health.unresolvedScopeCaptures = unresolved
    health.completeCaptures = attempts - unreadable - truncated
    health.toleratedFailures = tolerated
    health.skippedBusyTicks = skipped
    health.skippedDictationTicks = skipped
    health.missingPermissionTicks = skipped
    return health
  }

  private func segment(_ startMs: Int, _ health: CallCaptureHealth?) -> CallSpeakerSegment {
    CallSpeakerSegment(
      startMs: startMs, endMs: startMs + 1_000, endReason: .sourceChanged, surface: .zoomApp,
      source: .app, status: .observed, lag: CallSpeakerLag(milliseconds: 0), roster: .empty,
      rosterFromParticipantList: false, observations: [], health: health)
  }

  private func log(_ healths: [CallCaptureHealth?]) -> CallSpeakerLog {
    CallSpeakerLog(
      rules: nil,
      segments: healths.enumerated().map { index, health in segment(index * 2_000, health) })
  }

  @Test("segments are summed before any share; skipped ticks are not attempts")
  func summedOverSegments() throws {
    let read = try #require(
      SpeakerReadHealth(
        log: log([
          health(attempts: 10, unreadable: 2, tolerated: 5, skipped: 40),
          nil,
          health(attempts: 0, tolerated: 0, skipped: 9),
          health(attempts: 30, truncated: 1, unresolved: 3, tolerated: 7),
        ])))
    #expect(read.captureAttempts == 40)
    #expect(read.unreadableCaptures == 2)
    #expect(read.truncatedCaptures == 1)
    #expect(read.unresolvedScopeCaptures == 3)
    #expect(read.toleratedFailures == 12)
    #expect(read.unusableShare == 6.0 / 40.0)
    #expect(read.unusableReason == .unresolvedScope)
  }

  @Test("a log with no capture attempt has no read health")
  func noAttempts() {
    #expect(SpeakerReadHealth(log: log([])) == nil)
    #expect(SpeakerReadHealth(log: log([nil, health(attempts: 0, skipped: 50)])) == nil)
  }

  @Test("a segment saved before the tolerated counter leaves that count unknown, not zero")
  func olderSegmentTolerated() throws {
    let read = try #require(
      SpeakerReadHealth(
        log: log([health(attempts: 5, tolerated: nil), health(attempts: 5, tolerated: 3)])))
    #expect(read.toleratedFailures == nil)
    #expect(read.captureAttempts == 10)
    // A segment that never walked does not make the count unknown.
    let quiet = try #require(
      SpeakerReadHealth(
        log: log([health(attempts: 0, tolerated: nil), health(attempts: 5, tolerated: 3)])))
    #expect(quiet.toleratedFailures == 3)
  }

  /// A segment whose copies were all dropped at delivery has walks but no attempt; what those
  /// walks tolerated still counts.
  @Test("tolerated failures from a segment with walks but no attempt are still summed")
  @MainActor func droppedCopiesStillCount() throws {
    var dropped = health(attempts: 0, tolerated: 150)
    dropped.walkDurationCount = 3
    let read = try #require(
      SpeakerReadHealth(log: log([health(attempts: 4, tolerated: 2), dropped])))
    #expect(read.captureAttempts == 4)
    #expect(read.toleratedFailures == 152)
    #expect(TelemetryService.speakerToleratedBucket(try #require(read.toleratedFailures)) == "100-999")
    // The same dropped segment saved before the counter makes the sum unknown.
    var older = dropped
    older.toleratedFailures = nil
    #expect(
      SpeakerReadHealth(log: log([health(attempts: 4, tolerated: 2), older]))?.toleratedFailures
        == nil)
  }

  /// #4436: walks are counted before a stale copy is dropped, so the skipped-page share's
  /// denominator is walks, never capture attempts (one stale walk: 2 refused walks, 1 attempt).
  @Test("skipped pages are summed over walks, unknown when an old segment walked without them")
  func skippedPagesOverWalks() throws {
    var fresh = health(attempts: 1)
    fresh.walkDurationCount = 2
    fresh.skippedPageCaptures = 2
    var quiet = health(attempts: 3)
    quiet.walkDurationCount = 3
    let read = try #require(SpeakerReadHealth(log: log([fresh, quiet])))
    #expect(read.walkDurationCount == 5)
    #expect(read.skippedPageCaptures == 2)
    #expect(read.skippedPageShare == 2.0 / 5.0)
    var older = quiet
    older.skippedPageCaptures = nil
    let unknown = try #require(SpeakerReadHealth(log: log([fresh, older])))
    #expect(unknown.skippedPageCaptures == nil)
    #expect(unknown.skippedPageShare == nil)
    // A segment that never walked adds zero, not unknown.
    var idle = health(attempts: 0)
    idle.skippedPageCaptures = nil
    #expect(SpeakerReadHealth(log: log([fresh, idle]))?.skippedPageCaptures == 2)
    // Attempts with no recorded walk: no share.
    #expect(SpeakerReadHealth(log: log([health(attempts: 2)]))?.skippedPageShare == nil)
    let saved = log([fresh])
    let decoded = try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(saved))
    #expect(decoded.segments.first?.health?.skippedPageCaptures == 2)
  }

  @Test("the tolerated counter survives the saved log's round trip")
  func logRoundTrip() throws {
    let saved = log([health(attempts: 4, unreadable: 1, tolerated: 9)])
    let read = try JSONDecoder().decode(CallSpeakerLog.self, from: JSONEncoder().encode(saved))
    #expect(read.segments.first?.health?.toleratedFailures == 9)
    #expect(SpeakerReadHealth(log: read) == SpeakerReadHealth(log: saved))
  }

  @Test("every pass from a log carries its read health into the committed summary only")
  @MainActor func passToCommittedSummary() throws {
    let saved = log([health(attempts: 8, unreadable: 2, tolerated: 4)])
    let expected = try #require(SpeakerReadHealth(log: saved))
    let abstained = MeetingNamingResult(proposals: [:], outcome: .noSignal).pass(log: saved)
    #expect(abstained == .abstained(surface: .zoomApp, outcome: .noSignal, readHealth: expected))
    let proposed = MeetingNamingResult(proposals: ["sys:S1": "Alex Rivera"], outcome: .named)
      .pass(log: saved)
    #expect(proposed == .proposed(surface: .zoomApp, count: 1, readHealth: expected))
    #expect(
      MeetingNamingResult(proposals: [:], outcome: .noLog).pass(log: nil)
        == .abstained(surface: nil, outcome: nil, readHealth: nil))
    let row = Transcript(
      id: UUID(), text: "x", backendType: .parakeet, speakerAnalysis: .labeled(count: 1),
      turns: [])
    let pending = PendingSpeakerNamingSummary(proposed: row, reconciled: row, pass: abstained)
    #expect(pending.committed(.written)?.readHealth == expected)
    #expect(pending.committed(.failed) == nil)
    #expect(pending.committed(.unknown) == nil)
  }
}
