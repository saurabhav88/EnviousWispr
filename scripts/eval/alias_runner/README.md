# AliasRunner

Local Swift CLI that drives the shipped `WordSuggestionService` over a JSONL corpus. Used by `scripts/eval/alias_suggestion_gate.py` for the alias-suggestion benchmark (issue #637).

**Not a shipped component.** Never built by the root `swift build`. Never bundled into the app. Dev tooling only.

## Build

```bash
cd scripts/eval/alias_runner
swift build -c release
```

The built binary ends up at `scripts/eval/alias_runner/.build/release/AliasRunner`.

## Use

```bash
./.build/release/AliasRunner \
  --corpus ../corpus/alias-corpus-a.jsonl \
  --out /tmp/alias-corpus-a-candidates.jsonl \
  --disable-timeout
```

Options:
- `--corpus <path>` (required) — JSONL, each line must have at minimum `{"id": String, "canonical": String}`. Extra fields are ignored.
- `--out <path>` — write JSONL to this file. Omit to write to stdout.
- `--sleep-seconds N` — optional inter-case sleep. Default `0`.
- `--disable-timeout` — bypass the production 5-second `withThrowingTimeout`. Recommended for benchmarks so true latency is measured (founder direction 2026-05-05 question 5).
- `--cold-start-subset K` — sample K cases evenly across the corpus and treat them as cold-start, sleeping `--cold-idle-seconds` before each. Default 0 (all warm).
- `--cold-idle-seconds S` — idle time before each cold-start case. Default 180 (3 min). Per `validation-discipline.md §9`, cold-cache benchmarks need idle time > 5 min; bump this to 300 for canonical cold runs.

## Output shape

One JSON object per line, keys sorted alphabetically:

```json
{
  "canonical": "Saurabh",
  "cold_start": false,
  "error": null,
  "filtered_aliases": ["Sourabh", "Sorab"],
  "id": "ALIAS-CORPUS-A-PERSON-001",
  "latency_ms": 1240,
  "predicted_category": "person",
  "raw_aliases": ["Sourabh", "Sorab", "Saurabh"],
  "timed_out": false
}
```

The split between `raw_aliases` and `filtered_aliases` is the whole point: raw shows what AFM actually emitted, filtered shows what production would surface to the user. The scorer needs both to grade the degeneration axis.

## Exit codes

- `0` — every case attempted. Per-case failures are reported via `error` lines; caller (Python) decides how to account for them.
- `2` — startup failure: corpus missing/malformed, Apple Intelligence unavailable on this machine (first-case `framework_unavailable` is fatal).

## Troubleshooting

- **"first case reported framework_unavailable"** — Apple Intelligence is not enabled on this Mac, or the on-device model has not finished downloading. Check System Settings → Apple Intelligence & Siri.
- **"corpus has zero cases"** — the JSONL is empty or every line is whitespace.
- **"corpus line N is not a valid CorpusCase JSON object"** — a line is malformed or missing the `id` / `canonical` fields.
