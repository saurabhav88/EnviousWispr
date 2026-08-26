#if DEBUG
  import Testing

  @testable import EnviousWisprAppKit

  /// `withPresentationIntent`'s nesting and per-event defaulting, tested
  /// directly (#2377, C1 repair, cloud review P1).
  ///
  /// **Harness contract, not product outcome.** `OverlayFirstRenderMarkers`
  /// exists only to measure; when this suite fails, no user sees anything —
  /// the benchmark's own evidence becomes untrustworthy instead. The Python
  /// suite proves the ADJUDICATOR reads `intent` correctly from marker text
  /// it fabricates; nothing there can see whether the ambient the Director
  /// sets ever reaches `capture()` correctly through a NESTED scope, or
  /// whether a non-host event stays `.none` no matter what the ambient is —
  /// this file is where those two facts are pinned.
  ///
  /// `emitFirst`'s own state (`pending`, `emittedIntents`) is deliberately
  /// NOT exercised here: it is a once-per-PROCESS latch by design, so a test
  /// calling it would either pollute every other test in this process or
  /// need the kind of DEBUG-only reset hatch this migration exists to
  /// delete. `capture()` and `withPresentationIntent` are pure enough to test
  /// directly without touching that state at all.
  @MainActor
  @Suite(.tags(.harnessContract))
  struct OverlayFirstRenderMarkersIntentTests {

    @Test("a nested scope's intent does not leak into the outer one")
    func nestedScopesRestoreTheOuterIntent() {
      let outerIntent = OverlayFirstRenderMarkers.withPresentationIntent(.recording) {
        () -> OverlayFirstRenderMarkers.Intent in
        let innerIntent = OverlayFirstRenderMarkers.withPresentationIntent(.other) {
          OverlayFirstRenderMarkers.capture(.hostOrderFrontComplete).intent
        }
        #expect(innerIntent == .other, "the inner scope did not see its own intent")
        // The inner scope has returned; the ambient must be back to what the
        // OUTER scope set, not whatever the inner scope left behind.
        return OverlayFirstRenderMarkers.capture(.hostOrderFrontComplete).intent
      }
      #expect(
        outerIntent == .recording,
        "the outer scope's intent did not survive a nested inner scope")
    }

    @Test("non-host events carry .none regardless of the ambient intent")
    func nonHostEventsIgnoreTheAmbientIntent() {
      OverlayFirstRenderMarkers.withPresentationIntent(.recording) {
        #expect(OverlayFirstRenderMarkers.capture(.launchEnter).intent == .none)
        #expect(OverlayFirstRenderMarkers.capture(.launchExit).intent == .none)
        #expect(OverlayFirstRenderMarkers.capture(.rootConstructStart).intent == .none)
        #expect(OverlayFirstRenderMarkers.capture(.rootConstructEnd).intent == .none)
      }
      // TWIN: the same four events under a DIFFERENT ambient intent still
      // read `.none` — proving the exemption is about the EVENT, not about
      // which intent happens to be active when it is read.
      OverlayFirstRenderMarkers.withPresentationIntent(.other) {
        #expect(OverlayFirstRenderMarkers.capture(.launchEnter).intent == .none)
        #expect(OverlayFirstRenderMarkers.capture(.rootConstructEnd).intent == .none)
      }
    }

    @Test("only the host event reads the ambient intent at all")
    func onlyTheHostEventReadsTheAmbientIntent() {
      let hostIntent = OverlayFirstRenderMarkers.withPresentationIntent(.other) {
        OverlayFirstRenderMarkers.capture(.hostOrderFrontComplete).intent
      }
      #expect(hostIntent == .other, "hostOrderFrontComplete did not read the ambient intent")
    }
  }
#endif
