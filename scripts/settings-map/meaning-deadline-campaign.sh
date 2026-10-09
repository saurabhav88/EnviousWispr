#!/usr/bin/env bash
# Settings search meaning deadline campaign (#3545 plan §3.5).
#
#   scripts/settings-map/meaning-deadline-campaign.sh <output folder>
#
# Runs SettingsSearchMeaningCampaignTests (opt-in) in 31 fresh test processes through
# scripts/xcode-test.sh: 30 measure one process-cold first meaning pass each (cold:0 .. cold:29),
# then one runs an unmeasured warm-up and 30 measured warm passes. Every measured pass is a line
# in <output folder>/raw.jsonl; each run's log and result bundle are under <output folder>/runs/.
# It then writes <output folder>/summary.json (nearest-rank percentiles over ALL samples, with
# every outcome counted) and <output folder>/environment.txt (machine, OS, code, asset hashes).
# The output folder must not exist yet. Exit: 0 every run passed · 1 a run failed · 2 usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE="EnviousWisprTests/SettingsSearchMeaningCampaignTests"

die() {
  local code="$1"
  shift
  echo "meaning-deadline-campaign.sh: $*" >&2
  exit "$code"
}

[ $# -eq 1 ] || die 2 "usage: meaning-deadline-campaign.sh <output folder>"
OUT="$1"
[ ! -e "$OUT" ] || die 2 "$OUT already exists"
mkdir -p "$OUT/runs"
OUT="$(cd "$OUT" && pwd)"
RAW="$OUT/raw.jsonl"

# The measured source: HEAD plus a hash of every tracked change and untracked file under
# Sources/ and Tests/, taken before and after the runs; a difference fails the campaign.
source_identity() {
  {
    git -C "$ROOT" rev-parse HEAD
    git -C "$ROOT" diff HEAD -- Sources Tests
    git -C "$ROOT" ls-files --others --exclude-standard -z -- Sources Tests |
      xargs -0 -I{} shasum -a 256 "$ROOT/{}"
  } | shasum -a 256 | cut -d' ' -f1
}
BEFORE="$(source_identity)"
git -C "$ROOT" diff HEAD -- Sources Tests >"$OUT/measured-source.diff"

{
  echo "machine: $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string) memory=$(sysctl -n hw.memsize)"
  echo "os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "code: $(git -C "$ROOT" rev-parse HEAD)"
  echo "source: $(source_identity)"
  echo "configuration: Debug test process (scripts/xcode-test.sh), CPU-only Core ML"
  echo "assets:"
  (cd "$ROOT/Sources/EnviousWispr/Resources/SettingsSearchMeaning" && find . -type f | LC_ALL=C sort | xargs shasum -a 256)
} >"$OUT/environment.txt"

failed=0
run() {
  local name="$1" phase="$2"
  echo "meaning-deadline-campaign.sh: $name ($(date +%H:%M:%S))"
  if TEST_RUNNER_EW_MEANING_CAMPAIGN="$phase" TEST_RUNNER_EW_MEANING_OUT="$RAW" \
    "$ROOT/scripts/xcode-test.sh" --configuration Debug --filter "$SUITE" \
    --log-dir "$OUT/runs/$name" >"$OUT/runs/$name.log" 2>&1; then
    echo "  passed"
  else
    echo "  FAILED (see $OUT/runs/$name.log)"
    failed=1
  fi
}

for n in $(seq 0 29); do run "cold-$n" "cold:$n"; done
run warm warm

AFTER="$(source_identity)"
echo "source after: $AFTER" >>"$OUT/environment.txt"
[ "$BEFORE" = "$AFTER" ] || die 1 "the source changed during the campaign ($BEFORE -> $AFTER)"
[ -s "$RAW" ] || die 1 "no samples were written to $RAW"
set +e
python3 - "$RAW" "$OUT/summary.json" <<'PY'
import json, math, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
def rank(values, p):
    ordered = sorted(values)
    return ordered[max(1, math.ceil(p / 100 * len(ordered))) - 1]
summary = {"method": "nearest-rank over every sample of the phase, whatever its outcome"}
for phase, expected in (("cold", 30), ("warm", 30)):
    picked = [r for r in rows if r["phase"] == phase]
    times = [r["milliseconds"] for r in picked]
    outcomes = {}
    for r in picked:
        outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
    summary[phase] = {
        "expected": expected, "samples": len(picked), "outcomes": outcomes,
        "p50": rank(times, 50) if times else None, "p95": rank(times, 95) if times else None,
        "p99": rank(times, 99) if times else None, "max": max(times) if times else None,
        "min": min(times) if times else None,
        "loadMilliseconds": sorted(r["loadMilliseconds"] for r in picked if r["loadMilliseconds"] is not None),
    }
json.dump(summary, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
print(json.dumps(summary, indent=2))
# Only a full set of completed passes is deadline evidence; other outcomes stay in raw.jsonl.
complete = all(
    summary[p]["samples"] == summary[p]["expected"]
    and summary[p]["outcomes"] == {"completed": summary[p]["expected"]}
    for p in ("cold", "warm")
)
sys.exit(0 if complete else 1)
PY
summary_status=$?
set -e
[ "$failed" -eq 0 ] && [ "$summary_status" -eq 0 ] || exit 1
