import Foundation
import Testing

/// PR9 of #763 — locks `DictationLifecycleCoordinator`'s shape so the new
/// lifecycle home does not silently accrete domain state.
///
/// Bible-changelog (ratchet history):
/// - PR9 (#775): baseline. The cap is 11 `let` collaborators — raised from
///   the parent migration plan §PR9's named "10" after parser-grounded
///   analysis of `CeilingsTestSupport.swift` revealed two facts:
///   (a) the ceiling parser counts only top-level `let` declarations with
///       non-primitive types; `var`-typed resolver state (`lastCapturingBackend`,
///       `prevParakeetActive`, `prevWhisperKitActive`, `postCompletionWarningTask`,
///       lazy state handlers, `onPipelineStateChange`) is therefore free
///       against the cap.
///   (b) the lifecycle home needs BOTH a getter and a setter for the former root state's
///       still-owned `isRecordingLocked` — getter feeds
///       `recordingOverlay.show(...)` so the hands-free lock visual renders
///       correctly during state transitions; setter clears locked on
///       transitions out of `.recording`. Packaging the get/set pair into a
///       single nested `RecordingLockedAccess` struct holds the cap at exactly
///       11. Alternatives rejected: `weak var appState` back-reference
///       (banned forwarding shim per migration Hard Constraint #2 and
///       `~/.claude/rules/no-half-done-handoffs.md`); expanding PR9 scope to
///       absorb `isRecordingLocked` state ownership entirely (collides with
///       PR10's `RecordingFinalizer` plan).
///   PR10 ratchets back down when `RecordingFinalizer` absorbs the
///   lock-state writes (the closure-pair retires).
/// - #1060 (2026-06-17): line ceiling 350 → 365. The coordinator gained the
///   approaching-cap warning presentation (`showApproachingCapWarning`, a PRIVATE
///   method) + its callback wiring + completion-telemetry stop-reason/length —
///   correctly placed here per state-ownership decision table row 8 (overlay /
///   warning / transition behavior after start). The ENTANGLEMENT ceilings are
///   UNCHANGED (collaborators still 11, non-private methods still 5): the feature
///   added no collaborator and no public surface, only lines. Per
///   `measure-entanglement-not-paper` the line ceiling is the loose/paper metric,
///   so a modest paper bump for a correctly-placed responsibility is the honest
///   call over comment-cramming. Comments were trimmed first to minimize it.
///
/// Var-exclusion rationale (per category, locked here so a future PR cannot
/// argue "var anything is free"):
///   1. OWNED MUTABLE STATE (`lastCapturingBackend`, `prevParakeetActive`,
///      `prevWhisperKitActive`, `postCompletionWarningTask`, lazy state
///      handlers): genuine in-flight state owned by the coordinator, mutated
///      by the state-change closures and Task scheduling. Not collaborators —
///      no external owner, no architectural dependency.
///   2. EXTERNAL CALLBACK (`var onPipelineStateChange`): setter-injected
///      post-init by AppDelegate. Same precedent as PR4's
///      `var languageSuggestionPresenter`.
@Suite struct DictationLifecycleCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/DictationLifecycleCoordinator.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationLifecycleCoordinator", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 11,
      """
      DictationLifecycleCoordinator collaborator ceiling exceeded: \(count) > 11. \
      Allowed (PR9 baseline): pipeline, whisperKitKernelDriver, recordingOverlay, \
      hotkeyService, settingsSync, audioCapture, transcriptCoordinator, settings, \
      lastRecordingResult, languageSuggestionPresenter, recordingLockedAccess. \
      PR10 ratchets down when RecordingFinalizer absorbs the lock-state writes.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationLifecycleCoordinator", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 5,
      """
      DictationLifecycleCoordinator non-private method ceiling exceeded: \
      \(count) > 5 non-private `func` declarations. Allowed (PR9 baseline): \
      `install()`, `cancelPendingWarning()`, `activeCaptureBackend()`, \
      `isCurrentSession(_:)`, `activeTelemetryTarget()`.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    // #1063 PR1 (crash recovery): raised 365 → 385 for the setter-injected
    // `onDurableSave` `var` closure (deletes a session's spool + key on durable
    // save) + its invocation in the existing `appendCompletedTranscript` seam.
    // A `var` closure is NOT counted as a collaborator (collaboratorCount still
    // ≤ 11); the Pipeline stays recovery-unaware. Only the paper-line ceiling
    // moves (deterministic rule: actual 374 + 10 → round up to 385).
    // #1063 PR1 (Codex code-diff r3): raised 385 → 400 for the second
    // setter-injected `onRecordingEndedWithoutDurableSave` `var` closure +
    // its invocation on the non-saved `.idle`/`.error` terminals in BOTH
    // per-backend handlers (deletes the armed spool/key when a recording ends
    // without a durable save, instead of leaking until launch). Still a `var`
    // closure (collaboratorCount stays ≤ 11); only the paper-line ceiling moves
    // (deterministic rule: actual 390 + 10 → round up to 400).
    #expect(
      count <= 400,
      """
      DictationLifecycleCoordinator line count exceeded: \(count) > 400. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "EnviousWisprASR",
      "EnviousWisprAudio",
      "EnviousWisprCore",
      "EnviousWisprPipeline",
      "EnviousWisprServices",
      "EnviousWisprStorage",
      "Foundation",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      DictationLifecycleCoordinator imports outside allowed set: \
      \(extras.sorted()). Allowed: \(allowed.sorted()).
      """)
  }
}
