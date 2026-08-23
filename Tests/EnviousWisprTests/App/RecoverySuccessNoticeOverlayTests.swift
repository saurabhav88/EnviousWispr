import AppKit
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// #1464 — the crash-recovery SUCCESS notice is a DEDICATED `.recoverySucceeded`
/// intent that must render at LAUNCH, where there is no live recording pill (the
/// `.recovered` path runs from `scanAndRecover`).
///
/// Retargeted from `RecordingOverlayPanel` to `OverlayDirector` in #2292. The
/// property is unchanged and so are the assertions; only the owner moved. The
/// director is HEADLESS — it resolves no screen, so no `NSPanel` is built — and
/// these hold anyway because the reducer's state is what they read. The green
/// pill's pixels are proven by Live UAT, as before.
@Suite @MainActor struct RecoverySuccessNoticeOverlayTests {

  @Test("the success notice is accepted with no prior pill (launch-visible, not a no-op)")
  func recoverySucceededAcceptedFromLaunch() {
    let overlay = OverlayTestDouble.headlessDirector()
    // Nothing shown first — mirrors launch recovery with no live recording.
    overlay.send(.pipeline(.recoverySucceeded), actions: nil)
    #expect(
      overlay.currentIntent == .recoverySucceeded,
      "a dedicated intent routed through the standalone launch-visible notice path")
    overlay.dismissCurrent(.silent)
    #expect(overlay.currentIntent == .hidden)
  }

  @Test("a recording supersedes the success notice synchronously (single slot)")
  func recordingSupersedesSuccessNotice() {
    let overlay = OverlayTestDouble.headlessDirector()
    overlay.send(.pipeline(.recoverySucceeded), actions: nil)
    overlay.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0,
            audioLevelProvider: { 0 },
            recordingElapsedProvider: { nil },
            isLocked: false)))
    #expect(overlay.currentIntent == .recording(audioLevel: 0))
    overlay.dismissCurrent(.silent)
    #expect(overlay.currentIntent == .hidden)
  }
}
