import AppKit
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// #1464 — the crash-recovery SUCCESS notice is a DEDICATED `.recoverySucceeded`
/// overlay intent that must render at LAUNCH, where there is no live recording
/// panel (the `.recovered` path runs from `scanAndRecover`). `currentIntent` is
/// mutated synchronously in `show(intent:)`; panel creation is deferred, so these
/// assertions hold headless. The green-pill pixels are proven by Live UAT.
@Suite @MainActor struct RecoverySuccessNoticeOverlayTests {
  /// `show(intent:)` posts an AX announcement against `NSApp.mainWindow`; touch
  /// `NSApplication.shared` so the headless host has a non-nil `NSApp`.
  init() { _ = NSApplication.shared }

  @Test("the success notice is accepted with no prior panel (launch-visible, not a no-op)")
  func recoverySucceededAcceptedFromLaunch() {
    let overlay = RecordingOverlayPanel()
    // No `show(...)` first — mirrors launch recovery with no live recording panel.
    overlay.show(intent: .recoverySucceeded)
    #expect(
      overlay.currentIntent == .recoverySucceeded,
      "a dedicated intent routed through the standalone launch-visible notice path")
    overlay.hide()
    #expect(overlay.currentIntent == .hidden)
  }

  @Test("a recording supersedes the success notice synchronously (single slot)")
  func recordingSupersedesSuccessNotice() {
    let overlay = RecordingOverlayPanel()
    overlay.show(intent: .recoverySucceeded)
    overlay.show(intent: .recording(audioLevel: 0))
    #expect(overlay.currentIntent == .recording(audioLevel: 0))
    overlay.hide()
    #expect(overlay.currentIntent == .hidden)
  }
}
