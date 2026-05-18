import Foundation
import Testing

/// Architecture ceiling for `NavigationCoordinator` (PR2 of epic #763, backfilled in PR5).
///
/// PR2 (#765/#767) shipped before per-home ceiling discipline existed. PR5
/// backfills the cap to lock the current shape.
///
/// Caps:
/// - 0 stored collaborators (the one stored property is `var pendingSection: SettingsSection?` — primitive optional)
/// - 2 non-private methods (`request`, `consume`)
/// - ≤20 lines
/// - imports ⊆ {Observation}
@Suite struct NavigationCoordinatorCeilingsTests {
  private static let sourcePath = "Sources/EnviousWispr/App/NavigationCoordinator.swift"

  @Test func storedCollaboratorCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "NavigationCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 0,
      """
      NavigationCoordinator stored-collaborator ceiling exceeded: \(total) > 0. \
      The home owns only the primitive `pendingSection: SettingsSection?` signal. \
      Raising this cap requires a Bible §30 changelog entry.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "NavigationCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    #expect(
      total <= 2,
      """
      NavigationCoordinator non-private method ceiling exceeded: \(total) > 2. \
      Expected `request` and `consume` only. Raising this cap requires a \
      Bible §30 changelog entry.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 20,
      """
      NavigationCoordinator line count exceeded: \(count) > 20. Ratchet down \
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
      NavigationCoordinator imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry — \
      the home should not couple to additional modules without justification.
      """)
  }
}
