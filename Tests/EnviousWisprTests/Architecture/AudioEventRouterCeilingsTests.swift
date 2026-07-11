import Foundation
import Testing

/// PR8 of #763 — locks `AudioEventRouter`'s entanglement shape.
///
/// Counts top-level `let` stored properties only (per
/// `.claude/rules/architecture-rules.md`; `var` is owned mutable state, not a
/// collaborator), sub-binned into collaborator / closure-injected slots so the
/// test fails with a specific message. Caps lower-is-free, raise via the
/// Bible §30 changelog.
///
/// Bible §30 entry (#1194, 2026-07-02): line ceiling 125 → 137. The router
/// gained one wiring block (`onAudioStartRetryResolved` →
/// `TelemetryService.audioStartRetryResolved`), consistent with its existing
/// role as the audio-callback → telemetry wiring home (state-ownership row 9).
/// No new collaborator slot, no new closure-injected dependency, no new
/// import — only the line count moved.
///
/// Bible §30 entry (#1224, 2026-07-11): collaborator ceiling 4 → 5, line
/// ceiling 137 → 148. The router gained `recordingOverlay` as a fifth
/// collaborator so it can show the honest "auto-stop unavailable" notice
/// when the bundled VAD model is broken — the same in-panel mechanism
/// `RecordingStarter`/`RecordingFinalizer`/`DictationLifecycleCoordinator`
/// already receive `recordingOverlay` for. Bound alongside the existing
/// `onVADAutoStop` install; no re-check of the auto-stop setting here (the
/// XPC service already decided eligibility before firing the callback).
@Suite struct AudioEventRouterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/AudioEventRouter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(named: "AudioEventRouter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 5,
      """
      AudioEventRouter collaborator-slot ceiling exceeded: \(count) > 5. \
      Allowed: audioCapture, pipeline, whisperKitKernelDriver, captureTelemetry, \
      recordingOverlay.
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
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 148,
      """
      AudioEventRouter line count exceeded: \(count) > 148. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
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
