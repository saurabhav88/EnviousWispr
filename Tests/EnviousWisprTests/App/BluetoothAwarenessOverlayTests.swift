// **Release-visible since C6.** This file was `#if DEBUG` for one reason: it read
// `currentIntent` and `currentPresentationForTesting`, both of which lived inside
// `#if DEBUG` on the director. It now reads the render model, which is the
// production surface, so the Release lane executes these cases instead of
// silently excluding them.
import AppKit
  import EnviousWisprPipeline
  import Testing

  @testable import EnviousWisprAppKit

  /// #1480 — the Bluetooth card is a normal single-slot occupant: a recording must
  /// supersede it synchronously, and it must never linger in the intent state.
  ///
  /// Retargeted from `RecordingOverlayPanel` to `OverlayDirector` in #2292. The
  /// properties are unchanged. Two things in the old preamble no longer apply and
  /// are removed rather than carried: the card is now a feature request rather
  /// than a pipeline intent, and the suite no longer has to touch
  /// `NSApplication.shared` to stop an accessibility post crashing a headless host,
  /// because the headless director's announcement seam goes nowhere.
  @Suite @MainActor struct BluetoothAwarenessOverlayTests {

    @Test func recordingSupersedesBluetoothCardSynchronously() {
      let overlay = OverlayTestDouble.headlessDirector()
      overlay.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
      // **This once asserted `.hidden` and that is what hid the defect.** A
      // feature does not change the pipeline intent, which is true and was the
      // wrong question: the presenter had to confirm its own card before acting
      // on any button, so reporting hidden left every one of them a no-op. The
      // test agreed with the code because both were written from the same
      // assumption. Asking what is ON SCREEN cannot go wrong that way — there is
      // no projection to get right, only the pill the user is looking at.
      guard case .bluetoothAwareness? = overlay.renderModel.presentation?.content else {
        Issue.record("the Bluetooth card did not take the slot")
        return
      }

      overlay.present(
        .recording(
          RecordingPillInput(
            audioLevel: 0,
            audioLevelProvider: { 0 },
            recordingElapsedProvider: { nil },
            isLocked: false)))
      guard case .recording? = overlay.renderModel.presentation?.content else {
        Issue.record("the recording pill did not supersede the card")
        return
      }

      overlay.dismissCurrent(.silent)
      #expect(
        overlay.renderModel.presentation == nil,
        "a dismissed slot still shows a pill")
    }

    @Test func hideClearsBluetoothCard() {
      let overlay = OverlayTestDouble.headlessDirector()
      overlay.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
      overlay.dismissCurrent(.silent)
      #expect(overlay.renderModel.presentation == nil)
    }
  }
