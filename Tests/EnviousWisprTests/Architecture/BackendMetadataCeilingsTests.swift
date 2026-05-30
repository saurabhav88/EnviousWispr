import Foundation
import Testing

/// Architecture ceiling for `BackendMetadata` (PR7 of epic #763).
///
/// Locks the home as the canonical "backend/model display labels" surface:
/// - 3 stored properties (`settings`, `asrManager`, `llmDiscovery`)
/// - 1 non-private method (`statusText(for:)`)
/// - ≤65 lines
/// - imports ⊆ {EnviousWisprASR, EnviousWisprCore, EnviousWisprServices, Observation}
///
/// Computed properties (`modelLabel`, `llmLabel`) are NOT counted by the
/// shared parser; only `func` declarations are. `LLMModelDiscoveryCoordinator`
/// is App-local (same target, no Services import needed for it).
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
@Suite struct BackendMetadataCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/BackendMetadata.swift"

  @Test func storedPropertyCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "BackendMetadata", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 3,
      """
      BackendMetadata stored-property count mismatch: expected exactly 3 \
      (settings + asrManager + llmDiscovery), found \(total). \
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
      count <= 65,
      """
      BackendMetadata line count exceeded: \(count) > 65. \
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
