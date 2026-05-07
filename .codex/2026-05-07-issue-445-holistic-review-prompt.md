# Holistic review — issue #445 signal-based wedge trigger (rebase on parked branch)

You are reviewing the EnviousWispr branch `feat/issue-445-signal-based-trigger` against `main`. Look BEYOND the diff: take a holistic view of the wedge problem, the parked branch's prior work, and whether this rebase is the right shape. The founder explicitly asked for this — not just a code diff review.

## Context

EnviousWispr is a 2-person macOS voice-to-text company. Saurabh is founder and product owner; Claude Code is the sole engineer. ~5 active production users. Heart path (audio capture → ASR → paste) must never fail. Limbs may degrade.

## What this branch is

Issue #445 has two phases of work:

1. **Parked branch `feat/issue-445-model-load-watchdog`** (commit `3f6fe09`, NOT pushed). Built service-level recovery infrastructure: XPC connection invalidate, post-condition guard, prewarm cleanup, `cancelInFlightLoad`, telemetry events (`wedge_detected`, `launch.model_preload_completed`), Sentry breadcrumb categories, single-flight prepare task on WhisperKit. Trigger condition: `raceWithTimeout(20s)` wall-clock deadline. Founder rejected the timer trigger because picking 20 seconds had no defensible justification (single-sample-plus-headroom over 14s cold-load reference, which the new global rule `~/.claude/rules/no-arbitrary-timeouts.md` explicitly forbids).

2. **This branch `feat/issue-445-signal-based-trigger`** (forked from `3f6fe09`). One commit on top of the parked branch. Replaces the trigger only:
   - Deletes `Sources/EnviousWisprCore/Timeout.swift` (the 20s deadline machinery).
   - Deletes `Tests/EnviousWisprTests/TimeoutTests.swift`.
   - Drops `ModelLoadWatchdog.deadlineMs`. Keeps `WedgeError` and `userMessage`.
   - Adds `Sources/EnviousWisprCore/LoadProgressWatcher.swift` — `@MainActor` watcher that consumes the existing 8Hz progress polling stream and tracks per-attempt inter-signal cadence with a monotonic clock.
   - Adds `raceWithSignalWatcher(_ work, against watcher)` race helper.
   - Adds `loadProgressTickReporter` to `ASRManagerInterface` so `TranscriptionPipeline` can plumb a watcher into the proxy's existing 8Hz polling without growing AppState collaborators.
   - Wires `LoadProgressWatcher` into `TranscriptionPipeline` (Parakeet) replacing `raceWithTimeout`.
   - **Reverts** the WhisperKit pipeline's wrap to a bare `try await backend.prepare()`. WhisperKit `MLModel.load` is a black box with no progress signal source, so signal-based detection cannot apply. Wedge coverage for WhisperKit needs a different signal source (XPC service heartbeat) and is a separate design — explicit non-goal.
   - Extends the `modelLoadWedged` PostHog event to include the watcher snapshot fields (`silence_ms`, `observed_max_gap_ms`, `observed_phase`, `signal_count_total`, `first_signal_latency_ms`, `total_attempt_duration_ms`) — additive only.
   - Mock `ASRManagerInterface` conformers in tests get the new property as a stored var.
   - Tests: `Tests/EnviousWisprTests/Core/LoadProgressWatcherTests.swift`.

## Trigger design

`LoadProgressWatcher` fires when both:

- **Floor:** silence > 800ms. Grep-cited precedent: `Sources/EnviousWisprAudio/AVCaptureSessionSource.swift` first-buffer liveness latch is 800ms — the only foreground-user-watching silence threshold in our codebase.
- **Ratio:** silence > 5x the worst inter-signal gap observed so far in this same attempt. Statistical "definitely abnormal." Threshold self-calibrates per-attempt.

Pre-first-signal silence does NOT fire — the watcher only arms once the first real progress signal arrives. Pre-first-signal wedges are uncovered by this PR (acknowledged non-goal). Recovery requires a defended first-signal-latency duration, which we don't have data for.

Monotonic clock used (`ProcessInfo.processInfo.systemUptime`) so sleep/wake doesn't skew calculations.

## What I want from you

**Holistic, not narrow.** Consider:

1. **Is the trigger right?** Floor 800ms + ratio 5x — does this defend itself in production for the actual wedge symptom (compile-phase silence after some progress)? Where does this design break? Pre-first-signal coverage is acknowledged as deferred — anything else uncovered?

2. **Is the rebase shape right?** Should the trigger replacement live on top of the parked branch (one PR with everything: telemetry + recovery + new trigger), or should the parked-branch work be split into smaller PRs first? Founder is past Gate 2 on the overall approach — they want to ship this once.

3. **WhisperKit revert defensible?** The 2026-04-24 issue comment reports WhisperKit also wedges. The 2026-05-07 handoff narrowed scope to Parakeet. Is reverting the WhisperKit wrap (taking us back to today's main behavior for WhisperKit, no watchdog) the right choice, or should we keep some safety net for WhisperKit that doesn't violate the no-arbitrary-timeouts rule?

4. **Any code reality issues?** Walk the diff — `git diff main...HEAD` — for type errors, lifecycle bugs, race conditions, MainActor isolation hazards in the new `assumeIsolated` block in `ASRManagerProxy.startProgressPolling`, missing test coverage for any failure mode.

5. **Heart-path safety.** The recovery branch in `TranscriptionPipeline` mutates `audioCapture.abortPreWarm()`, sets `state = .error(...)`, calls `asrManager.cancelInFlightLoad()`. Is the order correct? Could a race between the watcher firing and `loadTask.value` returning leave any state inconsistent?

6. **Is anything missing from the parked branch's work that this rebase silently dropped?** Compare main vs HEAD; flag if any infrastructure on the parked branch got lost in the rebase.

7. **Does this actually solve the founder's problem?** The complaint: production wedges with zero Sentry visibility, users force-quit. Does this branch produce visibility? Does it recover automatically? Does any part of the design introduce a NEW failure mode that's worse than the wedge?

## Verdict

Return one of:

- **PROCEED** — ship as is. List any tiny tightening notes that don't block.
- **PROCEED-WITH-REVISIONS** — list specific revisions with file:line references and an exact patch where possible.
- **PIVOT** — the design is wrong; explain why and what to do instead.

Use grep evidence (file:line citations) for every code claim. Be specific — vague concerns get discarded.
