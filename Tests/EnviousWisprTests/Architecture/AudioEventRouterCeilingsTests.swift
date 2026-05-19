import Foundation
import Testing

/// PR8 of #763 — locks `AudioEventRouter`'s entanglement shape.
///
/// Counts honestly: BOTH `let` and `var` instance stored properties count,
/// sub-binned into collaborator / closure-injected / observer-token slots so
/// the test fails with a specific message. Caps lower-is-free, raise via the
/// Bible §30 changelog.
@Suite struct AudioEventRouterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/AudioEventRouter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(named: "AudioEventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 4,
      """
      AudioEventRouter collaborator-slot ceiling exceeded: \(count) > 4. \
      Allowed: audioCapture, pipeline, whisperKitPipeline, captureTelemetry.
      """)
  }

  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(named: "AudioEventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count <= 1,
      """
      AudioEventRouter closure-injected-dependency ceiling exceeded: \
      \(count) > 1. Allowed: resolveActiveCaptureBackend.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(named: "AudioEventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // Parser counts `func` declarations, not `init`. The router exposes
    // only `init(...)`; any additional non-private `func` (e.g. `start()`)
    // breaks the no-public-control-surface invariant. Codex code-diff r1
    // [P3]: a `<= 1` ceiling would allow the first violation to pass.
    #expect(
      count == 0,
      """
      AudioEventRouter non-private method ceiling exceeded: \(count) > 0 \
      non-private `func` declarations. Only `init(...)` (not counted as a \
      `func`) is permitted; no public `start()` / `stop()`.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 125,
      """
      AudioEventRouter line count exceeded: \(count) > 125. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "AVFAudio", "EnviousWisprAudio", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices", "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      AudioEventRouter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
