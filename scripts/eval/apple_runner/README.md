# AppleIntelligenceRunner

Local Swift CLI that drives the shipped `AppleIntelligenceConnector` over a JSONL corpus. Used by `scripts/eval/acceptance_gate.py --mode bench` for the AFM polish quality benchmark (issue #372).

**Not a shipped component.** Never built by the root `swift build`. Never bundled into the app. Dev tooling only.

## Build

```bash
cd scripts/eval/apple_runner
swift build -c release
```

The built binary ends up at `scripts/eval/apple_runner/.build/release/AppleIntelligenceRunner`.

## Use

```bash
./.build/release/AppleIntelligenceRunner \
  --corpus ../corpus/ci_corpus.jsonl \
  --out /tmp/afm-candidates.jsonl
```

Options:
- `--corpus <path>` (required) — JSONL, each line must have at minimum `{"id": String, "asr_input": String}`. Extra fields are ignored.
- `--out <path>` — write JSONL to this file. Omit to write to stdout.
- `--sleep-seconds N` — optional inter-case sleep. Default `0`. Use only for the empirical thermal-throttle A/B described in the plan.

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
