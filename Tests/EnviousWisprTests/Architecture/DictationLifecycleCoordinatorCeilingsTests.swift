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
///   (b) the lifecycle home needs BOTH a getter and a setter for AppState's
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
///      `var languageSuggestionPresenter` on AppState (see
///      `AppStateCeilingsTests.swift:19-25` doc).
@Suite struct DictationLifecycleCoordinatorCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/DictationRuntime/DictationLifecycleCoordinator.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "DictationLifecycleCoordinator", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 11,
      """
      DictationLifecycleCoordinator collaborator ceiling exceeded: \(count) > 11. \
      Allowed (PR9 baseline): pipeline, whisperKitPipeline, recordingOverlay, \
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
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      count <= 350,
      """
      DictationLifecycleCoordinator line count exceeded: \(count) > 350. \
      Raise via Bible §30 only.
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
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
