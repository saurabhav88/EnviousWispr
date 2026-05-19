import Foundation
import Testing

/// PR8 of #763 — locks `ASREventRouter`'s entanglement shape.
@Suite struct ASREventRouterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/ASREventRouter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(named: "ASREventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 3,
      """
      ASREventRouter collaborator-slot ceiling exceeded: \(count) > 3. \
      Allowed: asrManager, pipeline, whisperKitPipeline.
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

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 65,
      """
      ASREventRouter line count exceeded: \(count) > 65. Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
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
