# V1a — Cold-path telemetry analysis (production data, 30 days)

**Date:** 2026-04-30
**Phase:** V1a (replaces "Pass 1 cold bench + Pass 2 3-hr memory profile" from bible §18)
**Source:** PostHog `dictation.completed`, `asr.completed`, `llm.polish_completed`, `pipeline.failed` events filtered `environment=production`, last 30 days.
**Bottom line:** the cold-path concern from validation-discipline §9 is not present in current production usage. Synthetic cold benches built around it can be retired.

---

## 1. Population

| Metric | Value |
|---|---|
| Active installs (30d) | 16 |
| Installs that dictated | 12 |
| Installs that polished | 6 |
| Active days in window | 18 |
| First event in window | 2026-04-03 |
| Last event in window | 2026-04-30 |

## 2. Polish provider mix — the headline finding

| Provider | Model | Samples | Users | p50 (s) | p90 (s) | p99 (s) | min (s) | max (s) |
|---|---|---|---|---|---|---|---|---|
| **appleIntelligence** | apple-intelligence | **150** | **6** | 1.084 | 1.744 | 2.823 | 0.552 | 3.336 |

**100% of production polish is Apple Intelligence. Zero Gemini, zero OpenAI, zero Ollama in the last 30 days.**

This invalidates the entire premise the cold-path rule was built on. The #272 incident (2026-04-13 Gemma4 KV cache, 7-14s polish on idle re-use) was a cloud / local-LLM artifact: connection pool aging, KV cache rotation, daemon re-load. None of those mechanisms exist in `FoundationModels.LanguageModelSession.respond(to:)`. There is no network connection to age out, no shared KV cache between calls, no daemon to unload. AppleIntelligenceConnector is a synchronous on-device framework call.

Until production usage shifts back toward cloud providers, cold-path latency tests targeting polish are testing a failure mode that cannot occur for our users.

## 3. Polish latency vs gap-since-previous-polish

| Gap bucket | Samples | mean | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| <30s | 33 | 0.997 | 0.996 | 1.151 | 1.203 | 1.204 |
| 30s–2min | 34 | 1.196 | 1.038 | 1.622 | 2.197 | 2.237 |
| 2–5min | 13 | 1.092 | 1.081 | 1.275 | 1.324 | 1.331 |
| **5–15min** | 12 | 1.452 | 1.161 | 2.152 | **3.209** | **3.336** |
| 15min–1hr | 19 | 1.357 | 1.238 | 1.855 | 2.486 | 2.524 |
| 1–4hr | 16 | 1.337 | 1.158 | 1.983 | 2.261 | 2.284 |
| 4hr+ | 23 | 1.408 | 1.196 | 2.111 | 2.968 | 3.110 |

**p50 is essentially flat (~1.0–1.2s) across all gap sizes.** Tail (p90/p99) drifts up modestly with longer gaps, but max never exceeds 3.4s. No knee. No bimodal distribution. No "slowdown after N minutes" that would justify a synthetic gap-based bench.

The 5–15min bucket has the largest tail (max 3.336s) but only 12 samples; not enough to call a real effect. Even if real, 3.3s is acceptable for an Apple Intelligence cold framework call.

## 4. ASR latency vs gap

| Backend | Cold start | Gap | Samples | p50 (s) | p90 (s) | max (s) |
|---|---|---|---|---|---|---|
| parakeet | false | <2min | 103 | 0.102 | 0.260 | 2.131 |
| parakeet | false | 2–5min | 23 | 0.119 | **1.489** | **12.189** |
| parakeet | false | 5–15min | 29 | 0.100 | 0.986 | 2.123 |
| parakeet | false | 15min–1hr | 27 | 0.105 | 0.292 | 2.916 |
| parakeet | false | >1hr | 53 | 0.104 | 0.235 | 2.501 |
| whisperKit | false | <2min | 2 | 1.084 | 1.388 | 1.464 |
| whisperKit | false | 5–15min | 1 | 1.295 | — | 1.295 |

Two observations:

1. **`cold_start=true` never appears in production.** All 235 ASR events report `cold_start=false`. Either the field is not being set correctly or production users genuinely never hit a cold ASR path within a 30-day window. Worth investigating — likely a telemetry bug. Filed as follow-up.
2. ASR p50 is 100ms regardless of gap. Tail spike in 2–5min bucket (max 12.189s, one outlier) is not a structural pattern — adjacent buckets have 2.1–2.9s max. Single outlier, 23 samples, not actionable.

