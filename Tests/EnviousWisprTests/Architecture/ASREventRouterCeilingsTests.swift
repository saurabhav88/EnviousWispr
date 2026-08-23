import Foundation
import Testing

/// PR8 of #763 — locks `ASREventRouter`'s entanglement shape.
@Suite struct ASREventRouterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/ASREventRouter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(named: "ASREventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 3,
      """
      ASREventRouter collaborator-slot ceiling exceeded: \(count) > 3. \
      Allowed: asrManager, pipeline, whisperKitKernelDriver.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(named: "ASREventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count == 0,
      """
      ASREventRouter must not take closure-injected dependencies (found \(count)). \
      Reads pipeline state directly; no resolver helper required.
      """)
  }

  /// The two buckets are individually useful, but an alias can change buckets
  /// without changing the dependency. Freeze their measured total as well.
  @Test func totalStoredDependencyCount() throws {
    let body = try RouterCeilingParser.classBody(named: "ASREventRouter", at: Self.sourcePath)
    let collaborators = RouterCeilingParser.collaboratorCount(in: body)
    let closures = RouterCeilingParser.closureInjectedCount(in: body)
    let total = RouterCeilingParser.storedDependencyCount(in: body)
    #expect(
      total <= 3,
      "ASREventRouter total stored-dependency ceiling exceeded: \(total) > 3 (\(collaborators) collaborators + \(closures) closures).")
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(named: "ASREventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // Parser counts `func`, not `init`. Codex code-diff r1 [P3].
    #expect(
      count == 0,
      """
      ASREventRouter non-private method ceiling exceeded: \(count) > 0 \
      non-private `func` declarations. Only `init(...)` permitted.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprASR", "EnviousWisprCore", "EnviousWisprPipeline", "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      ASREventRouter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
