// **Release-visible since C6.** This file was `#if DEBUG` for one reason: it read
// `currentPresentationForTesting` and `currentIntent`, both of which lived inside
// `#if DEBUG` on the director. It now reads the render model, which is the
// production surface.
  import AppKit
  import EnviousWisprPipeline
  import Testing

  @testable import EnviousWisprAppKit

  /// #1701 Phase 3 — the bulk-import status pill, and the arbitration that stops a
  /// limb taking a slot the dictation pipeline holds.
  ///
  /// Retargeted from `RecordingOverlayPanel` to `OverlayDirector` in #2292. The
  /// three properties are unchanged. What changed underneath is that arbitration
  /// used to be re-derived at every feature — importStatusOwnsCurrentSlot,
  /// Bluetooth's `isPresented`, the chip's generation — with nothing holding those
  /// three to the same answer; there is now ONE rule, stated once in the reducer:
  /// a feature may occupy the slot only while the pipeline intent is `.hidden`.
  @MainActor
  @Suite("Overlay — bulk-import status pill (#1701 Phase 3)")
  struct OverlayImportStatusTests {

    private static func importMessage(_ d: OverlayDirector) -> String? {
      guard case .notice(let notice)? = d.renderModel.state.presentation?.content,
        notice.kind == .importStatus
      else { return nil }
      return notice.text
    }

    private static func record(_ d: OverlayDirector) {
      d.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0,
            audioLevelProvider: { 0 },
            recordingElapsedProvider: { nil },
            isLocked: false)))
    }

    @Test("a still-pending Importing pill is replaced by Finished, not dropped")
    func pendingImportingReplacedByFinished() {
      let overlay = OverlayTestDouble.headlessDirector()

      // No `await`/suspension between these two calls — this reproduces the exact
      // race a fast (or unavailable-model) drain hits: "Finished" arriving before
      // "Importing" has ever been rendered.
      overlay.present(.importStatus(message: "Importing your words now."))
      overlay.present(.importStatus(message: "Finished importing your words."))

      #expect(Self.importMessage(overlay) == "Finished importing your words.")
    }

    @Test("a live recording refuses import status entirely")
    func pendingRecordingRefusesImportStatus() {
      let overlay = OverlayTestDouble.headlessDirector()

      Self.record(overlay)
      overlay.present(.importStatus(message: "Finished importing your words."))

      guard case .recording? = overlay.renderModel.state.presentation?.content else {
        Issue.record("a limb claimed ownership of a slot a genuine recording holds")
        return
      }
      #expect(
        Self.importMessage(overlay) == nil,
        "a limb must never claim ownership of a slot a genuine recording holds")
    }

    @Test("recording superseding a pending import status leaves no stale ownership")
    func recordingSupersedesPendingImportStatus() {
      let overlay = OverlayTestDouble.headlessDirector()

      overlay.present(.importStatus(message: "Importing your words now."))
      Self.record(overlay)
      overlay.present(.importStatus(message: "Finished importing your words."))

      guard case .recording? = overlay.renderModel.state.presentation?.content else {
        Issue.record("a limb claimed ownership of a slot a genuine recording holds")
        return
      }
      #expect(
        Self.importMessage(overlay) == nil,
        "the stale import token must lose all ownership once recording superseded it")
    }
  }
