# #1784 latency receipt — 2026-07-25

## Headline: the detector-only measurement is the one that answers the question

Direct replay of committed fixtures through SilenceDetector under both configurations,
median of 5 runs each, no app / mic / polish / paste involved:

| fixture | chunks | bare (.all) per-chunk | pinned (.cpuAndNeuralEngine) per-chunk | delta |
|---|---|---|---|---|
| normal-speech | 36 | 0.344 ms | 0.342 ms | **-0.002 ms** |
| mumbled-speech | 56 | 0.349 ms | 0.347 ms | **-0.002 ms** |

The detector is ~0.1% of pipeline time. **No measurable cost; if anything marginally faster.**

## End-to-end paired run (retained for completeness, and as a lesson)

Arm A = baseline d2f903c1 dev build. Arm B = this change. Alternating blocks A1 B1 B2 A2 A3 B3,
five fixtures per pass, both engines, timing parsed from the first new `Pipeline timing TOTAL:` record
after a recorded log offset. Stopped early at founder request: 55/60 recordings, all usable.

- **parakeet**: n=15, median +0.0500s, bootstrap 95% CI [+0.0030, +0.0670], 12/15 positive
- **whisperKit**: n=10, median +0.0055s, bootstrap 95% CI [-0.3315, +0.1570], 5/10 positive
- **aggregate**: n=25, median +0.0410s, bootstrap 95% CI [-0.0140, +0.0670] — includes zero

**Gate (paired median > 0 AND CI excludes zero): PASS** — no statistically supported regression.

### Why this run was the wrong instrument

Parakeet showed +0.050s with a CI excluding zero, which looked like a real cost on the default
engine. Decomposing it by stage shows where it actually sat:

| stage | parakeet delta | whisperKit delta |
|---|---|---|
| ASR | +0.001s | -0.002s |
| polish | +0.013s | +0.012s |
| paste | +0.030s | -0.003s |

ASR is the only stage where detector contention could appear, and it is flat. The delta sits in
paste and polish — stages that run after the detector has finished, with no causal path to it.
Arm A paste spread 0.255-0.277s; arm B 0.256-0.359s: same floor, a few spikes.

A hypothesis that the detector now contends with Parakeet on the Neural Engine (Parakeet runs
`.cpuAndNeuralEngine`, WhisperKit is pinned `.cpuAndGPU`) was stated in advance and is REFUTED by
the ASR row and by the detector-only measurement above.

**Lesson, promoted to validation-discipline.md RULE: capture-polish-latency-per-bucket:** measure at
the component when the component is a small fraction of the pipeline. 55 recordings over ~30 minutes
produced a misleading number; the correct measurement took 0.7 seconds. Two suitable instruments
already existed, including telemetry shipped the previous night.

Raw samples: /tmp/1784-latency.jsonl (55 rows). Baseline SHA d2f903c1.
