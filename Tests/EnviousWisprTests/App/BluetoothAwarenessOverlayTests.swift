#if DEBUG
// **DEBUG-only because it reads a `*ForTesting` accessor**, which lives inside
// `#if DEBUG` on the type it belongs to. Without the guard the RELEASE build of
// the test target does not compile — which a Debug-only local run cannot see, by
// construction, and which CI's `build-release` job catches instead.
  import AppKit
  import EnviousWisprPipeline
  import Testing

  @testable import EnviousWisprAppKit

  /// #1480 — the Bluetooth card is a normal single-slot occupant: a recording must
  /// supersede it synchronously, and it must never linger in the intent state.
  ///
  /// Retargeted from `RecordingOverlayPanel` to `OverlayDirector` in #2292. The
  /// properties are unchanged. Two things in the old preamble no longer apply and
  /// are removed rather than carried: the card is now a `.featureRequest` rather
  /// than a pipeline intent, and the suite no longer has to touch
  /// `NSApplication.shared` to stop an accessibility post crashing a headless host,
  /// because the headless director's announcement seam goes nowhere.
  @Suite @MainActor struct BluetoothAwarenessOverlayTests {

    @Test func recordingSupersedesBluetoothCardSynchronously() {
      let overlay = OverlayTestDouble.headlessDirector()
      overlay.send(.featureRequest(.bluetoothAwareness), actions: nil)
      // **This asserted `.hidden` and that is what hid the defect.** A feature
      // does not change the pipeline intent, which is true and was the wrong
      // question: `BluetoothAwarenessPresenter` asks `currentIntent` for
      // `.bluetoothAwareness` to confirm its own card before acting on any
      // button, so reporting hidden left every one of them a no-op. The test
      // agreed with the code because both were written from the same assumption.
      #expect(overlay.currentIntent == .bluetoothAwareness)
      guard case .bluetoothAwareness? = overlay.currentPresentationForTesting?.content else {
        Issue.record("the Bluetooth card did not take the slot")
        return
      }

      overlay.presentRecording(
        audioLevel: 0, audioLevelProvider: { 0 }, recordingElapsedProvider: { nil },
        isRecordingLocked: false, actions: nil)
      #expect(overlay.currentIntent == .recording(audioLevel: 0))

      overlay.dismissSilently()
      #expect(overlay.currentIntent == .hidden)
      #expect(overlay.currentPresentationForTesting == nil)
    }

    @Test func hideClearsBluetoothCard() {
      let overlay = OverlayTestDouble.headlessDirector()
      overlay.send(.featureRequest(.bluetoothAwareness), actions: nil)
      overlay.dismissSilently()
      #expect(overlay.currentPresentationForTesting == nil)
    }
  }
#endif
