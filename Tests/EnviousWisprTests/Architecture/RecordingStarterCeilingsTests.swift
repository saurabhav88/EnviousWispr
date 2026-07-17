import Foundation
import Testing

/// PR10 of #763 — locks `RecordingStarter`'s initial shape so the start-path
/// home does not silently accrete domain state. Owns `start()` (hotkey PTT
/// path: prewarm + dispatch + post-condition wedge guard) and
/// `toggle(source:)` (lighter UI/menu path: no prewarm).
///
/// Bible-changelog (ratchet history):
/// - PR10 (#776): baseline = 7 collaborators (audioCapture, asrManager,
///   pipeline, whisperKitKernelDriver, settings, permissions, recordingOverlay),
///   2 non-private methods (start, toggle — `isProcessing` is a `var` and
///   is NOT counted), ≤ 250 lines.
@Suite struct RecordingStarterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/RecordingStarter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    #expect(
      count <= 7,
      """
      RecordingStarter collaborator ceiling exceeded: \(count) > 7. \
      Allowed (PR10 baseline): audioCapture, asrManager, pipeline, \
      whisperKitKernelDriver, settings, permissions, recordingOverlay. \
      Raising the ceiling requires a Bible §30 entry.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 2,
      """
      RecordingStarter non-private method ceiling exceeded: \(count) > 2 \
      non-private `func` declarations. PR10 baseline: start, toggle. \
      `isProcessing` is a `var` (computed) and is not counted.
      """)
  }

  @Test func lineCount() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let count = source.split(separator: "\n", omittingEmptySubsequences: false).count
    // #879: raised 250 → 280 (cold-boot press-safety guards on both start
    // paths), then 280 → 285 for the `activeDriver` computed var — a computed
    // accessor (not a stored slot or method) that lets the runtime route
    // onboarding's warm-up through the active engine's shared `ensureEngineWarm`.
    // The domain logic still lives off this type in `ColdPressGuard`; no new
    // collaborator or non-private method.
    // #904 (trust sweep): raised 285 → 292 for the `accessibilityRefresh` test
    // seam — a defaulted `@MainActor () -> Void` closure that makes the AX
    // re-arm-on-revocation step in `start()`/`toggle()` observable (the old test
    // had zero assertions). The closure does NOT count as a collaborator
    // (collaboratorCount still ≤ 7) and is not a non-private method; only the
    // paper-line ceiling moves. Production behavior is identical by default.
    // #959 (idle XPC reclaim): raised 292 → 305 for the warm-respawn branch on
    // both start paths (a not-ready press routes to `ColdPressGuard
    // .resolveNotReadyPress` — warm-respawn falls through to record, genuine cold
    // still pills) + the `warmRespawnInFlight` overlay-latch set just before each
    // kernel dispatch. The decision + telemetry live OFF this type in
    // `ColdPressGuard`; the latch lives on `KernelDictationDriver` — so
    // collaboratorCount stays ≤ 7 and nonPrivateMethodCount stays ≤ 2 (no new
    // slot or method); only the paper-line ceiling moves.
    // #1063 PR1 (crash recovery): raised 305 → 350 for the `makeRecoveryDirective`
    // bare-closure slot (arms the spool; does NOT count as a collaborator — the
    // `async` closure is excluded, collaboratorCount still ≤ 7), the private
    // `makeSessionConfig(triggerSource:armRecovery:)` helper consolidating both
    // start paths, and the Codex code-diff guards (arm-only-on-start + a PTT
    // post-arm release re-check so a quick release can't leave a recording
    // running). The recovery owner is `RecoveryCoordinator`, OFF this type; only
    // the paper-line ceiling moves (deterministic rule: actual 338 + 10 → 350).
    // #1063 PR1 (Codex code-diff r3): raised 350 → 385 for the second bare
    // closure `cleanupRecoveryArm` (also excluded — a non-`async` `() -> Void`
    // closure is not a collaborator, collaboratorCount still ≤ 7) plus the toggle
    // post-arm guards (stop/cancel-during-arm + concurrent-start → `.requestStop`
    // so a dropped `.toggleRecording` can't lose the user's stop) and the PTT
    // abort-cleanup call. Only the paper-line ceiling moves (deterministic rule:
    // actual 375 + 10 → round up to 385).
    // #1063 PR2 (crash-recovery replay): raised 385 → 420 for the third bare
    // closure `isRecovering` (also excluded — a non-`async` `() -> Bool` closure
    // is not a collaborator, collaboratorCount still ≤ 7), the recovery-hold gate
    // branch added to BOTH `start()` and `toggle()` (a press while recovering
    // shows the pill + returns, no session minted), and the id-carrying
    // `cleanupRecoveryArm(config.recoverySessionID)` at the three abort sites. The
    // recovery owner stays OFF this type; only the paper-line ceiling moves
    // (deterministic rule: actual 407 + 10 → round up to 420).
    // #1063 PR2 (Codex code-diff r2 P2): raised 420 → 440 for the post-arm recovery
    // re-checks in BOTH `start()` and `toggle()` — the top-of-method `isRecovering`
    // gate can go stale across the prewarm/arm awaits, so a second check before the
    // kernel dispatch bails (no session) if launch recovery began mid-start. Still
    // no new collaborator (count stays ≤ 7); only the paper-line ceiling moves
    // (deterministic rule: actual 430 + 10 → round up to 440).
    // #1171 (Telemetry Bible Phase 2): raised 440 → 480 for the start-of-recording
    // engine safety check in BOTH `start()` and `toggle()` (a press while the active
    // engine isn't the selected one routes to the reactive pill, no session) plus
    // the `ensureSelectedBackend` injected closure. The pill+swap body itself lives
    // in `ColdPressGuard.reconcileSelectedBackend` (factored out, like `handle`), so
    // only the call sites + closure land here. No new collaborator (count stays ≤ 7);
    // deterministic rule: actual 464 + 10 → round up to 480.
    // #1171 EngineCoordinator refactor (2026-06-23): raised 480 → 515 for the
    // engine-changed re-check added to BOTH `start()` and `toggle()` after the
    // preWarm/recovery-arm awaits — the coordinator can switch the active backend
    // out from under the captured `active` driver across those awaits (the kernel
    // is idle post-preWarm), so we re-check `activeBackendType` before minting and
    // bail on a raced engine (mirrors the existing recovery re-check). Two bare
    // `let entryBackend` captures + two guard blocks; no new collaborator (count
    // stays ≤ 7). Deterministic rule: actual 503 + 10 → round up to nearest 5 = 515.
    // #1393: raised 515 → 535 for the `recordingElapsedProvider` argument (and
    // its explanatory comment) on the recording overlay's FIRST `.recording`
    // push — this call site runs before `DictationLifecycleCoordinator` ever
    // sees a state change, so it must carry the real elapsed-time provider
    // itself or the panel's identical-intent dedup guard would leave the
    // floating pill stuck on the default `nil` provider for the whole
    // recording (the #1393 timer-reset bug, second instance, found by Codex
    // Grounded Review round 1). No new collaborator or method; only the
    // paper-line ceiling moves. Deterministic rule: actual 522 + 10 → round
    // up to nearest 5 = 535.
    // #1580: raised 535 → 550 for a `backend`/`isWhisperKit`-shape local in
    // both `start()` and `toggle(source:)` (`let backend = asrManager.
    // activeBackendType`), named so `backend.rawValue` reads the wire spelling
    // once instead of nine call sites each re-typing a "whisperkit" : "parakeet"
    // ternary that had drifted into two different casings. `start()`'s new
    // local nets zero (it lets an already-wrapped call collapse back to one
    // line); `toggle(source:)`'s has no such call to collapse against, so it
    // adds one line net. No new collaborator or method; only the paper-line
    // ceiling moves. Deterministic rule: actual 536 + 10 → round up to
    // nearest 5 = 550.
    // #1386 PR-2c: 550 → 565 for the founder's removal gate — the honest
    // not-installed pill on BOTH press paths before any readiness logic (a
    // removal's first instants can still read ready). Actual 560 + ~2 → 565.
    #expect(
      count <= 565,
      """
      RecordingStarter line count exceeded: \(count) > 565. \
      Raise via Bible §30 only.
      """)
  }

  @Test func noPolishServiceReference() throws {
    // Hard constraint from epic comment 4483335497 and migration plan §PR10.
    // PR11 owns the polish-service rehoming; PR10 must not introduce a
    // dependency on it. Filters comment lines so doc text that NAMES the
    // forbidden symbol (to explain the constraint) does not trigger.
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//")
      }
      .joined(separator: "\n")
      .lowercased()
    #expect(
      !code.contains("polishservice") && !code.contains("transcriptpolishservice"),
      """
      RecordingStarter must not reference polishService / TranscriptPolishService. \
      PR11 owns polish-service rehoming (epic comment 4483335497).
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      RecordingStarter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
