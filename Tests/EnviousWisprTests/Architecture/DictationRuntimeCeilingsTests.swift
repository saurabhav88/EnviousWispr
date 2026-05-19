import Foundation
import Testing

/// PR8 of #763 — locks `DictationRuntime`'s initial shape so the new
/// runtime-internals home does not silently accrete domain state.
///
/// Bible-changelog (ratchet history):
/// - PR8 (#774): baseline = 3 collaborators (audio/asr/wedge routers), 0
///   non-private methods, ≤ 80 lines.
/// - PR9 (#775): collaborator cap 3 → 4 (added `dictationLifecycleCoordinator`
///   as a private property). Line cap 80 → 100 (new property + init parameter
///   + Bible-changelog header comment).
/// - PR10 (#776): collaborator cap 4 → 7 (added `hotkeyController`,
///   `starter`, `finalizer` — three new private collaborators that own
///   the recording-control surface lifted out of AppState). Non-private
///   method cap 0 → 6 — DictationRuntime is now the App-level façade for
///   recording commands (`startHotkeyServiceIfEnabled`, `suspendHotkeys`,
///   `resumeHotkeys`, `toggleRecording(source:)`, `cancelRecording()`,
///   `resetActivePipeline()`). Line cap 100 → 200 to absorb the 7-collab
///   field block + 6 façade methods + DR.init body that builds the
///   recording subsystem internally (HeartControlRecovery + Finalizer +
///   Starter + HotkeyController) and calls `hotkeyController.install()`
///   as the last init step.
@Suite struct DictationRuntimeCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/DictationRuntime.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationRuntime", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 7,
      """
      DictationRuntime collaborator ceiling exceeded: \(count) > 7. \
      Allowed (PR10 baseline): dictationLifecycleCoordinator, audioEventRouter, \
      asrEventRouter, wedgeRecoveryRouter, hotkeyController, starter, finalizer. \
      Raising the ceiling requires a Bible §30 entry.
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
      Resolver closures pass through init to the routers; HeartControlRecovery is \
      built in init body and passed by value to Starter+Finalizer.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationRuntime", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // Parser counts `func`, not `init` or computed `var` (e.g. hotkeyDescription).
    #expect(
      count <= 6,
      """
      DictationRuntime non-private method ceiling exceeded: \(count) > 6 \
      non-private `func` declarations. PR10 baseline: \
      startHotkeyServiceIfEnabled, suspendHotkeys, resumeHotkeys, \
      toggleRecording, cancelRecording, resetActivePipeline. Raising the \
      ceiling requires a Bible §30 entry.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 200,
      """
      DictationRuntime line count exceeded: \(count) > 200. \
      Raise via Bible §30 only. PR10 ratcheted 100 → 200 to absorb the \
      7-collab field block + 6 façade methods + DR.init body building the \
      recording subsystem (HeartControlRecovery + Finalizer + Starter + \
      HotkeyController) and calling `hotkeyController.install()` internally.
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
