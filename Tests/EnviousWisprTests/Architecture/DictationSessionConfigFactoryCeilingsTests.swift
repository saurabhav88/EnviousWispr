import Foundation
import Testing

/// Architecture ceiling for `DictationSessionConfigFactory` (PR5 of epic #763).
///
/// Locks the home as a stateless factory:
/// - 0 stored properties (enum namespace — cannot have stored properties)
/// - exactly 1 non-private method (the outward `make(...)` API)
/// - ≤85 lines (counted with `source.split(separator: "\n", omittingEmptySubsequences: false).count`)
/// - imports ⊆ {EnviousWisprASR, EnviousWisprCore, EnviousWisprPipeline, EnviousWisprServices}
///
/// Lowering any cap is free; raising requires a Bible §30 changelog entry.
@Suite struct DictationSessionConfigFactoryCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationSessionConfigFactory.swift"

  @Test func storedPropertyCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "DictationSessionConfigFactory", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countTopLevelLetCollaborators(in: $1) }
    #expect(
      total == 0,
      """
      DictationSessionConfigFactory must be stateless: \(total) > 0 stored \
      collaborators. Per epic #763 PR5 plan and decision-tree rule #17, \
      this home is an enum namespace.
      """)
  }

  @Test func nonPrivateMethodCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let bodies = try CeilingsTestSupport.typeBodies(
      named: "DictationSessionConfigFactory", in: source)
    let total = bodies.reduce(0) { $0 + CeilingsTestSupport.countNonPrivateMethods(in: $1) }
    // Use exact-match. `total <= 1` would pass vacuously (0 ≤ 1) if the parser
    // ever stopped detecting `static func make(...)` — guard against drift in
    // the shared parser by asserting the home actually exposes the one API.
    #expect(
      total == 1,
      """
      DictationSessionConfigFactory non-private method count mismatch: \
      expected exactly 1 (the outward `make(...)` API), found \(total). \
      Add a new outward method only via a Bible §30 entry; if this dropped \
      to 0, the shared parser at CeilingsTestSupport may have stopped \
      matching `static func` declarations.
      """)
  }

  @Test func lineCountCeiling() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let count = CeilingsTestSupport.lineCount(in: source)
    #expect(
      count <= 85,
      """
      DictationSessionConfigFactory line count exceeded: \(count) > 85. \
      Ratchet down if implementation came in lower; raise only via Bible §30.
      """)
  }

  @Test func allowedImports() throws {
    let source = try CeilingsTestSupport.source(at: Self.sourcePath)
    let actual = CeilingsTestSupport.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprASR", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices",
      // #1063 PR1 (Bible §30): the factory now threads an opaque `Data?` crash-
      // recovery payload into `DictationSessionConfig`, so it needs `Data`
      // (Foundation, a system value type — not a feature-module coupling).
      "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      DictationSessionConfigFactory imports outside the allowed set: \
      \(extras.sorted()). Allowed: \(allowed.sorted()). New imports require \
      a Bible §30 entry — the factory should not couple to additional modules \
      without justification.
      """)
  }
}
