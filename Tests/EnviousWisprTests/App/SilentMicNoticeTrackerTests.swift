import EnviousWisprAudio
import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4841: the silent-mic notice policy. Expected values are literal sample
/// counts at 16 kHz (5 s = 80,000; 6 s = 96,000; 15 s = 240,000), never the
/// production constants, so a changed threshold fails here.
///
/// Product Outcome: when these fail, the pill warns too early (annoying a user
/// who paused to think), too late, or not at all when the microphone is silent.
@Suite("Silent-mic notice policy (#4841)", .tags(.productOutcome))
struct SilentMicNoticeTrackerTests {

  private func level(_ samples: Int, sinceStart: Bool, enabled: Bool = true) -> MicSilenceLevel {
    SilentMicNoticePolicy.level(
      for: ExactZeroRun(sampleCount: samples, sinceTakeStart: sinceStart),
      warningsEnabled: enabled)
  }

  @Test("mid-take: calm at exactly 5 s, not one sample before")
  func midTakeCalmBoundary() {
    #expect(level(79_999, sinceStart: false) == .none)
    #expect(level(80_000, sinceStart: false) == .calm)
    #expect(level(80_001, sinceStart: false) == .calm)
  }

  @Test("silent since start: calm at exactly 6 s, so 5 s is still quiet")
  func sinceStartCalmBoundary() {
    #expect(level(80_000, sinceStart: true) == .none)
    #expect(level(95_999, sinceStart: true) == .none)
    #expect(level(96_000, sinceStart: true) == .calm)
    #expect(level(96_001, sinceStart: true) == .calm)
  }

  @Test("strong at exactly 15 s, for both kinds of run")
  func strongBoundary() {
    for sinceStart in [false, true] {
      #expect(level(239_999, sinceStart: sinceStart) == .calm)
      #expect(level(240_000, sinceStart: sinceStart) == .strong)
      #expect(level(240_001, sinceStart: sinceStart) == .strong)
    }
  }

  @Test("warnings switched off show nothing, even during a strong run")
  func warningsOffShowNothing() {
    #expect(level(240_000, sinceStart: false, enabled: false) == .none)
    #expect(level(96_000, sinceStart: true, enabled: false) == .none)
  }

  @Test("no reading (not capturing) shows nothing")
  func missingReadingShowsNothing() {
    #expect(SilentMicNoticePolicy.level(for: nil, warningsEnabled: true) == .none)
  }

  @Test("sound returning clears the level, and a later run starts again from zero")
  func recoveryClearsAndAFreshRunIsEvaluatedAfresh() {
    #expect(level(240_000, sinceStart: false) == .strong)
    // Sound arrived: the live run resets to zero.
    #expect(level(0, sinceStart: false) == .none)
    // A new silence mid-take must reach 5 s again before warning.
    #expect(level(79_999, sinceStart: false) == .none)
    #expect(level(80_000, sinceStart: false) == .calm)
  }
}

/// #4841: the tracker that drives the notice for one running take, stepped one poll at a
/// time against a recording overlay double (no clock, no window).
@MainActor
@Suite("Silent-mic notice tracker (#4841)", .tags(.productOutcome))
struct SilentMicNoticeTrackerDrivingTests {

  /// Mirrors the director's fenced notice API and its one notice field.
  final class FakeOverlay: SilentMicNoticeOverlay {
    var presentation: PresentationID? = PresentationID()
    var notice: RecordingNoticeReason?
    var posts: [RecordingNoticeReason] = []
    var clears = 0
    var currentRecordingPresentationID: PresentationID? { presentation }
    var currentInPanelNoticeKind: RecordingNoticeKind? { notice?.kind }
    func showInPanelNotice(
      _ reason: RecordingNoticeReason, dismissAfter: Double?, on presentation: PresentationID
    ) -> PresentationID? {
      guard presentation == self.presentation else { return nil }
      notice = reason
      posts.append(reason)
      return presentation
    }
    func clearInPanelNotice(_ kind: RecordingNoticeKind, on presentation: PresentationID) -> Bool {
      guard presentation == self.presentation, notice?.kind == kind else { return false }
      notice = nil
      clears += 1
      return true
    }
  }

  final class Rig {
    var run: ExactZeroRun? = ExactZeroRun(sampleCount: 0, sinceTakeStart: false)
    var session: UInt64 = 7
    var notices: [(String, Bool)] = []
    var cleared: [String] = []
  }

  private func make(_ rig: Rig, _ overlay: FakeOverlay) -> SilentMicNoticeTracker {
    SilentMicNoticeTracker(
      readRun: { rig.run }, currentCaptureSessionID: { rig.session }, overlay: overlay,
      recordNotice: { rig.notices.append(($0, $1)) }, recordCleared: { rig.cleared.append($0) },
      startsPolling: false)
  }

  private func silent(_ samples: Int, start: Bool = false) -> ExactZeroRun {
    ExactZeroRun(sampleCount: samples, sinceTakeStart: start)
  }

