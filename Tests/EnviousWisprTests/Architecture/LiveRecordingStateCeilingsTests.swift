import Foundation
import Testing

/// Architecture ceiling for `LiveRecordingState` (PR7 of epic #763).
///
/// Locks the home as the canonical "live recording facts" surface:
/// - 4 stored properties (`pipeline`, `whisperKitPipeline`, `audioCapture`, `asrManager`)
/// - 0 non-private `func` methods (three computed properties: `pipelineState`,
///   `audioLevel`, `currentTranscript`; computed properties are NOT counted
///   by `CeilingsTestSupport.countNonPrivateMethods`)
/// - ≤100 lines
/// - imports ⊆ {EnviousWisprASR, EnviousWisprAudio, EnviousWisprCore, EnviousWisprPipeline, Observation}
///
/// Ceiling-raise note: stored-property count was raised from 3 to 4 before
/// PR7 was written, after grep verification showed the four current AppState
/// dependencies. Bible §30 entry filed.
///
/// Bible §30 entry (PR-C.3 of #763, 2026-05-20, #815): line ceiling 90 → 100.
/// PR-C.3 adds the `isRecordingLocked` hands-free flag (rehomed off `AppState`)
/// and the `DictationActivityProviding` conformance extension (also off
/// `AppState`). The stored-property count is unchanged (the flag is a primitive
/// `var`, not counted) and no `func` is added (`isDictationActive` is computed).
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
@Suite struct LiveRecordingStateCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/LiveRecordingState.swift"

  @Test func storedPropertyCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "LiveRecordingState", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 4,
      """
      LiveRecordingState stored-property count mismatch: expected exactly 4 \
      (pipeline + whisperKitPipeline + audioCapture + asrManager), found \(total). \
      Adding a stored property requires a Bible §30 entry; if this dropped, \
      ratchet down. The parser counts `let` collaborator declarations with non-\
      primitive types.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "LiveRecordingState", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    // Exact-match 0. Computed properties (pipelineState, audioLevel,
    // currentTranscript) are NOT counted by the parser; only `func`
    // declarations are. PR7 introduces no `func` methods on this home.
    // Adding a `func` here would be the structural signal that
    // LiveRecordingState is accreting start/stop/cancel behavior — which
    // belongs in DictationRuntime (PR10), not here.
    #expect(
      total == 0,
      """
      LiveRecordingState non-private method count mismatch: expected exactly \
      0 (`func` declarations only — computed properties are not counted), \
      found \(total). Adding a `func` method requires a Bible §30 entry — \
      LiveRecordingState must not own start/stop/cancel behavior.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 100,
      """
      LiveRecordingState line count exceeded: \(count) > 100. \
      Ratchet down if implementation came in lower; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprASR", "EnviousWisprAudio",
      "EnviousWisprCore", "EnviousWisprPipeline",
      "Observation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      LiveRecordingState imports outside the allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry.
      """)
  }
}
