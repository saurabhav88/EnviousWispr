# Adversarial Review — Issue #445 First-PTT Cold-Start Hang

You have read-only access to the full repository at `/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/`. Read whatever you need — code, tests, docs, plans, knowledge files. Source-of-truth for code is what's in `Sources/`, not what this prompt claims. **If anything in this prompt contradicts the code, the code wins and you should call it out.**

## What we're trying to do

Fix issue #445 (first-PTT-after-fresh-boot silent hang) before the next release. The plan in flight is `docs/feature-requests/issue-445-2026-05-06-first-ptt-cold-boot-hardening.md` — read it in full. We are deliberately rewriting it because the founder pushed back: "the app should be warmed and primed before the person even gets ready to press the first dictation. The plan I read involved safety hatches but no real solution to priming the app."

We are about to rewrite around three beats:

1. **Fix `cold_start` telemetry.** The current `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift:928` and `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift:1069` both emit `coldStart: false` as a hardcoded literal. Telemetry is broken. Replace with real cold-vs-warm detection so we can MEASURE the problem we're trying to solve.
2. **Aggressive launch-time prime.** At app open, walk the full press path in the background: load the model, start the audio engine, stabilize the format, prime XPC, then stand down. User never feels it. By the time they reach for the hotkey, every cold path has been paid. New `LaunchPrimer` helper that AppState owns.
3. **Safety nets (demoted from headline to fallback).** The four layers from the original plan — timeout on dispatch, drop the `try?` swallow, post-condition guard, readiness gate — stay because rare cases happen (model evicted under memory pressure, audio device hot-swapped, Mac slept and woke into a degraded state). They are not the primary fix; they catch what the prime missed.

Total estimate: ~200-280 lines across new prime helper, telemetry fix, four safety layers, plus tests. Tier MEDIUM. One PR.

## Hypothesis under test

**The dominant cause of silent churn from new installers is the cold-start hang on first PTT after fresh boot.** Aggressive launch-time prime eliminates the common case; safety nets catch the rare case. Honest telemetry tells us whether the fix worked.

## Raw evidence we are basing this on

### PostHog, last 30 days, **production environment only**, real users

- 422 `asr.completed` events from 14 distinct users.
- 422 `paste.completed` events. Top 30 paste latencies all 270-290ms cgevent, 100% success. Paste is healthy.
- 43 `pipeline.failed` events from 8 users. Top categories: "Couldn't catch that, try again" (23 events / 5 users), "No speech detected" (7 / 2 users), "Audio device disconnected" (3 / 1 user), "Model load failed: cancelled" (1 / 1 user), "Recording failed: Failed to create audio format" (1 / 1 user).
- **`cold_start` property is `false` for 100% of asr.completed events.** This is because the field is hardcoded `false` in the two pipeline emit-sites — telemetry is broken.

