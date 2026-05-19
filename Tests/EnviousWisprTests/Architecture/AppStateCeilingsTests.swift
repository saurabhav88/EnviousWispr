import Foundation
import Testing

/// Architecture regression tests for AppState.
///
/// Locks post-Phase-F (#501) state so AppState does not silently re-accrete
/// toward a god-object. Tests parse the source file directly rather than
/// constructing an AppState instance — AppState's init pulls in real audio
/// capture, ASR, pipelines, and Tasks that should not run inside a unit test.
///
/// Ceilings: concrete-collaborator count ≤ 17, total line count ≤ 692.
/// Raising a ceiling requires a Bible changelog entry, not a silent bump.
@Suite struct AppStateCeilingsTests {

  /// Concrete-collaborator count ceiling. Locked at post-PR9 (#775) baseline = 17.
  /// Counts top-level `let` declarations on AppState whose type is non-primitive.
  /// Existentials (`any X`) count as collaborators.
  ///
  /// Ratchet history:
  /// - 19 → 18 in PR3 of epic #763 (2026-05-18, #769) after extracting
  ///   BenchmarkSuite into DiagnosticsCoordinator. PR4 of epic #763 (#770)
  ///   ships `var languageSuggestionPresenter` which is intentionally a
  ///   `var` (setter-injected post-init) and is therefore NOT counted by
  ///   this parser — the ceiling stays at 18.
  /// - 18 → 17 in PR9 of epic #763 (2026-05-19, #775) after extracting
  ///   `let transcriptCoordinator` off AppState. The new lifecycle home
  ///   (`DictationLifecycleCoordinator`) is the caller of `append`; views
  ///   read through `TranscriptWorkflowCoordinator`. The composition root
  ///   (`EnviousWisprApp.init`) constructs `TranscriptCoordinator` once and
  ///   threads the same instance to both. AppState's init now takes
  ///   `TranscriptStore` so the pipelines + polish service still receive
  ///   the shared store reference.
  @Test func appStateConcreteCollaboratorCeilingHolds() throws {
    let body = try classBodyOfAppState()
    let count = countTopLevelLetCollaborators(in: body)
    #expect(
      count <= 17,
      """
      AppState concrete-collaborator ceiling exceeded: \(count) > 17. \
      Raising the ceiling requires a Bible changelog entry, not a silent bump.
      """)
  }

  /// File line-count ceiling. Locked at post-PR8 (#774) baseline = 904.
  /// Soft backstop against scope creep.
  ///
  /// Ratcheted history:
  /// - 1050 → 1049 in PR3 of epic #763 (2026-05-18, #769) after removing the
  ///   `let benchmark = BenchmarkSuite()` line.
  /// - 1049 → 1115 in PR4 of epic #763 (2026-05-18, #770) after adding the
  ///   transient `languageSuggestionPresenter` var + setter, the chip-handler
  ///   ChipWiringDiagnostics dispatch, the pipeline state-change chip dispatches
  ///   (parakeet `.complete`/`.error`, whisperKit `.complete`/`.ready`/`.error`,
  ///   plus polish-error race guards from Codex code-diff r2+r3), and the
  ///   cancelRecording chip clear. All sunset in PR9 / PR10 / PR11.
  /// - 1115 → 1073 in PR5 of epic #763 (2026-05-18, #771) after extracting
  ///   `makeDictationSessionConfig(triggerSource:)` into `DictationSessionConfigFactory`.
  ///   Method body + doc removed 55 lines; two call sites grew 13 lines for the
  ///   multi-line factory invocation. Net delta: -42. 1071 actual + 2-line margin.
  /// - 1073 → 1046 in PR6 of epic #763 (2026-05-18, #772) after extracting
  ///   `lastEnhancementError` computed + `polishTranscript(_:)` method into
  ///   `TranscriptWorkflowCoordinator`. Removed 27 lines (5 + 20 + 2 blank).
  ///   1044 actual + 2-line margin. Collaborator ceiling stays at 18 — Shape 4
  ///   keeps `let polishService` and `let transcriptCoordinator` on AppState
  ///   through PR6 (cascade out in PR11 / PR9 respectively).
  /// - 1046 → 1038 in PR7 of epic #763 (2026-05-18, #773) after extracting the
  ///   eight live-recording / display getters (`pipelineState`, `lastPolishError`,
  ///   `activeTranscript`, `audioLevel`, `activeModelName`, `activeLLMDisplayName`,
  ///   `modelStatusText`) into `LiveRecordingState` + `LastRecordingResult` +
  ///   `BackendMetadata`. Net: -8 (getters + comments removed; three setter-
  ///   injected `var` outlets + their attach methods + polishError push/reset
  ///   lines added, including a Codex-flagged pre-dispatch reset in
  ///   `toggleRecording(source:)`). 1036 actual + 2-line margin. Collaborator
  ///   ceiling stays at 18 — the three new outlets are `var`, not `let`, and
  ///   the parser matches only `let`. The three temporary outlets sunset
  ///   in PR9 / PR11.
  /// - 1038 → 904 in PR8 of epic #763 (2026-05-19, #774) after extracting the
  ///   seven heart-path event-routing closures (`audioCapture.on*` ×6 +
  ///   `asrManager.onServiceInterrupted`) plus the
  ///   `AVAudioEngineConfigurationChange` observer block into the three
  ///   routers under `DictationRuntime`. Net: -134. The resolver helpers
  ///   stayed on AppState through PR8 — promoted `private` → `internal` so
  ///   the router-injected closures could read them — and PR9 owns the
  ///   cleanup.
  /// - 904 → 692 in PR9 of epic #763 (2026-05-19, #775) after extracting:
  ///   the two pipeline `onStateChange` closure bodies (~120 lines), the
  ///   lazy state-handler factory (~37 lines), the post-completion warning
  ///   Task + scheduler (~13 lines), the seven PR8 deferred resolver
  ///   symbols (~47 lines), the `let transcriptCoordinator` + local
  ///   `transcriptStore` construction (~5 lines), the `onPipelineStateChange`
  ///   var (~2 lines). New code added: the `attachDictationLifecycleCoordinator`
  ///   weak ref setter (~10 lines), the `init(transcriptStore:)` parameter
  ///   change (~2 lines), explanatory comments at the deletion sites
  ///   (~25 lines). Net: ~-212. 690 actual + 2-line margin. Same-PR
  ///   grep-test `AppStateNoLongerOwnsBackendResolverTests` enforces no
  ///   PR8-deferred symbol survives.
  @Test func appStateLineCountCeilingHolds() throws {
    let url = appStateURL()
    let source = try String(contentsOf: url, encoding: .utf8)
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    #expect(
      lineCount <= 692,
      """
      AppState line count exceeded: \(lineCount) > 692. \
      Raising the ceiling requires a Bible changelog entry, not a silent bump.
      """)
  }
}