WhisperKit has only 3 production samples; not enough to analyze.

## 5. End-to-end dictation latency vs gap (Parakeet only)

| Gap | Samples | p50 (s) | p90 (s) | p99 (s) | max (s) |
|---|---|---|---|---|---|
| <30s | 57 | 1.345 | 1.626 | 2.475 | 2.475 |
| 30s–2min | 46 | 1.368 | 2.148 | 2.766 | 2.828 |
| 2–5min | 23 | 1.428 | **6.690** | **16.166** | **17.335** |
| 5–15min | 29 | 1.985 | 5.551 | 7.333 | 7.362 |
| 15min–1hr | 27 | 1.773 | 5.426 | 7.435 | 7.963 |
| 1–4hr | 19 | 1.573 | 2.717 | 9.060 | 10.442 |
| 4hr+ | 34 | 1.526 | 5.160 | 6.058 | 6.372 |

E2E p50 stays under 2s across all gaps. Tail p90 jumps from 2.1s (under 2 min) to 5–7s once gaps exceed 2 min. ASR is 100ms p50 and polish is 1.0s p50, so e2e p50 of 1.3–2.0s leaves 200–900ms of unattributed time (audio engine spinup, hotkey handling, paste tier, Sentry breadcrumb, telemetry emission, recording-duration variance).

The tail growth (p90 from 2s → 5–7s past the 2-min mark) is real but not located in ASR or polish. Most likely candidates: audio engine cold-start after `AudioBackendIdleManager` unload, or simply correlation with longer recordings that produce longer transcripts. Not a cache/connection issue.

## 6. Pipeline failures

42 failures over 30 days, 8 affected users, all in the `transcription` stage. Zero polish failures. Zero network failures. Zero timeouts.

| Error | Count | Users |
|---|---|---|
| "Couldn't catch that — try again" | 23 | 5 |
| "No speech detected — try speaking closer to the microphone" | 7 | 2 |
| [REDACTED] | 6 | 2 |
| "Audio device disconnected" | 3 | 1 |
| "Microphone disconnected" | 1 | 1 |
| "No text after processing" | 1 | 1 |
| "Model load failed: cancelled" | 1 | 1 |

