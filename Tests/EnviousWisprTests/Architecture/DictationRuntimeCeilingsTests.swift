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
///   the recording-control surface lifted out of the former root state). Non-private
///   method cap 0 → 6 — DictationRuntime is now the App-level façade for
///   recording commands (`startHotkeyServiceIfEnabled`, `suspendHotkeys`,
///   `resumeHotkeys`, `toggleRecording(source:)`, `cancelRecording()`,
///   `resetActivePipeline()`). Line cap 100 → 200 to absorb the 7-collab
///   field block + 6 façade methods + DR.init body that builds the
///   recording subsystem internally (HeartControlRecovery + Finalizer +
///   Starter + HotkeyController) and calls `hotkeyController.install()`
///   as the last init step.
/// - #1171 (Telemetry Bible Phase 2): line cap 200 → 215. EngineCoordinator
///   owns engine selection/switching, so DR.init threads four new pass-through
///   parameters to the Starter (`ensureSelectedReadyForPress`,
///   `isEngineSwitching`, `beginMinting`, `endMinting`) plus their doc
///   comments. No new stored property, collaborator, or method — pure init
///   wiring; collaborator/closure-injected/method caps unchanged.
/// - #1388: non-private method cap 7 → 8, line cap 215 → 216 for
///   `cancelActiveEngineWarmupForOnboarding()` — the onboarding install
///   Cancel's seam, the exact cancel twin of #879's
///   `ensureActiveEngineWarmForOnboarding` (same thin forward to
///   `starter.activeDriver`, no new state, no new collaborator).
/// - #1224 (2026-07-11): line cap 216 → 217 for one new `recordingOverlay:`
///   argument threaded into the existing `AudioEventRouter(...)` construction
///   call — the router needs it to show the bundled-VAD-model-unavailable
///   notice. No new DictationRuntime collaborator, method, or import; the
///   value was already a DictationRuntime.init parameter, just not yet
///   passed to this one collaborator.
@Suite struct DictationRuntimeCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/DictationRuntime.swift"

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
    // #879: raised 6 → 7 for `ensureActiveEngineWarmForOnboarding()` — the
    // onboarding screen routes its first-run warm-up through the runtime so it
    // uses the same shared `ensureEngineWarm` as every other warm-up site. It is
    // a thin forward to `starter.activeDriver.ensureEngineWarm(.onboarding)`, no
    // new state.
    // #1388: raised 7 → 8 for `cancelActiveEngineWarmupForOnboarding()` — the
    // install Cancel's seam, #879's cancel twin (thin forward to
    // `starter.activeDriver.cancelSessionlessWarmup()`, no new state).
    #expect(
      count <= 8,
      """
      DictationRuntime non-private method ceiling exceeded: \(count) > 8 \
      non-private `func` declarations. PR10 baseline: \
      startHotkeyServiceIfEnabled, suspendHotkeys, resumeHotkeys, \
      toggleRecording, cancelRecording, resetActivePipeline; #879 added \
      ensureActiveEngineWarmForOnboarding; #1388 added \
      cancelActiveEngineWarmupForOnboarding. Raising the ceiling requires a \
      Bible §30 entry.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 217,
      """
      DictationRuntime line count exceeded: \(count) > 217. \
      Raise via Bible §30 only. PR10 ratcheted 100 → 200 to absorb the \
      7-collab field block + 6 façade methods + DR.init body building the \
      recording subsystem (HeartControlRecovery + Finalizer + Starter + \
      HotkeyController) and calling `hotkeyController.install()` internally. \
      #1171 ratcheted 200 → 215 for the four EngineCoordinator pass-through \
      init parameters (ensureSelectedReadyForPress, isEngineSwitching, \
      beginMinting, endMinting) + their doc comments — no new state. \
      #1388 ratcheted 215 → 216 for cancelActiveEngineWarmupForOnboarding \
      (#879's cancel twin — thin forward, no new state). #1224 ratcheted \
      216 → 217 for one new `recordingOverlay:` argument threaded into the \
      existing AudioEventRouter(...) construction call.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
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
