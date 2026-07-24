import Foundation
import Testing

/// Architecture ceiling for `BulkImportEnrichmentCoordinator` (#1701 Chunk 2).
///
/// First measurement, not a ratchet: caps are set to the shape that shipped,
/// not padded ahead of need. Raising any of these requires a Bible §30
/// changelog entry, same discipline as every other per-home ceiling.
///
/// Caps:
/// - 3 stored collaborators (`customWords`, `aliasSuggester`, `presentStatus`)
/// - 3 non-private methods (`requestDrain`, `cancel`, `awaitDrainForTesting`)
/// - ≤225 lines
/// - imports ⊆ {EnviousWisprCore, EnviousWisprPostProcessing, Foundation}
@Suite struct BulkImportEnrichmentCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/BulkImportEnrichmentCoordinator.swift"

  @Test func storedCollaboratorCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "BulkImportEnrichmentCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total <= 3,
      """
      BulkImportEnrichmentCoordinator stored-collaborator ceiling exceeded: \(total) > 3. \
      Expected only `customWords`, `aliasSuggester`, `presentStatus`. Raising this cap \
      requires a Bible §30 changelog entry.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "BulkImportEnrichmentCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    #expect(
      total <= 3,
      """
      BulkImportEnrichmentCoordinator non-private method ceiling exceeded: \(total) > 3. \
      Expected only `requestDrain`, `cancel`, `awaitDrainForTesting`. New domain methods \
      require a Bible §30 changelog entry.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 225,
      """
      BulkImportEnrichmentCoordinator line count exceeded: \(count) > 225. Ratchet down \
      if shipping smaller; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = ["EnviousWisprCore", "EnviousWisprPostProcessing", "Foundation"]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      BulkImportEnrichmentCoordinator imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()). New imports require a Bible §30 entry — this coordinator \
      should not couple to additional modules without justification (it never reaches \
      through to CustomWordsManager directly; see the file's own header comment).
      """)
  }
}
