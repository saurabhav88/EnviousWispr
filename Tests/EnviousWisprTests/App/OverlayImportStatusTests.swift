#if DEBUG
  // **DEBUG-only because it reads a `*ForTesting` accessor**, which lives inside
  // `#if DEBUG` on the type it belongs to. Without the guard the RELEASE build of
  // the test target does not compile — which a Debug-only local run cannot see, by
  // construction, and which CI's `build-release` job catches instead.
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
      guard case .notice(let notice)? = d.currentPresentationForTesting?.content,
        notice.kind == .importStatus
      else { return nil }
      return notice.text
    }

    private static func record(_ d: OverlayDirector) {
      d.presentRecording(
        audioLevel: 0, audioLevelProvider: { 0 }, recordingElapsedProvider: { nil },
        isRecordingLocked: false, actions: nil)
    }

    @Test("a still-pending Importing pill is replaced by Finished, not dropped")
    func pendingImportingReplacedByFinished() {
      let overlay = OverlayTestDouble.headlessDirector()

      // No `await`/suspension between these two calls — this reproduces the exact
      // race a fast (or unavailable-model) drain hits: "Finished" arriving before
      // "Importing" has ever been rendered.
      overlay.send(
        .featureRequest(.importStatus(message: "Importing your words now.")), actions: nil)
      overlay.send(
        .featureRequest(.importStatus(message: "Finished importing your words.")), actions: nil)

      #expect(Self.importMessage(overlay) == "Finished importing your words.")
    }

    @Test("a live recording refuses import status entirely")
    func pendingRecordingRefusesImportStatus() {
      let overlay = OverlayTestDouble.headlessDirector()

      Self.record(overlay)
      overlay.send(
        .featureRequest(.importStatus(message: "Finished importing your words.")), actions: nil)

      #expect(overlay.currentIntent == .recording(audioLevel: 0))
      #expect(
        Self.importMessage(overlay) == nil,
        "a limb must never claim ownership of a slot a genuine recording holds")
    }

    @Test("recording superseding a pending import status leaves no stale ownership")
    func recordingSupersedesPendingImportStatus() {
      let overlay = OverlayTestDouble.headlessDirector()

      overlay.send(
        .featureRequest(.importStatus(message: "Importing your words now.")), actions: nil)
      Self.record(overlay)
      overlay.send(
        .featureRequest(.importStatus(message: "Finished importing your words.")), actions: nil)

      #expect(overlay.currentIntent == .recording(audioLevel: 0))
      #expect(
        Self.importMessage(overlay) == nil,
        "the stale import token must lose all ownership once recording superseded it")
    }
  }
#endif
