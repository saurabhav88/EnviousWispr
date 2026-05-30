import Foundation
import Testing

/// Architecture ceiling for `TranscriptWorkflowCoordinator` (PR6 of epic #763).
///
/// Locks the home as the canonical transcript-workflow coordinator:
/// - 2 stored properties (`transcriptCoordinator` + `polishService` refs)
/// - exactly 1 non-private method (`polishTranscript(_:)`)
/// - ≤90 lines
/// - imports ⊆ {EnviousWisprCore, EnviousWisprPipeline, Foundation, Observation}
///
/// `TranscriptCoordinator` is App-local (same target as TWC); no Services
/// import needed. `EnhancementError` is re-exported from `EnviousWisprCore`.
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
///
/// Anti-service-locator guardrail (Codex grounded review 2026-05-18): TWC
/// must not accrete new domain APIs or non-transcript surfaces. The method
/// ceiling of exactly 1 enforces that structurally.
@Suite struct TranscriptWorkflowCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/TranscriptWorkflowCoordinator.swift"

  @Test func storedPropertyCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "TranscriptWorkflowCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 2,
      """
      TranscriptWorkflowCoordinator stored-property count mismatch: \
      expected exactly 2 (transcriptCoordinator + polishService), found \(total). \
      Adding a stored property requires a Bible §30 entry; if this dropped \
      to 0 or 1, the parser may have stopped matching `let` collaborator \
      declarations.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "TranscriptWorkflowCoordinator", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    // Exact-match. Computed properties (lastEnhancementError, polishingTranscriptID)
    // are NOT counted by the parser. Only `polishTranscript(_:)` is a `func`
    // declaration, so the method count must be 1. The exact-match also guards
    // against the anti-service-locator rule: a new non-private method on TWC
    // is the structural signal of scope creep.
    #expect(
      total == 1,
      """
      TranscriptWorkflowCoordinator non-private method count mismatch: \
      expected exactly 1 (`polishTranscript(_:)`), found \(total). \
      Adding a new outward method requires a Bible §30 entry — TWC must not \
      become a generic transcript service locator. If this dropped to 0, the \
      shared parser at CeilingsTestSupport may have stopped matching `func` \
      declarations.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 90,
      """
      TranscriptWorkflowCoordinator line count exceeded: \(count) > 90. \
      Ratchet down if implementation came in lower; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprCore", "EnviousWisprPipeline",
      "Foundation", "Observation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      TranscriptWorkflowCoordinator imports outside the allowed set: \
      \(extras.sorted()). Allowed: \(allowed.sorted()). TranscriptCoordinator \
      is App-local (same target, no import needed); EnhancementError lives in \
      EnviousWisprCore. New imports require a Bible §30 entry.
      """)
  }
}
