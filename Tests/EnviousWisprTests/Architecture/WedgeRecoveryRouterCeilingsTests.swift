import Foundation
import Testing

/// PR8 of #763 — locks `WedgeRecoveryRouter`'s entanglement shape.
@Suite struct WedgeRecoveryRouterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/WedgeRecoveryRouter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "WedgeRecoveryRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 3,
      """
      WedgeRecoveryRouter collaborator-slot ceiling exceeded: \(count) > 3. \
      Allowed: audioCapture, pipeline, whisperKitKernelDriver.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "WedgeRecoveryRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count <= 2,
      """
      WedgeRecoveryRouter closure-injected-dependency ceiling exceeded: \
      \(count) > 2. Allowed: isCurrentSession, resolveActiveTelemetryTarget.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "WedgeRecoveryRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // Parser counts `func`, not `init`. Codex code-diff r1 [P3].
    #expect(
      count == 0,
      """
      WedgeRecoveryRouter non-private method ceiling exceeded: \(count) > 0 \
      non-private `func` declarations. Only `init(...)` permitted.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 115,
      """
      WedgeRecoveryRouter line count exceeded: \(count) > 115. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprAudio", "EnviousWisprCore", "EnviousWisprPipeline",
      "EnviousWisprServices", "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      WedgeRecoveryRouter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
