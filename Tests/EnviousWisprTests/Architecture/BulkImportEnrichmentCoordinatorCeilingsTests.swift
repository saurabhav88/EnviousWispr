import Foundation
import Testing

/// Architecture ceiling for `BulkImportEnrichmentCoordinator` (#1701 Chunk 2).
///
/// Ratchet history:
/// - Stored collaborators 3 -> 4 in #1701 (2026-07-23): injected
///   `retrySleep`, the cancellable timing seam for bounded `.libraryBusy`
///   recovery. Production uses the shipped 1/2/4-second retry schedule;
///   tests replace the wait with a signal and never depend on wall-clock time.
/// - Lines 225 -> 260 in #1701 (2026-07-23): Phase 3 full-diff review required
///   typed `.libraryBusy` handling, a bounded delayed-retry state machine,
///   and classification-aware routing for `.general` imported words. This is
///   coordinator sequencing, not a new domain responsibility.
///
/// Caps:
/// - 4 stored collaborators
///   (`customWords`, `aliasSuggester`, `presentStatus`, `retrySleep`)
/// - 3 non-private methods (`requestDrain`, `cancel`, `awaitDrainForTesting`)
/// - <=260 lines
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
      total <= 4,
      """
      BulkImportEnrichmentCoordinator stored-collaborator ceiling exceeded: \(total) > 4. \
      Expected only `customWords`, `aliasSuggester`, `presentStatus`, `retrySleep`. Raising \
      this cap requires a Bible §30 changelog entry.
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
      count <= 260,
      """
      BulkImportEnrichmentCoordinator line count exceeded: \(count) > 260. Ratchet down \
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
