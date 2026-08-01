import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #1635: the WhisperKit setup row's copy contract.
///
/// These strings are founder-frozen (2026-08-01) and one of them states a DURATION derived
/// from production telemetry. A silent edit to either would either break a promise made on
/// screen or reintroduce the "Model Ready" lie this issue exists to fix, so both are pinned
/// verbatim here and a change must be a conscious act.
struct ModelPreparingCopyTests {

  @Test("both user-facing strings are frozen verbatim")
  func stringsAreFrozen() {
    #expect(
      ModelPreparingCopy.preparing
        == "Getting the model ready. This usually takes about 30 seconds.")
    #expect(ModelPreparingCopy.ready == "Model Ready")
  }

  /// The duration in the copy is only honest for the population `warmInFlight` describes
  /// (coordinator-owned post-switch warms, p50 27.4s). If someone widens the state to cover
  /// launch or cold-press warms, this mapping test cannot detect it. The canonical copy
  /// comment records that population and copy must be reviewed together.
  @Test("only WhisperKit's own warm shows the preparing copy")
  func whisperKitWarmShowsPreparing() {
    #expect(ModelPreparingCopy.isPreparing(warmInFlight: .whisperKit))
    #expect(ModelPreparingCopy.label(warmInFlight: .whisperKit) == ModelPreparingCopy.preparing)
  }

  /// Two-way control. Without these the mapping could return preparing unconditionally and
  /// the freeze test above would still pass, leaving a permanent spinner over a ready model.
  @Test("no warm, or another engine's warm, leaves the settled label untouched")
  func othersShowReady() {
    #expect(ModelPreparingCopy.isPreparing(warmInFlight: nil) == false)
    #expect(ModelPreparingCopy.label(warmInFlight: nil) == ModelPreparingCopy.ready)

    // Parakeet warming must not relabel WhisperKit's row. `selectedReadiness` describes
    // whichever engine the user picked, and this label lives in the WhisperKit section.
    #expect(ModelPreparingCopy.isPreparing(warmInFlight: .parakeet) == false)
    #expect(ModelPreparingCopy.label(warmInFlight: .parakeet) == ModelPreparingCopy.ready)
  }

  /// A missing coordinator (previews, tests without the environment) arrives as `nil` and
  /// must fail toward the shipped copy. A stuck "preparing" would be a new lie with no exit.
  @Test("a missing coordinator falls back to Model Ready")
  func missingCoordinatorFallsBackToReady() {
    let absent: ASRBackendType? = nil
    #expect(ModelPreparingCopy.label(warmInFlight: absent) == "Model Ready")
  }
}