**First-press latency by user, sorted highest first** (each user's very first ASR event ever recorded, last 60 days):

| User (anonymized) | First-press latency_seconds | Total events | Active days |
|---|---|---|---|
| 3a54ae90 | **2.501 s** | 19 | 1 day |
| 70bea3e1 | **1.127 s** | 6 | 1 day |
| 399bbaa2 | 0.893 s | 2 | 1 day |
| 0623b431 | 0.414 s | 18 | 1 day |
| 4baf8d3f | 0.303 s | 61 | 4 days |
| f4b74b26 | 0.195 s | 2 | 1 day |
| 76b94d01 | 0.189 s | 13 | 1 day |
| 1319026f | 0.157 s | 7 | 2 days |
| dfc82c08 | 0.155 s | 43 | 7 days |
| (rest) | <125 ms | varies | varies |

**Retention picture, last 60 days:** 25 distinct users with `app.launched` or `asr.completed` events. **9 of 25 are one-and-done** (one or two ASR events ever, never returned). That is 36% silent churn. We do not know the cause.

### Sentry, last 14 days, **production environment only** (dev events excluded)

| Fingerprint | Prod events | Prod users | Title |
|---|---|---|---|
| ENVIOUSWISPR-M | 13 | 4 | `paste_failed: Paste cascade fell back to clipboard after tiers:` (already addressed via PR #596) |
| ENVIOUSWISPR-B | 5 | 3 | `asr_empty_result: ASR returned empty text despite speech evidence` |
| ENVIOUSWISPR-C | 2 | 1 | redacted |
| ENVIOUSWISPR-P | 2 | 1 | `asr_empty_result: WhisperKit ASR returned empty text despite speech evidence` |
| ENVIOUSWISPR-Q | **1** | **1** | `audio_capture_failed: Failed to create audio format.` |
| ENVIOUSWISPR-N | **1** | **1** | `xpc_service_error: Audio XPC interrupt (capturing=true)` |

**Smoking gun, ENVIOUSWISPR-Q breadcrumbs (cleaned):**

```
[06:37:20] pipeline.pipeline     Pipeline complete    ← prior session, normal
                                                         (Mac slept overnight)
[04:33:09] pipeline.asr          Model loading        ← next morning, fresh press
[04:33:09] pipeline.recording    ERROR: audio_capture_failed: Failed to create audio format
```

Same-millisecond timestamp on "Model loading" and "audio capture failed" — both triggered by the press, both lost the race. Production user, real release v1.9.4, built-in mic. This is the visible variant of the silent #445 hang. It surfaces in Sentry because audio format negotiation throws; #445 hangs silently because `await backend.prepare()` does not throw, it just blocks for 10s to 170s.

**Cold-path canaries (Q + N) total in prod 14d: 2 events, 2 users.** This is essentially zero, which means cold-start hangs do not surface in Sentry. The hang is invisible to our error monitoring.

### Competitor architecture observations

Both inspected from `/Applications/`:

- **Wispr Flow 1.5.185.** Electron app, four helper processes (GPU, Plugin, Renderer, main Helper), 119MB asar bundle, no local ASR model. Squirrel auto-updater registered as launchctl entry. Cloud ASR architecture. Stays running in menubar by default — first-press cold-start is essentially eliminated by being always-on.
- **superwhisper 2.12.1.** Native Swift app, similar shape to ours. ArgmaxSDK (whisperkit derivative), libllama (local LLM), libonnxruntime, full ggml suite, Sparkle auto-updater. No launch agents. Bundled feedback sounds (Start1-4, Stop1-4, PreStop, noResult, Loop, Intro) suggest mature UX around start/stop signaling. Likely strategy: aggressive prewarm at launch.

We do not have Handy installed.

### Founder context (heart-path is sacred)

- 2-person company. Founder is product owner (CSM at Qualtrics, not engineer). Claude Code is sole implementer.
- Heart path = trigger → audio capture → ASR → text finalization → clipboard/paste. Must always complete.
- Limbs (LLM polish, custom words, filler removal, language hints) may degrade or fail; user still gets raw text.
- Sub-second pipeline latency target.
- "Production-grade from day one." No shortcuts.

## What we need from you

**Read the existing plan file `docs/feature-requests/issue-445-2026-05-06-first-ptt-cold-boot-hardening.md` and the current code (especially `Sources/EnviousWispr/App/AppState.swift`, `Sources/EnviousWisprPipeline/TranscriptionPipeline.swift`, `Sources/EnviousWisprPipeline/WhisperKitPipeline.swift`, `Sources/EnviousWisprAudio/`, and `Sources/EnviousWisprASR/ASRManager.swift`).**

Then attack this hypothesis adversarially. Be specific, grep-cite, and assume the data above can be wrong.

### Q1 — Hypothesis attack

Is the cold-start hang plausibly the dominant cause of the 36% silent churn? Or is there a stronger candidate hiding in the data we should investigate before committing engineering effort?

Specifically address:
- Could the silent churn be onboarding friction (permission denials, hotkey conflict with macOS shortcuts, model download progress hidden, paste tier confusion) rather than cold-start?
- Could `asr_empty_result` (ENVIOUSWISPR-B, the second-most-common prod error) be more impactful than we're treating it?
- The paste_failed fingerprint M was 14 events in raw view, 13 in prod-only — already addressed via #596 in this release. Anything else we should be addressing?
- The first-press latency table shows 2.5s as the WORST case observed, with most users below 250ms. If the hang is really 10-170s, why don't we see that in PostHog at all? (The `pipeline.failed` event for "Couldn't catch that — try again" fires 23 times — could the hang be turning into one of these?)

### Q2 — Beat 2 design attack (the prime)

The proposed prime walks the full first-press sequence in the background at launch. Read the actual code — does this work?

Specifically:
- What does `audioCapture.startEnginePhase()` actually do? If we call it at launch, does it consume the mic indicator visibly to the user (privacy / UX concern — green dot in menubar)?
- Can we start the audio engine, leave it running idle, and have the first real press succeed without re-paying the cold cost?
- The two ASR pipelines (`TranscriptionPipeline` and `WhisperKitPipeline`) have separate `isStarting` guards and separate startup flows. Does priming one prime the other? If user switches backends at runtime, does the prime need to re-fire?
- `asrManager.loadModelSilently()` already runs at launch (AppState.swift:643). What additional warming would actually move the needle? Be specific about what cold paths it does NOT cover today.
- macOS resource-reclamation: if the app sits idle for an hour, does the OS evict the model from RAM? Does the audio engine go cold? If yes, the prime needs a maintenance pass too — what should the schedule look like?

### Q3 — Beat 3 design attack (safety nets)

The four safety layers (timeout on dispatch, drop `try?`, post-condition guard, readiness gate) — are they still all needed once Beat 2 is in place? Should any be cut? Are any dangerously redundant?

Specifically:
- The proposed timeout is 8 seconds. Look at the current `await backend.prepare()` typical durations from logs / breadcrumbs. Is 8s the right number, or should it be tighter (5s) once the prime has run?
- Layer D (readiness gate that paints "Starting up..." and drops the press) — if Beat 2 prime works, is this still useful? Or is it a tell that Beat 2 isn't trusted?
- The `recoverFromStartTimeout` helper issues a `.requestStop` to release the pipeline's `isStarting=true` guard. Is this safe? Could it race with a still-in-flight `backend.prepare()` and cause a worse failure mode?

### Q4 — Telemetry fix (Beat 1)

`coldStart: false` is hardcoded in two emit sites. What's the right shape for actually detecting cold-start in code?

Specifically:
- Is "this is the first press of this app session" the right definition of cold? Or should it be "this is the first press after model was loaded into RAM"?
- Where in the pipeline can we actually observe the cold-vs-warm signal? Is it on the backend (`isReady` transitions from false → true), or in the pipeline state machine (`.startingUp → .loadingModel → .recording`), or somewhere else?
- Is there value in a multi-tier signal (cold/warm/hot) versus binary?

### Q5 — Architectural risk

This change adds an at-launch background task that can fail silently if not careful. What can go wrong?

Specifically:
- If the prime fails (audio device unavailable at launch, model file corrupt, XPC service crashed at boot), does the user notice? What state should the app be in?
- The architecture-rules.md "Heart is sacred" rule — does the prime violate it? It's pre-warming heart-path infrastructure, but if the prime crashes the app at launch, every user is dead. How do we make the prime itself a limb?
- AppState concrete-collaborator ceiling is 19/19 (per `Tests/EnviousWisprTests/Architecture/AppStateCeilingsTests`). Adding a `LaunchPrimer` reference to AppState would push to 20/19. Where should `LaunchPrimer` actually live?

### Q6 — Sequencing

Should this fix ship in this release or get a dedicated release? The current release contains a lot of other work (Your Words redesign, in-app update banner, polish picker rework, custom-words frequency tracking, AFM polish telemetry, WhisperKit migration). Is bundling #445 with all that increasing release risk too much?

## Output format

Per question (Q1-Q6), give us:
- Verdict: PROCEED-AS-PLANNED / PROCEED-WITH-REVISIONS / PIVOT / SPLIT-PR
- Reasoning, grep-cited where the claim references code
- If revising or pivoting, the specific change to the plan

Then a final summary section with your top 3 findings and what changes the plan should make before we go to council.

Be brutal. The cost of a silent retention killer in production is much higher than the cost of being told the plan needs another pass.