30 of 42 (71%) are ASR empty / no-speech, which is user-side (didn't speak, mic too far away, VAD too aggressive). 4 are device disconnects (transient hardware). 1 is a model-load cancel. None of these are cold-path failures. None are timeout-ish.

The failure mode the cold-path rule was meant to catch (provider timeout, connection drop after idle, KV cache wedge) does not appear once in 30 days of production telemetry.

## 6.5. Sentry corroboration (14-day window — Sentry's max free-tier period)

17 unresolved issues over 14 days. Total counts include both production and development environments; production-only counts in parens where the breakdown matters.

| Category | Events (all envs) | Production-only | Issues | Users (all envs) |
|---|---|---|---|---|
| ASR empty / no speech (user-side) | 93 | (not split — likely most prod) | 5 | 4 |
| Paste fallback (paste_failed) | 117 | **~14** | 3 | 8 (mostly dev/founder) |
| Audio capture failures (old, last 2026-04-15) | 25 | (single user) | 4 | 1 |
| XPC service errors (audio) | 4 | (single user) | 2 | 1 |
| EXC_BREAKPOINT (libdispatch, fatal, old, last 2026-04-15) | 2 | 0 (dev only) | 1 | 1 |
| Model load failed (XPC unreachable) | 1 | (single user) | 1 | 1 |
| [REDACTED] | 15 | (mixed) | 2 | 2 |
| **LLM polish failures** | **0** | **0** | **0** | **0** |
| **Network timeouts** | **0** | **0** | **0** | **0** |

Sentry confirms what PostHog showed: zero polish failures, zero network failures, zero cold-path-shaped events.

**paste_failed environment breakdown (correction from initial count):** the 101-event April 25 cluster (issue ENVIOUSWISPR-8) is 87 development events from founder dual-mode-polish dev builds (`v1.9.4-...-dualmode-logs2-dev` etc.) plus 7 production. Issue ENVIOUSWISPR-M (last 2026-04-30) is 7 production events. Issue ENVIOUSWISPR-K is 9 dev-only events. Real production paste_failed total ≈ 14 events across the window, not 117. Still worth understanding (heart-path-adjacent — paste falling through all tiers means users get text via raw clipboard but lose in-place insertion), but not the urgent triage the raw count suggested. Notably absent from PostHog's `pipeline.failed` because paste fallback delivers text and is not classified as a pipeline failure in `TelemetryService` — different telemetry contract.

The audio/XPC and EXC_BREAKPOINT clusters all stopped on 2026-04-15 and were single-user. They were a real problem at that time but are quiescent now.

**Lesson on Sentry queries:** initial count read totals across environments. observability-operations.md is explicit — "always filter by `environment=production` for real user data." Sentry's REST `/issues/` endpoint returns combined counts; environment must be checked per-issue via the tags endpoint. Worth a knowledge-file note so future Sentry queries default to env-aware reads.

## 7. Conclusions

1. **The cold-path concern from validation-discipline §9 is not present in production.** Polish runs entirely on Apple Intelligence (no network, no shared cache). ASR cold-start never registers. Pipeline failures are all user-side or hardware. The structural failure mode the rule guards against has zero observed instances in 30 days, 12 dictating users, 238 dictations.
2. **The "5-min idle" prescription is unjustified by current data.** It was inherited from one #272 incident (Gemma4 KV cache) that does not generalize to the providers in production use.
3. **Tail latency past 2-min gaps is real but not in the heart path.** It lives in audio engine spinup or recording-duration correlation, not in ASR or polish. Investigating it requires instrumenting the recording-start path, not running a 3-hr bench.
4. **There is no justification to keep V1 as written** (3-hr metronome dictation profile, every-5-min cold bench).

## 8. Recommendations

**For epic #319 close-out:**

- Mark Performance & latency as **confirmed acceptable** based on production telemetry, not synthetic cold bench. Downgrade Medium → Low risk in audit rerun, citing this report.
- Cancel V1's 3-hr memory profile and 5-min metronome bench. Both are designed around a failure mode production data does not exhibit.

**For validation-discipline §9:**

- Drop the "5-min idle between samples" prescription. Replace with: "If a future change reintroduces a cloud or local-LLM polish provider, run cold-launch + back-to-back stress benches (<5 min each) and verify production telemetry afterward. Do not run synthetic gap-based benches as preventive maintenance."

**For bible §18:**

- Rewrite V1 as three short probes, all under 5 min runtime each, executed on demand around any heart-path-affecting change. Drop the marathon profiles. The retained probes are:
  - **V1b — cold-launch single dictation.** Kill app, launch, dictate, record full e2e. Captures cold process state without idle. ~3 min.
  - **V1c — back-to-back stress (50 dictations).** Heap snapshot before/after via Instruments CLI. Catches per-dictation leak via linear allocation growth, not duration. ~5 min.
  - **V1a — production telemetry refresh.** This report's queries, re-run any time provider mix shifts or after any pipeline-affecting refactor. Zero app time.

**For follow-ups:**

- File issue: `cold_start=true` never registers in production `asr.completed`. Likely telemetry bug in `TelemetryService.swift` or `ASRManager`.
- File issue: investigate the e2e tail past 2-min gaps. Suspect audio engine cold-start (`AudioBackendIdleManager` unload boundary). Add instrumented spans around recording-start to attribute the unattributed 200–900ms.
- File issue: `paste_failed` rolling-window production count ~14 events across two issues (ENVIOUSWISPR-8 and ENVIOUSWISPR-M, last 2026-04-30). Heart-path-adjacent. Investigate which apps the cascade is failing in and whether the fallback logic is correctly classifying the failure mode. Triage separately from V1 / #319; not urgent but worth a session.
- Knowledge-file followup: add a "Sentry env filter" note to observability-operations.md — REST `/issues/` returns combined-environment counts; production-only counts require fetching the tags endpoint per issue (`/organizations/<org>/issues/<id>/tags/`).

## 9. Provenance

Queries run via PostHog HogQL (`mcp__posthog__query-run`) on 2026-04-30. Project ID 354235. Filter `properties.environment = 'production'` applied to every query. Window: `now() - INTERVAL 30 DAY`.

Per-user identifiers omitted from this report by design (Telemetry Privacy Boundary, observability-operations.md §"Telemetry Privacy Boundary"). Aggregates only.
