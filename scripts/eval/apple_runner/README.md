# AppleIntelligenceRunner

Local Swift CLI that drives the shipped `AppleIntelligenceConnector` over a JSONL corpus. Used by `scripts/eval/acceptance_gate.py --mode bench` for the AFM polish quality benchmark (issue #372).

**Not a shipped component.** Never built by the root `swift build`. Never bundled into the app. Dev tooling only.

## Build

Its sources are a target of the one eval package, `scripts/eval/Package.swift` (#4293), so all three runners share one build of the app's code:

```bash
swift build -c release --package-path scripts/eval --product AppleIntelligenceRunner
```

The binary's location comes from SwiftPM: `python3 scripts/eval/eval_bin.py AppleIntelligenceRunner` prints it (the gates use the same resolver).

## Use

```bash
"$(python3 scripts/eval/eval_bin.py AppleIntelligenceRunner)" \
  --corpus scripts/eval/corpus/ci_corpus.jsonl \
  --out /tmp/afm-candidates.jsonl
```

Options:
- `--corpus <path>` (required) — JSONL, each line must have at minimum `{"id": String, "asr_input": String}`. Extra fields are ignored.
- `--out <path>` — write JSONL to this file. Omit to write to stdout.
- `--sleep-seconds N` — optional inter-case sleep. Default `0`. Use only for the empirical thermal-throttle A/B described in the plan.

## Recipe overrides come from the environment

The connector reads three bench seams from the process environment: `EW_AFM_PROMPT_FILE` (instructions), `EW_AFM_EXAMPLES_FILE` (example turns, JSONL; empty file = no turns) and `EW_AFM_TRAILER_FILE` (correction trailer; empty file = none). A direct run inherits whatever your shell exports, so to measure the shipped recipe clear them first:

```bash
( unset EW_AFM_PROMPT_FILE EW_AFM_EXAMPLES_FILE EW_AFM_TRAILER_FILE; "$(python3 scripts/eval/eval_bin.py AppleIntelligenceRunner)" --corpus ... --out ... )
```

`acceptance_gate.py` does this for every arm (`_afm_arm_env`).

## Output shape

One JSON object per line:

- Success: `{"candidate": "polished text", "id": "CASE-ID"}`
- Failure: `{"error": "LLMError description", "id": "CASE-ID"}`

Keys are sorted alphabetically for stable diffs.

## Exit codes

- `0` — every case attempted. Per-case failures are reported via `error` lines; caller (Python) decides how to account for them.
- `2` — startup failure: corpus missing/malformed, Apple Intelligence unavailable on this machine (first-case `frameworkUnavailable` is fatal).

## Troubleshooting

- **"first case threw frameworkUnavailable"** — Apple Intelligence is not enabled on this Mac, or the on-device model has not finished downloading. Check System Settings → Apple Intelligence & Siri, or wait for the model download to complete.
- **"corpus has zero cases"** — the JSONL is empty or every line is whitespace.
- **"corpus line N is not a valid CorpusCase JSON object"** — a line is malformed or missing the `id` / `asr_input` fields.
