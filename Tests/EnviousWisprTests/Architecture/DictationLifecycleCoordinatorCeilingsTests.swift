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
      // #2455 C3 (#2460): 11 -> 12. `application`, the activation seam. Escape
      // Recovery's pill hands the caret back to the user's app after a cancel,
      // and that call had a live DEFAULT until this chunk made it required.
      count <= 12,
      """
      DictationLifecycleCoordinator collaborator ceiling exceeded: \(count) > 12. \
      Allowed (PR9 baseline): pipeline, whisperKitKernelDriver, recordingOverlay, \
      hotkeyService, settingsSync, audioCapture, transcriptCoordinator, settings, \
      lastRecordingResult, languageSuggestionPresenter, recordingLockedAccess. \
      PR10 ratchets down when RecordingFinalizer absorbs the lock-state writes.
      """)
  }

  /// #2648 — the combined cap this home never had.
  ///
  /// Its collaborator cap counts `let`s that are not closures, so a capability
  /// stored as a bare closure lands in no bin at all. That is a real shape for a
  /// single capability and it is what `releaseEngineClaim` is, but "it does not
  /// count" is not the same as "it costs nothing". The starter's own suite
  /// learned this the same way (`RecordingStarterCeilingsTests`, the sum cap
  /// added after cloud review found both per-bin caps individually bypassable).
  @Test func totalStoredDependencyCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationLifecycleCoordinator", at: Self.sourcePath)
    let total = RouterCeilingParser.storedDependencyCount(in: body)
    #expect(
      total <= 13,
      """
      DictationLifecycleCoordinator stored-dependency ceiling exceeded: \(total) > 13. \
      Twelve collaborators plus #2648's one release capability. Whichever bin a new \
      dependency lands in, it lands here.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationLifecycleCoordinator", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    // #2648: 5 -> 6. `acceptEngineToken(_:)`, which takes ownership of the
    // running session's claim on the shared ASR-and-polish resource.
    //
    // It has to be a method on this home rather than a closure the start path
    // keeps, because both start methods RETURN while the recording is still
    // running (`RecordingStarter.swift:437-497`, `:610-626`): the claim must
    // outlive the call that made it, and this is the type that already owns the
    // session's terminal transition. The release is a bare closure and did NOT
    // move the collaborator count, which stays at 12.
    #expect(
      count <= 6,
      """
      DictationLifecycleCoordinator non-private method ceiling exceeded: \
      \(count) > 6 non-private `func` declarations. Allowed (PR9 baseline): \
      `install()`, `cancelPendingWarning()`, `activeCaptureBackend()`, \
      `isCurrentSession(_:)`, `activeTelemetryTarget()`, plus #2648's \
      `acceptEngineToken(_:)`.
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