  @Test("calm at 5 s, strong at 15 s, cleared when sound returns, one post per level")
  func calmStrongThenRecovery() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)

    rig.run = silent(79_999)
    tracker.tick()
    #expect(overlay.posts.isEmpty)
    rig.run = silent(80_000)
    tracker.tick()
    tracker.tick()
    #expect(overlay.posts == [.micSilent(.calm)], "one post per level change")
    rig.run = silent(240_000)
    tracker.tick()
    #expect(overlay.posts == [.micSilent(.calm), .micSilent(.strong)])
    rig.run = silent(0)
    tracker.tick()

    #expect(overlay.notice == nil)
    #expect(overlay.clears == 1)
    #expect(rig.cleared == ["A"])
    #expect(rig.notices.map(\.1) == [false, true])
    #expect(rig.notices.allSatisfy { $0.0 == "A" })
  }

  @Test("silent from the start waits for 6 s")
  func silentFromStartWaitsSixSeconds() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(80_000, start: true)
    tracker.tick()
    #expect(overlay.posts.isEmpty)
    rig.run = silent(96_000, start: true)
    tracker.tick()
    #expect(overlay.posts == [.micSilent(.calm)])
  }

  @Test("a take frozen with warnings off shows nothing")
  func frozenOffShowsNothing() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: false)
    rig.run = silent(240_000)
    tracker.tick()
    #expect(tracker.binding == nil)
    #expect(overlay.posts.isEmpty)
  }

  @Test("a timed notice keeps its dwell; silence shows again on the poll after it leaves")
  func timedNoticeKeepsItsDwell() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(80_000)
    tracker.tick()
    overlay.notice = .secureInputActive  // a timed notice replaced ours
    tracker.tick()
    #expect(overlay.notice == .secureInputActive, "the timed notice was not displaced")
    overlay.notice = nil  // its dwell ended
    tracker.tick()
    #expect(overlay.notice == .micSilent(.calm))
    #expect(overlay.posts == [.micSilent(.calm), .micSilent(.calm)])
  }

  @Test("the 60-minute warning is never replaced, and its clear is never recorded as recovery")
  func capWarningWins() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    overlay.notice = .approachingCap
    rig.run = silent(240_000)
    tracker.tick()
    #expect(overlay.notice == .approachingCap)
    rig.run = silent(0)
    tracker.tick()
    #expect(overlay.notice == .approachingCap)
    #expect(overlay.clears == 0)
    #expect(rig.cleared.isEmpty)
  }

  @Test("a competing notice that replaced ours is not recorded as cleared when sound returns")
  func replacedNoticeIsNotCleared() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(80_000)
    tracker.tick()
    overlay.notice = .secureInputActive
    rig.run = silent(0)
    tracker.tick()
    #expect(rig.cleared.isEmpty)
    #expect(overlay.notice == .secureInputActive)
  }

  @Test("a new pill or a new capture session ends the binding; nothing reaches the new take")
  func staleBindingStops() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    overlay.presentation = PresentationID()  // the take's pill was replaced
    rig.run = silent(240_000)
    tracker.tick()
    #expect(tracker.binding == nil)
    #expect(overlay.posts.isEmpty)

    tracker.start(takeID: "B", warningsEnabled: true)
    rig.session = 8  // capture went away mid-take
    tracker.tick()
    #expect(tracker.binding == nil)
    #expect(overlay.posts.isEmpty)
  }

  @Test("re-binding the same take keeps the shown level (hands-free lock, repeated state)")
  func sameTakeRebindKeepsState() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(80_000)
    tracker.tick()
    tracker.start(takeID: "A", warningsEnabled: true)
    #expect(tracker.shownLevel == .calm)
    tracker.tick()
    #expect(overlay.posts == [.micSilent(.calm)], "no duplicate post after a re-bind")
  }

  @Test("capture lost mid-warning (no reading, same IDs) ends tracking and records no clear")
  func captureLossIsNotRecovery() {
    let rig = Rig(), overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(240_000); tracker.tick()
    #expect(overlay.notice == .micSilent(.strong))
    rig.run = nil  // capture stopped; session and pill unchanged
    tracker.tick()
    #expect(tracker.binding == nil)
    #expect(rig.cleared.isEmpty, "a lost reading is never recorded as sound returning")
    #expect(overlay.clears == 0)
    #expect(rig.notices.map(\.1) == [true])
  }

  @Test(
    "a running poll never keeps the tracker alive once its owner lets go (coordinator teardown)")
  func runningPollDoesNotRetainTheTracker() async {
    let rig = Rig()
    let overlay = FakeOverlay()
    var tracker: SilentMicNoticeTracker? = SilentMicNoticeTracker(
      readRun: { rig.run }, currentCaptureSessionID: { rig.session }, overlay: overlay,
      recordNotice: { _, _ in }, recordCleared: { _ in },
      pause: { await Task.yield() })
    weak let watched = tracker
    tracker?.start(takeID: "A", warningsEnabled: true)
    #expect(watched?.binding != nil)
    // Let the poll run a few ticks so it is mid-loop, not still unscheduled.
    for _ in 0..<5 { await Task.yield() }
    tracker = nil
    #expect(watched == nil, "the poll must not hold the tracker across its pause")
  }

  @Test("stop at 15 s records strong and no clear")
  func strongAtStop() {
    let rig = Rig()
    let overlay = FakeOverlay()
    let tracker = make(rig, overlay)
    tracker.start(takeID: "A", warningsEnabled: true)
    rig.run = silent(240_000)
    tracker.tick()
    tracker.stop()
    #expect(rig.notices.map(\.1) == [true])
    #expect(rig.cleared.isEmpty)
    #expect(overlay.clears == 0, "stop never clears: the pill leaves with the take")
  }
}
