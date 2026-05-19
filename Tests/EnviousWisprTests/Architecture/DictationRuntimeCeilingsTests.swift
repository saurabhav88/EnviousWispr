import Foundation
import Testing

/// PR8 of #763 — locks `DictationRuntime`'s initial shape so the new
/// runtime-internals home does not silently accrete domain state before
/// PR10 expands it with HotkeyController / RecordingStarter / RecordingFinalizer.
@Suite struct DictationRuntimeCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/DictationRuntime.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationRuntime", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 3,
      """
      DictationRuntime collaborator ceiling exceeded: \(count) > 3. \
      Allowed: audioEventRouter, asrEventRouter, wedgeRecoveryRouter.
      PR10 raises this when hotkey/start/finalize land.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationRuntime", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count == 0,
      """
      DictationRuntime must not store closure-injected dependencies (found \(count)). \
      Resolver closures pass through init to the routers; they are not held \
      on DictationRuntime itself.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationRuntime", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // Parser counts `func`, not `init`. Codex code-diff r1 [P3].
    #expect(
      count == 0,
      """
      DictationRuntime non-private method ceiling exceeded: \(count) > 0 \
      non-private `func` declarations. Only `init(...)` permitted at the PR8 \
      stage; PR10 may add more.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 80,
      """
      DictationRuntime line count exceeded: \(count) > 80. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprAudio", "EnviousWisprASR",
      "EnviousWisprPipeline", "EnviousWisprServices", "EnviousWisprCore",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      DictationRuntime imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