private func appStateURL() -> URL {
  // SPM tests run with cwd = package root.
  URL(fileURLWithPath: "Sources/EnviousWispr/App/AppState.swift")
}

private func classBodyOfAppState() throws -> String {
  let source = try String(contentsOf: appStateURL(), encoding: .utf8)
  guard let openRange = source.range(of: "final class AppState {") else {
    Issue.record("AppState declaration not found at expected path/shape")
    throw POSIXError(.ENOENT)
  }
  let openIdx = source.index(before: openRange.upperBound)  // points at '{'
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("AppState class body has unbalanced braces")
  throw POSIXError(.EILSEQ)
}

private func countTopLevelLetCollaborators(in body: String) -> Int {
  // Top-level = brace-depth 0 within the class body.
  // Match `let <ident>` declarations preceded by any combination of:
  //   - Swift attributes (e.g. `@ObservationIgnored`, `@Published`)
  //   - One access modifier (public/internal/private/fileprivate/package/open)
  // Skip primitives (Bool/Int/String/closures/Tasks).
  var depth = 0
  var collaborators = 0
  for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
    let opens = line.filter { $0 == "{" }.count
    let closes = line.filter { $0 == "}" }.count
    let depthForThisLine = depth - max(0, closes - opens)
    if depthForThisLine == 0 {
      let s = String(line)
      if isCollaboratorLetDeclaration(s) && !isPrimitiveTyped(s) {
        collaborators += 1
      }
    }
    depth += opens - closes
  }
  return collaborators
}

private let collaboratorLetPattern: String = {
  // Attribute can have a parenthesized argument list (`@available(macOS 14, *)`,
  // `@Injected(...)`); the optional `(\([^)]*\))?` matches that. Multiple
  // attributes in series allowed via `*` repetition.
  let attrs = #"(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*"#
  let access = #"(public|internal|private|fileprivate|package|open)?"#
  return "^[[:space:]]*\(attrs)\(access)[[:space:]]*let[[:space:]]+[A-Za-z_]"
}()

private func isCollaboratorLetDeclaration(_ line: String) -> Bool {
  return line.range(of: collaboratorLetPattern, options: .regularExpression) != nil
}

private func isPrimitiveTyped(_ line: String) -> Bool {
  // Architectural collaborators are concrete app/library types and protocol
  // existentials. Plain values are not collaborators.
  let primitives = [
    ": Bool", ": Int", ": String", ": Double", ": Float",
    "Task<", ": ((", "= false", "= true",
  ]
  return primitives.contains { line.contains($0) }
}
