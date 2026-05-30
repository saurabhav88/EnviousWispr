import Foundation
import Testing

/// Architecture ceiling for `DiagnosticsCoordinator` (PR3 of epic #763, backfilled in PR5).
///
/// PR3 (#768/#769) shipped before per-home ceiling discipline existed. PR5
/// backfills the cap to lock the current shape.
///
/// Caps:
/// - 1 stored collaborator (`let benchmark = BenchmarkSuite()`)
/// - 0 non-private methods (read-only collaborator)
/// - ≤14 lines
/// - imports ⊆ {Observation}
@Suite struct DiagnosticsCoordinatorCeilingsTests {
  private static let sourcePath = "Sources/EnviousWisprAppKit/App/DiagnosticsCoordinator.swift"

  @Test func storedCollaboratorCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "DiagnosticsCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total <= 1,
      """
      DiagnosticsCoordinator stored-collaborator ceiling exceeded: \(total) > 1. \
      Expected only `let benchmark = BenchmarkSuite()`. Raising this cap \
      requires a Bible §30 changelog entry.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "DiagnosticsCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    #expect(
      total == 0,
      """
      DiagnosticsCoordinator non-private method ceiling exceeded: \(total) > 0. \
      The home is a read-only collaborator container. Adding a method requires \
      a Bible §30 changelog entry.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 14,
      """
      DiagnosticsCoordinator line count exceeded: \(count) > 14. Ratchet down \
      if shipping smaller; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = ["Observation"]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      DiagnosticsCoordinator imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry — \
      the home should not couple to additional modules without justification.
      """)
  }
}
