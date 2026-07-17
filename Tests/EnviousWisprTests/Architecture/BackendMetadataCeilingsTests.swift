import Foundation
import Testing

/// Architecture ceiling for `BackendMetadata` (PR7 of epic #763).
///
/// Locks the home as the canonical "backend/model display labels" surface:
/// - 3 stored properties (`settings`, `asrManager`, `llmDiscovery`)
/// - 1 non-private method (`statusText(for:)`)
/// - ≤75 lines
/// - imports ⊆ {EnviousWisprASR, EnviousWisprCore, EnviousWisprServices, Observation}
///
/// Computed properties (`modelLabel`, `llmLabel`, `polishLabel`) are NOT
/// counted by the shared parser; only `func` declarations are.
/// `LLMModelDiscoveryCoordinator` is App-local (same target, no Services
/// import needed for it).
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
///
/// Bible §30 entry (#1026, 2026-06-10): line cap 65→75. Reason: fourth
/// display label `polishLabel` (sidebar AI Polish row) — a provider
/// switch ("Off" / "Apple Intelligence" / llmLabel chain) in the
/// ceiling's explicitly uncounted category (computed display label);
/// stored-property, method, and import caps unchanged. The home
/// remains display-only.
///
/// Bible §30 entry (#1386 PR-2b, 2026-07-17): stored properties 3→4 and
/// line cap 75→85. Reason: `activeModelLoaded`, the EngineCoordinator's
/// published truth injected as a closure — the manager's own flag became
/// Parakeet-only when #1386 re-homed WhisperKit, so the "Loaded"/"Unloaded"
/// fallback needed the cross-engine authority (cloud review P2 on PR #1606).
/// The home remains display-only; a closure, not a coordinator reference,
/// keeps the import set unchanged.
@Suite struct BackendMetadataCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/BackendMetadata.swift"

  @Test func storedPropertyCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "BackendMetadata", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 4,
      """
      BackendMetadata stored-property count mismatch: expected exactly 4 \
      (settings + asrManager + llmDiscovery + activeModelLoaded), found \(total). \
      Adding a stored property requires a Bible §30 entry; if this dropped, \
      ratchet down.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "BackendMetadata", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    #expect(
      total == 1,
      """
      BackendMetadata non-private method count mismatch: expected exactly 1 \
      (`statusText(for:)`), found \(total). Computed properties (modelLabel, \
      llmLabel) are not counted. Adding a `func` method requires a Bible §30 entry.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 85,
      """
      BackendMetadata line count exceeded: \(count) > 85. \
      Ratchet down if implementation came in lower; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprASR", "EnviousWisprCore",
      "EnviousWisprServices", "Observation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      BackendMetadata imports outside the allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry.
      """)
  }
}
