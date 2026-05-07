# Grounded Review — Issue #445 Plan Rewrite

You have read-only access to the full repository at `/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/`. **The code is the source of truth.** If anything in this prompt or the plan file contradicts the code, the code wins and you should call it out.

## Context

The issue #445 plan was rewritten today after empirical investigation reframed the problem. Original plan: aggressive launch prime + four safety nets. Revised plan: model-load watchdog + heavy parallel telemetry (Sentry AND PostHog) + dropped-`try?` + post-condition guard.

Reframe was driven by:
1. Founder reproduced the bug today on production v1.9.4 work-laptop. Symptom: spinning wheel → "Model loading" overlay → indefinite hang. Normal Cmd-Q clears it (NOT force-quit).
2. Sentry has zero production events in the last 24 hours despite the founder hitting the wedge today. Defect is silent end-to-end.
3. PostHog's `cold_start` property is hardcoded `false` in two pipeline emit-sites. Telemetry has been broken since launch.
4. Three friends reported the same wedge to the founder. N=4 qualitative reports against ~25 production users in 60 days. 9 of 25 users in 60 days are one-and-done (36% silent churn, possibly attributable to this defect).
5. Live cold-launch reproduction in this session: app cold-restarted, first press at 8 minutes after launch was 188ms total (audio engine 150ms of that). The slow-warmup case is fine; the hang case is a TRUE wedge in the model-load await.

## What we need from you

**Read the plan file at `docs/feature-requests/issue-445-2026-05-06-first-ptt-cold-boot-hardening.md`.** Then read the actual code (especially `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift` lines 340-400 and `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift` lines 410-470, plus `Sources/EnviousWispr/App/AppState.swift` lines 540-602).

Then answer these questions adversarially. Be brutal. Grep-cite every claim. The cost of a hidden defect or unfounded claim shipping is high.

### Q1 — Wedge-cancellation reality check

The plan assumes that wrapping `try await loadTask.value` (Parakeet) and `try await backend.prepare()` (WhisperKit) in a structured-concurrency timeout, and cancelling the held task on timeout, will actually unwedge the model load. This requires the underlying libraries (FluidAudio for Parakeet, WhisperKit/Argmax for WhisperKit) to observe `Task.isCancelled` and unwind cooperatively.

**Read the dependency code (`.build/checkouts/FluidAudio/`, `.build/checkouts/WhisperKit/` or wherever they live, plus `Package.resolved` for SHAs) and verify:**
- Does `FluidAudio.AsrManager.loadModel()` check `Task.isCancelled` or otherwise observe Swift cooperative cancellation?
- Does `WhisperKit.WhisperKit.prepare()` (or whatever the actual prepare entry point is) do the same?
- If either does NOT, the plan's cancellation mechanism doesn't actually unwedge — it just abandons the Task while the underlying work continues. The next press would race against the still-running first load.

If a library doesn't cancel cooperatively, what is the plan's actual recovery shape? Is the user-facing recovery still correct (state machine resets, "tap to retry" overlay) even if the background work is still running?

### Q2 — Watchdog placement on WhisperKit

The plan proposes hoisting `try await backend.prepare()` (WhisperKitPipeline.swift:434) into a held `Task<Void, Error>` and applying the watchdog. But the surrounding code at lines 427-443 has explicit late-completion guards (`guard state == .loadingModel else { return }`).

**Verify by reading:**
- Does the proposed hoist preserve those guards correctly?
- The actor isolation context — `WhisperKitPipeline` may be `@MainActor` or have its own actor. Does spawning a `Task { try await backend.prepare() }` inside `startRecording` create an actor-hop that changes timing or correctness?
- Is there an existing `prepareTask: Task<Void, Error>?` field, or do we need to add one? Check the full file.

### Q3 — Sentry + PostHog parallel emit pattern

The plan claims every new signal goes to both Sentry AND PostHog. **Verify by grepping the existing telemetry surfaces:**
- Does `SentryBreadcrumb` (the wrapper) exist? Where? What is its API surface?
- Does `TelemetryService.shared` (PostHog) exist? Where? What's the API for adding new event methods?
- Is there a precedent in the codebase for emitting the same signal to both systems in parallel?
- Are there existing PostHog events that fire on state transitions? Or is this entirely new?

If the parallel-emit pattern is novel, what's the right shape for a small wrapper that fires both with a single call site, without duplicating the call? (Or is duplicating intentional and fine?)

### Q4 — Post-condition guard correctness (Beat 2)

The plan has Beat 2 add a post-condition guard at the dispatch site (`AppState.swift:591`):
```
let pipelineActive: Bool = isWhisperKit ? whisperKitPipeline.state.isActive : pipelineState.isActive
if !pipelineActive { recover... }
```

**Verify by reading the actual code at AppState.swift:540-602:**
- Is there a race between the dispatch returning and reading `state`? On WhisperKit, `state` is mutated inside the pipeline; the read here is post-await but the state transition might be on a different actor.
- Does the watchdog timeout in Beat 1 already produce the right state on the inner side (pipeline transitions to `.error(...)`)? If yes, the post-condition check is redundant for the wedge case but still useful for other silent-failure modes — confirm.
- Is `setExternalError(...)` from a recovery path safe when the pipeline is in `.error(...)` state already? Could it cause an overlay-flash overwrite?

### Q5 — Watchdog threshold tuning

The plan picks 25 seconds. Stated reasoning: above the 14-second cold-load reference at `AppState.swift:950`, below the "indefinite" wedge experience.

**Verify the 14-second claim:**
- Read `AppState.swift:950` and surrounding context. Does it actually document 14 seconds of cold load? In what conditions?
- Are there any other documented latency observations in the codebase for `loadModel()` or `backend.prepare()`?
- Is 25 seconds tight enough for user-recovery perception, or should we go shorter (e.g., 15-18s) and accept that some legitimate slow loads will be timed out (with the user-recoverable "tap to retry" pattern)?

### Q6 — Live UAT fault-injection feasibility

The plan calls for a debug-only fault-injection that forces `loadModel()` (Parakeet) or `backend.prepare()` (WhisperKit) to sleep 30 seconds, so the watchdog's recovery path is deterministically testable.

**Verify:**
- Does the V2 fault-injection harness mentioned (`Tests/RuntimeUAT/faultInjection.py` from #557/#558) actually exist? At what path? What's its current API surface?
- Is the right injection point the ASR backend, the pipeline `loadModel` call site, or somewhere else?
- Is there an existing `EW_FAULT_INJECT_*` env-var pattern in the codebase to follow?

### Q7 — Anything else the plan missed

Free-form. After reading the code, what does the plan get wrong, miss, or hand-wave? Specifically check:
- AppState concrete-collaborator ceiling claim (currently 19, plan adds 0).
- AppState line-count claim (currently 978, plan adds ~25).
- Any false grep claims in §10.
- Any places where the plan says "existing X" when X doesn't exist.

## Output format

For each question (Q1-Q7), respond with:
- Verdict: PROCEED-AS-PLANNED / PROCEED-WITH-REVISIONS / PIVOT
- Reasoning, grep-cited
- If revising: the specific edit to the plan

Then a final summary with your top 3 findings and what the plan should change before council.

Be brutal. Find the load-bearing assumption that's wrong before we ship code on it.
