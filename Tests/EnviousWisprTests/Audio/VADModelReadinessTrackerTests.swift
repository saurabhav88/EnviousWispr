import Testing

@testable import EnviousWisprAudio

/// #1224: unit coverage for the classify-once / notify-eligible-every-time
/// state machine that decides when the "auto-stop unavailable" notice shows.
/// Pulled out of `AudioServiceHandler` specifically so this logic has real
/// test coverage — that type lives in an XPC service target with no
/// reachable unit-test bundle in this project's Xcode graph (§11 addendum,
/// issue-1224 plan).
@Suite("VADModelReadinessTracker")
struct VADModelReadinessTrackerTests {

  @Test("classifies ready exactly once; a later failure reason is ignored")
  func classifiesReadyOnce() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: nil)
    #expect(tracker.readiness == .ready)

    // A second classification call (should never happen in production, since
    // the caller gates on `.unknown`, but the tracker itself must also be
    // inert here) must not flip an already-`.ready` model to broken.
    tracker.classifyIfNeeded(failureReason: "SomeLaterError")
    #expect(tracker.readiness == .ready)
  }

  @Test("classifies broken exactly once; does not re-attempt or flip to ready")
  func classifiesBrokenOnce() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: "LoadError.resourceNotFound")
    #expect(tracker.readiness == .broken(reason: "LoadError.resourceNotFound"))

    tracker.classifyIfNeeded(failureReason: nil)
    #expect(tracker.readiness == .broken(reason: "LoadError.resourceNotFound"))
  }

  @Test(
    "notice fires on the first eligible recording, not the first failure — council-round-1 regression"
  )
  func noticeFiresOnFirstEligibleRecordingNotFirstFailure() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: "LoadError.loadFailed")

    // Recording N: model just classified broken, but auto-stop is OFF (the
    // ~95% default) — must NOT fire.
    #expect(tracker.shouldShowNotice(autoStopEnabled: false, recordingIsLive: true) == false)

    // Recording N+1: still off — still must not fire.
    #expect(tracker.shouldShowNotice(autoStopEnabled: false, recordingIsLive: true) == false)

    // User turns auto-stop ON before recording N+2 — the notice MUST fire now,
    // despite `.broken` having been set two recordings earlier. This is the
    // exact defect a single fire-at-classification-time latch reintroduces.
    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == true)
  }

  @Test("notice fires at most once ever, even across many more eligible recordings")
  func noticeFiresAtMostOnceEver() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: "LoadError.loadFailed")

    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == true)
    for _ in 0..<10 {
      #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == false)
    }
  }

  @Test("a ready model never shows the notice regardless of auto-stop state")
  func readyModelNeverShowsNotice() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: nil)
    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == false)
    #expect(tracker.shouldShowNotice(autoStopEnabled: false, recordingIsLive: true) == false)
  }

  @Test("an unclassified (still-unknown) model never shows the notice")
  func unknownModelNeverShowsNotice() {
    var tracker = VADModelReadinessTracker()
    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == false)
  }

  @Test(
    "a not-live call (recording already stopped/cancelled) is inert — cloud review PR #1510 regression"
  )
  func notLiveCallDoesNotConsumeTheOneShot() {
    var tracker = VADModelReadinessTracker()
    tracker.classifyIfNeeded(failureReason: "LoadError.loadFailed")

    // Recording N: classification's prepare() raced a near-instant stop —
    // by the time this call lands, the recording is no longer live. Must
    // NOT show the notice, and — critically — must NOT consume the one-shot
    // either, since `noticeShown` becomes permanently unavailable otherwise.
    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: false) == false)
    #expect(tracker.noticeShown == false)

    // Recording N+1: genuinely live this time — the notice must still be
    // available to fire, proving the not-live call above did not burn it.
    #expect(tracker.shouldShowNotice(autoStopEnabled: true, recordingIsLive: true) == true)
  }
}
