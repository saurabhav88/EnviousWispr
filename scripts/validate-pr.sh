#!/usr/bin/env bash
# validate-pr.sh — Single-command Phase 3 runner (PR #498).
#
# Walks the Phase 3 sequence in the canonical order (reordered 2026-06-20 per
# founder directive — see workflow-process.md RULE: codex-clean-gates-runtime-uat):
#   1. Logic tests
#   2. Codex code-diff review — iterate to a CLEAN pass (no app rebuild and no
#      Live UAT between rounds; validate fixes with the fast inline swift harness)
#   3. Smoke (Tuist/Xcode DEV build + signed copy + launch) + Live UAT — the
#      SINGLE rebuild, run once on the Codex-clean code
#   4. (Runtime-only Live UAT failure -> fix -> Codex clean again -> rebuild + re-UAT)
#   5. (Push handled by caller)
#
# This script is a SCAFFOLDER, not the review sequencer: for a Code-lane change it
# runs logic tests + the smoke build and writes `skipped:true` stubs for Live UAT
# and Codex that the caller overwrites. The caller drives Codex code-diff to clean
# BEFORE invoking the smoke + Live UAT portion, so the smoke build below is the
# single post-Codex rebuild. The numbered Phase 3.x echo sections are the
# scaffolder's internal step order, not the caller's review order.
#
# Writes evidence into `.validation/runs/<timestamp>-<shortsha>/`.
# Calls `check-validation.sh` at the end as the final assertion.
#
# Usage:
#   validate-pr.sh                  Run Phase 3 against current branch.
#   validate-pr.sh --self-test      Fixture-based self-test of orchestrator.
#
# See `.claude/rules/workflow-process.md §1 step 9` and §11 for lane definitions.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMA_VERSION=1

# --- Canonical lanes (workflow-process.md FACT: lane-classification) ---
# Exactly six, exact case. No `Local`, no `Mixed` (a multi-lane PR declares one
# primary lane plus `mixed_pr: true`). Defined here, above --self-test, so the
# self-test can EXERCISE the matcher rather than grep for its name.
# MUST stay in step with `check-validation.sh`'s per-lane `case` dispatch — any
# lane accepted here and absent there dies at `FAIL: unknown declared_lane`.
CANONICAL_LANES="Docs/dev-tooling Eval-harness CI/workflow Content Worker Code"

# Echoes the canonical lane a `**Lane:**` declaration line starts with, or
# returns 1. #1463: the old parser cut the line at the first `*` or `.`, so
# `**Lane:** Code (touches \`website/astro.config.mjs\` ...)` came out as
# `Code (touches \`website/astro` and failed downstream as an unknown lane.
# The lane set is CLOSED, so match against it instead of trimming open-ended
# prose (workflow-process.md RULE: parse-structured-input-dont-regex-and-iterate).
# Longest-first so `Docs/dev-tooling` is never shadowed by a shorter sibling; the
# trailing character class rejects a longer word that merely starts with a lane
# name (`Codebase` is not `Code`).

# The DECLARATION shapes, enumerated exhaustively across every plan on disk with
#   grep -rhoiE "^[^:]{0,40}lane[^:]{0,10}:" docs/feature-requests/*.md
# (no prefix assumed) rather than guessed one review round at a time:
#
#   270  **Lane:            39  - **Lane:           8  Lane:
#     3  - Lane:             2  - **Declared lane:  1  - Primary lane:
#
# The qualifier set is CLOSED — nothing, `Declared `, or `Primary `. It is
# deliberately NOT "any word before lane:", because the same sweep shows plenty
# of PROSE in that shape that must never be mistaken for the declaration:
# `**Validation lane:` (a different field entirely), `**Code lane:`,
# `- **Worker lane:`, `REFACTOR lane:`, `Lane detection:`, `Mixed-lane note:`,
# and `"declared_lane":` inside a JSON block. A permissive pattern would match
# one of those, find no canonical lane in it, and now HARD-FAIL the run — a
# worse failure than the bug being fixed.
#
# The old anchor was `^\*\*Lane:\*\*`, which silently missed 53 real
# declarations and fell back to the detected lane.
LANE_LINE_PATTERN='^[-*[:space:]]*\*{0,2}((declared|primary) )?lane\*{0,2}:'

match_canonical_lane() {
  local raw="$1" lane
  # Strip any leading bullet/bold, the optional `Primary `, the label and colon,
  # and any bold the author wrapped the value in.
  # ANCHORED at ^, never `.*[Ll]ane`. A greedy leading `.*` walks past the FIRST
  # label to the LAST one, so `Lane: Code (secondary lane: Docs/dev-tooling)`
  # returned `Docs/dev-tooling` — the parenthetical, not the declaration. sed has
  # no lazy quantifier, so the prefix is spelled out instead. Letter classes
  # rather than a case-insensitive flag, which is not portable across seds.
  #
  # `[*`[:space:]]*` after the colon consumes the WHOLE run of stars, backticks
  # and spaces, so `**Lane:** **Docs/dev-tooling.**` reaches the value. A lane
  # never begins with any of those, so the run cannot eat one.
  #
  # Trim with sed, NOT xargs: xargs PARSES quotes, and a real plan line
  # ("...NOT in this plan's first PR.") aborts it with "unterminated quote",
  # which read as an unparseable lane.
  raw=$(echo "$raw" | sed -E \
    's/^[-*[:space:]]*\*{0,2}(([Dd]eclared|[Pp]rimary) )?[Ll][Aa][Nn][Ee]\*{0,2}:[*`[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
  # Case-INSENSITIVE match, canonical-cased OUTPUT. A plan writing `code` names
  # exactly one lane and there is no ambiguity to protect against, but
  # `check-validation.sh` dispatches on the exact-case name — so rejecting the
  # declaration would fail a run over letter case, while passing `code` through
  # verbatim would die downstream at `unknown declared_lane`. Normalising here
  # accepts the human spelling and emits the one form the rest of the pipeline
  # understands. `issue-501`'s tracked plan declares lowercase `code`.
  local lower_raw lower_lane
  lower_raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  for lane in $CANONICAL_LANES; do
    lower_lane=$(printf '%s' "$lane" | tr '[:upper:]' '[:lower:]')
    case "$lower_raw" in
      "$lower_lane"|"$lower_lane"[^a-z0-9/-]*) echo "$lane"; return 0 ;;
    esac
  done
  return 1
}

# #4064: source completeness is decided before output filtering. Keep this callable by
# the offline self-test; normal execution records its result with record_step below.
check_broken_refs() {
  local caller="$1" report="$2" common hook_root top owner_common rc filter_rc status
  local raw="${2}.raw" diagnostics="${2}.stderr" retained="${2}.retained"
  if ! printf 'Status: UNAVAILABLE\nCalling checkout: %s\n' "$caller" > "$report"; then
    echo "Cannot write broken-refs report: $report" >&2
    return 2
  fi
  : > "$raw" && : > "$diagnostics" && : > "$retained" || return 2
  if ! common=$(git -C "$caller" rev-parse --path-format=absolute --git-common-dir 2>> "$diagnostics"); then
    printf 'Cannot identify the hook source checkout.\n' >> "$report" || return 2
    cat "$diagnostics" >> "$report" || return 2
    return 2
  fi
  case "$common" in
    */.git) hook_root="${common%/.git}" ;;
    *) printf 'Unsupported Git layout: %s\n' "$common" >> "$report"; return 2 ;;
  esac
  if ! top=$(git -C "$hook_root" rev-parse --show-toplevel 2>> "$diagnostics") \
     || ! owner_common=$(git -C "$hook_root" rev-parse --path-format=absolute --git-common-dir 2>> "$diagnostics") \
     || [ "$top" != "$hook_root" ] || [ "$owner_common" != "$common" ]; then
    printf 'Cannot verify the primary hook source checkout: %s\n' "$hook_root" >> "$report" || return 2
    cat "$diagnostics" >> "$report" || return 2
    return 2
  fi
  printf 'Hook source checkout: %s\n' "$hook_root" >> "$report" || return 2
  if [ ! -d "$hook_root/.claude/scripts" ] || [ ! -r "$hook_root/.claude/scripts" ] \
     || [ ! -x "$hook_root/.claude/scripts" ]; then
    printf 'Missing or unreadable directory: %s/.claude/scripts\n' "$hook_root" >> "$report" || return 2
    return 2
  fi
  if [ ! -f "$hook_root/.claude/settings.json" ] || [ ! -r "$hook_root/.claude/settings.json" ]; then
    printf 'Missing or unreadable file: %s/.claude/settings.json\n' "$hook_root" >> "$report" || return 2
    return 2
  fi
  if /usr/bin/grep -rn 'needs-uat\|\.needs-uat' \
      "$hook_root/.claude/scripts/" "$hook_root/.claude/settings.json" > "$raw" 2>> "$diagnostics"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -gt 1 ]; then
    printf 'Search incomplete (exit=%s). Partial observations are not a completed check.\n' "$rc" >> "$report" || return 2
    cat "$diagnostics" "$raw" >> "$report" || return 2
    return 2
  fi
  status=CLEAN
  rc=0
  if [ -s "$raw" ]; then
    # Preserve the PR #498 exclusion policy. These are candidate text matches,
    # including comments, not proof of a live obsolete marker consumer.
    if /usr/bin/grep -v 'validate-pr.sh\|check-validation.sh\|attest.sh' "$raw" > "$retained" 2>> "$diagnostics"; then
      filter_rc=0
    else
      filter_rc=$?
    fi
    if [ "$filter_rc" -gt 1 ]; then
      printf 'Exclusion filter failed (exit=%s).\n' "$filter_rc" >> "$report" || return 2
      cat "$diagnostics" "$raw" >> "$report" || return 2
      return 2
    fi
    if [ "$filter_rc" -eq 0 ]; then status=CANDIDATES; rc=1; fi
  fi
  {
    printf 'Status: %s\nCalling checkout: %s\nHook source checkout: %s\n' "$status" "$caller" "$hook_root" || return 2
    printf 'Search completed; existing three-name content exclusions apply.\n' || return 2
    if [ -s "$raw" ]; then
      printf '\nRaw matches before exclusions:\n' || return 2
      cat "$raw" || return 2
    fi
    if [ -s "$retained" ]; then
      printf '\nCandidates requiring review (comments may be historical):\n' || return 2
      cat "$retained" || return 2
    fi
  } > "$report" || return 2
  return "$rc"
}

# --- Self-test mode ---
if [ "${1:-}" = "--self-test" ]; then
  TMPDIR=$(mktemp -d -t validate-pr-self-test.XXXXXX)
  trap 'rm -rf "$TMPDIR"' EXIT

  pass=0
  fail=0

  # Test: lane-detection function exists (we just need the symbol; full
  # behavioral mock would require shelling git out and is out of scope here).
  if grep -q "^detect_lane_from_diff()" "$0"; then
    pass=$((pass + 1))
    echo "self-test PASS: detect_lane_from_diff function exists"
  else
    fail=$((fail + 1))
    echo "self-test FAIL: detect_lane_from_diff function missing"
  fi

  # Test: lane detection itself, on the real function (#3189). The function is defined after this
  # block, so it is lifted out of this file rather than reimplemented.
  eval "$(sed -n '/^detect_lane_from_diff() {/,/^}/p' "$0")"
  lane_case() { # name, expected lanes, changed files
    local got
    got=$(detect_lane_from_diff "$3")
    if [ "$got" = "$2" ]; then
      pass=$((pass + 1)); echo "self-test PASS: lanes for $1 = ${got:-<none>}"
    else
      fail=$((fail + 1)); echo "self-test FAIL: lanes for $1: expected '$2', got '$got'"
    fi
  }
  lane_case "scripts/lib" "Docs/dev-tooling" "scripts/lib/l10n-catalog-sync.sh"
  lane_case "scripts/ci" "Docs/dev-tooling" "scripts/ci/classify-changes.sh"
  lane_case "root script" "Docs/dev-tooling" "scripts/build-dev-app.sh"
  lane_case "root python script" "Docs/dev-tooling" "scripts/mutation-battery-test.py"
  lane_case "root python plus eval python" "Docs/dev-tooling,Eval-harness" "scripts/mutation-battery.py
scripts/eval/a.py"
  lane_case "root data file" "" "scripts/test-inventory-baseline.txt"
  lane_case "scripts/eval only" "Eval-harness" "scripts/eval/run_egone_gguf.py"
  lane_case "scripts/eval plus scripts/lib" "Docs/dev-tooling,Eval-harness" "scripts/eval/a.py
scripts/lib/b.sh"
  lane_case "no matching path" "" "README.md"
  eval "$(sed -n '/^fallback_lane_from_detected() {/,/^}/p' "$0")"
  fallback_case() { # name, expected, detected lanes
    local got
    got=$(fallback_lane_from_detected "$3")
    if [ "$got" = "$2" ]; then
      pass=$((pass + 1)); echo "self-test PASS: no-plan lane for $1 = ${got:-<none>}"
    else
      fail=$((fail + 1)); echo "self-test FAIL: no-plan lane for $1: expected '$2', got '$got'"
    fi
  }
  fallback_case "docs plus eval" "Eval-harness" "Docs/dev-tooling,Eval-harness"
  fallback_case "docs plus worker" "Worker" "Docs/dev-tooling,Worker"
  fallback_case "docs only" "Docs/dev-tooling" "Docs/dev-tooling"
  fallback_case "code plus docs" "Code" "Code,Docs/dev-tooling"
  fallback_case "CI plus code" "Code" "CI/workflow,Code"
  fallback_case "content plus eval" "Eval-harness" "Content,Eval-harness"
  fallback_case "worker plus eval" "Worker" "Eval-harness,Worker"
  fallback_case "none" "" ""
  eval "$(sed -n '/^detected_json_from_lanes() {/,/^}/p' "$0")"
  detected_json_case() { # name, expected compact JSON, detected lanes
    local got
    got=$(detected_json_from_lanes "$3")
    if [ "$got" = "$2" ]; then
      pass=$((pass + 1)); echo "self-test PASS: run.json detected_lanes for $1 = $got"
    else
      fail=$((fail + 1)); echo "self-test FAIL: run.json detected_lanes for $1: expected '$2', got '$got'"
    fi
  }
  detected_json_case "none" '[]' ""
  detected_json_case "one lane" '["Code"]' "Code"
  detected_json_case "two lanes" '["CI/workflow","Code"]' "CI/workflow,Code"

  # Test: run.json schema produced by the orchestrator validates against
  # check-validation.sh's expected fields.
  fixture_run="$TMPDIR/fixture-run"
  mkdir -p "$fixture_run"
  HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "fixturesha000000000000000000000000000000")
  cat > "$fixture_run/run.json" <<JSON
{"schema_version":$SCHEMA_VERSION,"head_sha":"$HEAD_SHA","branch":"fixture","declared_lane":"Docs/dev-tooling","detected_lanes":["Docs/dev-tooling"],"changed_files":[],"is_mixed_pr":false,"started_at":"2026-04-29T00:00:00Z","completed_at":"2026-04-29T00:00:01Z","obligations_satisfied":["codex-prose","broken-refs"],"obligations_skipped":[],"skip_notes":[]}
JSON
  echo "x" > "$fixture_run/codex-prose.txt"
  echo "x" > "$fixture_run/broken-refs-grep.txt"
  if "$PROJECT_ROOT/scripts/check-validation.sh" "$fixture_run" >/dev/null 2>&1; then
    pass=$((pass + 1))
    echo "self-test PASS: orchestrator-shaped run.json passes check-validation.sh"
  else
    fail=$((fail + 1))
    echo "self-test FAIL: orchestrator-shaped run.json failed check-validation.sh"
  fi

  # Test: the lane matcher, EXERCISED (#1463 regression lock). Each case is
  # `declaration line -> expected`, where `-` means "must not match". The first
  # case is the exact line from the legacy May plan that produced
  # `Code (touches \`website/astro` and failed the run with an unknown lane.
  while IFS='|' read -r line expected; do
    [ -z "$line" ] && continue
    if got=$(match_canonical_lane "$line"); then :; else got="-"; fi
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "self-test FAIL: lane matcher on '$line' gave '$got', expected '$expected'"
    fi
  done <<'CASES'
**Lane:** Code (touches `website/astro.config.mjs` and more)|Code
**Lane:** Code|Code
**Lane:** Content|Content
**Lane:** CI/workflow|CI/workflow
**Lane:** Eval-harness|Eval-harness
**Lane:** Worker|Worker
**Lane:** Docs/dev-tooling|Docs/dev-tooling
**Lane:** **Docs/dev-tooling.** Narrative prose after.|Docs/dev-tooling
**Lane:** Local|-
**Lane:** Mixed|-
**Lane:** Codebase|-
- **Lane:** Code (touches `Sources/EnviousWisprAppKit/App/`).|Code
- Lane: Content|Content
Lane: Worker|Worker
- Primary lane: Eval-harness|Eval-harness
- **Lane:** `Code`|Code
- Primary lane: **Eval-harness** (data under `scripts/eval/`), NOT in this plan's first PR.|Eval-harness
**Lane:** Mixed — Code (DEBUG seams) + Docs/dev-tooling (harness).|-
- **Declared lane:** Code|Code
- Declared lane: Docs/dev-tooling|Docs/dev-tooling
Lane: Code (secondary lane: Docs/dev-tooling)|Code
**Lane:** Content — the eval-harness lane: not used here.|Content
- **Lane:** Worker (per-lane: obligations in §11)|Worker
- **Declared lane:** code (mixed_pr: false)|Code
**Lane:** DOCS/DEV-TOOLING|Docs/dev-tooling
**Lane:** ci/workflow|CI/workflow
**Lane:** codebase|-
CASES
  echo "self-test: lane matcher exercised over 27 cases"

  # The declaration line must also be FOUND. A matcher that parses every shape
  # is useless behind a grep anchored to one of them (#1861 cloud review P1).
  while IFS='|' read -r line expected; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE "$LANE_LINE_PATTERN"; then got="found"; else got="-"; fi
    if [ "$got" = "$expected" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      echo "self-test FAIL: lane line pattern on '$line' gave '$got', expected '$expected'"
    fi
  done <<'FINDCASES'
**Lane:** Code|found
- **Lane:** Code|found
Lane: Code|found
- Lane: Code|found
- Primary lane: Eval-harness|found
- **Declared lane:** Code|found
Detect the lane from the PR's actual change set|-
**Validation lane:** Y|-
**Code lane:** obligations below|-
- **Worker lane:** routine prompt|-
REFACTOR lane: module moves|-
Lane detection:|-
Mixed-lane note:|-
  "declared_lane": "Code",|-
FINDCASES
  echo "self-test: lane line pattern exercised over 14 cases"

  # #4064 harness-contract tests: real Git ownership, real grep and the actual
  # producer/record_step/verifier chain, with no app or installed-hook changes.
  probe_base="$TMPDIR/hook probe"
  mkdir -p "$probe_base"
  probe_base=$(cd "$probe_base" && pwd -P)
  probe_root="$probe_base/primary"
  probe_linked="$probe_base/linked"
  probe_report="$probe_base/report.txt"
  probe_git() {
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git \
      -c core.hooksPath=/dev/null -c commit.gpgsign=false \
      -c user.name=Fixture -c user.email=fixture@example.invalid "$@"
  }
  probe_git init -q -b main "$probe_root"
  probe_git -C "$probe_root" commit --allow-empty -qm fixture
  probe_git -C "$probe_root" worktree add --detach -q "$probe_linked" HEAD
  mkdir -p "$probe_root/.claude/scripts" "$probe_linked/.claude/scripts"
  printf '{}\n' > "$probe_root/.claude/settings.json"
  printf 'ordinary hook\n' > "$probe_root/.claude/scripts/ordinary.sh"
  printf 'needs-uat copied worktree decoy\n' > "$probe_linked/.claude/scripts/decoy.sh"
  printf '{}\n' > "$probe_linked/.claude/settings.json"
  probe_case() {
    local label="$1" caller="$2" expected="$3" needle="$4" got
    if check_broken_refs "$caller" "$probe_report" 2> "$probe_base/call.stderr"; then got=0; else got=$?; fi
    if [ "$got" -eq "$expected" ] && /usr/bin/grep -qF -- "$needle" "$probe_report"; then
      pass=$((pass + 1)); echo "self-test PASS: hook sources $label"
    else
      fail=$((fail + 1)); echo "self-test FAIL: hook sources $label (expected $expected, got $got)"
      cat "$probe_report" "$probe_base/call.stderr"
    fi
  }
  probe_case 'known-present clean inputs' "$probe_root" 0 'Status: CLEAN'
  probe_case 'linked checkout ignores its copied hooks' "$probe_linked" 0 "Hook source checkout: $probe_root"
  printf 'needs-uat live fixture marker\n' > "$probe_root/.claude/scripts/ordinary.sh"
  probe_case 'known-present live candidate' "$probe_root" 1 'Status: CANDIDATES'
  probe_case 'linked checkout sees the primary candidate' "$probe_linked" 1 "$probe_root/.claude/scripts/ordinary.sh:1:"
  printf '# historical .needs-uat mention\n' > "$probe_root/.claude/scripts/ordinary.sh"
  probe_case 'historical text stays a review candidate' "$probe_root" 1 'comments may be historical'
  printf 'needs-uat mention of validate-pr.sh\n' > "$probe_root/.claude/scripts/ordinary.sh"
  probe_case 'existing exclusions retain raw evidence' "$probe_root" 0 'Raw matches before exclusions:'
  printf 'ordinary hook\n' > "$probe_root/.claude/scripts/ordinary.sh"
  probe_case 'clean report before sequential retry' "$probe_root" 0 'Status: CLEAN'
  mv "$probe_root/.claude/settings.json" "$probe_root/settings.saved"
  probe_case 'missing settings replaces prior clean report' "$probe_root" 2 'Status: UNAVAILABLE'
  printf 'needs-uat live fixture marker\n' > "$probe_root/.claude/scripts/ordinary.sh"
  probe_case 'missing input overrides matching member' "$probe_root" 2 'Missing or unreadable file:'
  probe_case 'linked copies cannot hide a missing primary input' "$probe_linked" 2 'Missing or unreadable file:'
  mkdir "$probe_root/.claude/settings.json"
  probe_case 'settings wrong type' "$probe_root" 2 'Missing or unreadable file:'
  rmdir "$probe_root/.claude/settings.json"
  mv "$probe_root/settings.saved" "$probe_root/.claude/settings.json"
  mv "$probe_root/.claude/scripts" "$probe_root/scripts.saved"
  probe_case 'missing hook directory' "$probe_root" 2 'Missing or unreadable directory:'
  mv "$probe_root/scripts.saved" "$probe_root/.claude/scripts"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$probe_root/.claude/settings.json"
    probe_case 'unreadable settings' "$probe_root" 2 'Missing or unreadable file:'
    chmod 600 "$probe_root/.claude/settings.json"
    printf 'unreadable hook\n' > "$probe_root/.claude/scripts/unreadable.sh"
    chmod 000 "$probe_root/.claude/scripts/unreadable.sh"
    probe_case 'actual partial read failure' "$probe_root" 2 'Search incomplete'
    if /usr/bin/grep -qF 'ordinary.sh:1:needs-uat' "$probe_report" \
       && [ -s "${probe_report}.stderr" ]; then
      pass=$((pass + 1)); echo 'self-test PASS: partial observations and read diagnostics survive'
    else
      fail=$((fail + 1)); echo 'self-test FAIL: partial observations or diagnostics lost'
    fi
    chmod 600 "$probe_root/.claude/scripts/unreadable.sh"
    chmod 000 "$probe_root/.claude/scripts"
    probe_case 'unreadable hook traversal' "$probe_root" 2 'Missing or unreadable directory:'
    chmod 700 "$probe_root/.claude/scripts"
  else
    echo 'self-test SKIP: permission fixtures need a non-root account; no permission result claimed'
  fi
  probe_case 'not a Git checkout' "$probe_base" 2 'Cannot identify the hook source checkout'
  probe_git init -q --separate-git-dir "$probe_base/separate-metadata" "$probe_base/separate"
  probe_case 'unsupported separate Git layout' "$probe_base/separate" 2 'Unsupported Git layout:'
  mkdir "$probe_base/report-directory"
  if check_broken_refs "$probe_root" "$probe_base/report-directory" 2> "$probe_base/write-error.txt"; then
    fail=$((fail + 1)); echo 'self-test FAIL: failed report write returned clean'
  else
    pass=$((pass + 1)); echo 'self-test PASS: failed report write is non-success'
  fi

  # Lift the real recorder, call site and writer, not a fake result mapper. The
  # final verifier sees fixture-only prose evidence, never a real review receipt.
  eval "$(sed -n '/^record_step() {/,/^}/p' "$0")"
  probe_call=$(sed -n '/^    # #4064 source probe:/,/^    # Per Codex round 3 P2:/p' "$0")
  probe_writer=$(sed -n '/^# --- Write run.json ---/,/^# --- Final assertion ---/p' "$0")
  [ -n "$probe_call" ] && [ -n "$probe_writer" ]
  probe_verifier="$PROJECT_ROOT/scripts/check-validation.sh"
  probe_head=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
  probe_integration() {
    local expected="$1" expected_obligation="$2" got
    local PROJECT_ROOT="$probe_root" RUN_DIR="$probe_base/integration-$expected"
    local SATISFIED SKIPPED SKIP_NOTES HEAD_SHA BRANCH DECLARED DETECTED CHANGED IS_MIXED STARTED_AT
    local COMPLETED_AT DETECTED_JSON CHANGED_JSON SATISFIED_JSON SKIPPED_JSON SKIP_NOTES_JSON refs_rc
    mkdir -p "$RUN_DIR"
    printf 'FIXTURE ONLY: artificial review evidence for source-probe contract checks.\n' > "$RUN_DIR/codex-prose.txt"
    SATISFIED=(codex-prose); SKIPPED=(); SKIP_NOTES=()
    eval "$probe_call" || return 2
    HEAD_SHA="$probe_head"; BRANCH=fixture; DECLARED=Docs/dev-tooling
    DETECTED=Docs/dev-tooling; CHANGED=''; IS_MIXED=false
    STARTED_AT=2026-10-29T00:00:00Z
    eval "$probe_writer" || return 2
    if "$probe_verifier" "$RUN_DIR" > "$RUN_DIR/verifier.txt" 2>&1; then got=0; else got=$?; fi
    [ "$got" -eq "$expected" ] \
      && jq -e --argjson wanted "$expected_obligation" \
        '((.obligations_satisfied | index("broken-refs")) != null) == $wanted' "$RUN_DIR/run.json" >/dev/null
  }
  printf 'ordinary hook\n' > "$probe_root/.claude/scripts/ordinary.sh"
  if probe_integration 0 true; then
    pass=$((pass + 1)); echo 'self-test PASS: real recorder and verifier accept complete clean search'
  else
    fail=$((fail + 1)); echo 'self-test FAIL: real clean-search integration'
  fi
  mv "$probe_root/.claude/settings.json" "$probe_root/settings.saved"
  if probe_integration 2 false; then
    pass=$((pass + 1)); echo 'self-test PASS: real recorder and verifier reject unavailable source'
  else
    fail=$((fail + 1)); echo 'self-test FAIL: unavailable source passed recorder/verifier'
  fi
  mv "$probe_root/settings.saved" "$probe_root/.claude/settings.json"
  printf 'needs-uat live fixture marker\n' > "$probe_root/.claude/scripts/ordinary.sh"
  if probe_integration 2 false \
     && /usr/bin/grep -qF 'Status: CANDIDATES' "$probe_base/integration-2/broken-refs-grep.txt"; then
    pass=$((pass + 1)); echo 'self-test PASS: real recorder and verifier reject undisposed candidates'
  else
    fail=$((fail + 1)); echo 'self-test FAIL: candidate result passed recorder/verifier'
  fi

  echo "self-test results: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

# --- Lane detection ---
detect_lane_from_diff() {
  local changed_files="$1"
  local lanes=""

  if echo "$changed_files" | grep -qE '^(Sources/|Tests/|Package\.swift|Package\.resolved|Project\.swift|Tuist\.swift|Workspace\.swift|Tuist/)'; then
    lanes="$lanes Code"
  fi
  if echo "$changed_files" | grep -qE '^(website/|assets/)'; then
    lanes="$lanes Content"
  fi
  # `.github/actions/` joined this pattern in #1994, when main-post-merge.yml's
  # shared Xcode setup moved into a composite action (#3729 retired that
  # workflow; pr-check.yml and cache-warm.yml use the action). Measured before the fix:
  # `.github/actions/xcode-ci-setup/action.yml` matched NO lane at all — not
  # CI/workflow, not Docs/dev-tooling — so a change to it carried no Phase 3
  # obligations whatsoever. Third instance of one class in this change, after
  # `scripts/ci/classify-changes.sh` (build decision) and
  # `.github/workflows/ci-drift-check.yml` (drift scan; since #3729 the
  # fast-checks member scripts/ci/check-ci-drift.py): each looked only at
  # `.github/workflows/`, so moving CI logic one directory sideways escaped it.
  #
  # `scripts/ci/` and `scripts/lib/` were unlaned until #3189: the old scripts/ pattern needed a
  # four-character directory name. Any scripts/ subdirectory except eval/ is Docs/dev-tooling below.
  if echo "$changed_files" | grep -qE '^\.github/(workflows/|actions/)|dependabot'; then
    lanes="$lanes CI/workflow"
  fi
  if echo "$changed_files" | grep -qE '^scripts/eval/'; then
    lanes="$lanes Eval-harness"
  fi
  if echo "$changed_files" | grep -qE '^workers/'; then
    lanes="$lanes Worker"
  fi
  # Root `scripts/*.py` joined the root `scripts/*.sh` pattern in #3585: `scripts/mutation-battery-test.py`
  # was the only changed file of a PR and matched no lane, so Phase 3 chose none.
  if echo "$changed_files" | grep -qE '^(docs/|\.claude/|CLAUDE\.md)' \
     || echo "$changed_files" | grep -E '^scripts/[^/]+/' | grep -qvE '^scripts/eval/' \
     || echo "$changed_files" | grep -qE '^scripts/[^/]+\.(sh|py)$'; then
    lanes="$lanes Docs/dev-tooling"
  fi

  echo "$lanes" | xargs -n1 | sort -u | tr '\n' ',' | sed 's/,$//'
}

# The detected lanes as a JSON array for run.json. An empty detection is `[]`; the old inline
# `tr | jq -R | jq -s` printed `[""]` for it, which looked like one lane with an empty name (#3585).
detected_json_from_lanes() {
  printf '%s\n' "$1" | tr ',' '\n' | jq -R . | jq -sc 'map(select(. != ""))'
}

# The lane used when the plan declares none. The verifier checks only the declared lane's evidence,
# so the fallback must be the lane with the most to prove, never the first name alphabetically
# (that let a docs or scripts/lib change hide an eval or worker change, and CI/workflow hide Code;
# #3189). Order: heaviest obligations first. A mixed PR still gets a warning naming the choice.
fallback_lane_from_detected() {
  local detected="$1" lane
  for lane in Code Worker Eval-harness CI/workflow Content Docs/dev-tooling; do
    if echo "$detected" | tr ',' '\n' | grep -qx "$lane"; then echo "$lane"; return 0; fi
  done
  echo "$detected" | cut -d, -f1
}

# --- Setup run directory ---
HEAD_SHA=$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")
SHORT_SHA=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
RUN_DIR="$PROJECT_ROOT/.validation/runs/$TIMESTAMP-$SHORT_SHA"
mkdir -p "$RUN_DIR"
STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "==> validate-pr.sh: Phase 3 run dir: $RUN_DIR"

# --- Detect lane from git diff ---
# Per Codex round 5: `git diff --name-only origin/main` includes files main
# advanced through after branch cut, contaminating lane detection. Use the
# merge-base so the diff is only the PR's actual change set. If origin/main
# is unavailable (fresh clone, no fetch), fall back to plain origin/main diff.
MERGE_BASE=$(git -C "$PROJECT_ROOT" merge-base origin/main HEAD 2>/dev/null || echo "")
if [ -n "$MERGE_BASE" ]; then
  CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null || echo "")
else
  CHANGED=$(git -C "$PROJECT_ROOT" diff --name-only origin/main 2>/dev/null || echo "")
fi
DETECTED=$(detect_lane_from_diff "$CHANGED")
echo "==> Detected lanes: ${DETECTED:-<none>}"
if [ -z "$DETECTED" ] && [ -n "$CHANGED" ]; then
  # Files changed but none matched a lane: the plan's declared lane is the only lane left, and nothing
  # cross-checks it. Name the files so the router gap is visible (#3585).
  echo "WARN: no lane matched these changed files; only the plan's declared lane is checked:" >&2
  printf '%s\n' "$CHANGED" | sed 's/^/      /' >&2
fi

# --- Read declared lane from THIS PR's plan file (Phase 1 Preface) ---
# #1463, two compounding bugs, both fixed here.
#
# 1. WRONG PLAN. This used to take the newest `issue-*.md` by mtime. We stopped
#    committing plan files around May 2026, so in a fresh feature worktree the
#    only plans on disk are the ~25 legacy tracked ones and `ls -t` confidently
#    returned a plan from MAY — then read ITS lane. Now the plan must belong to
#    this branch: the issue number is taken from the branch name and matched
#    against `issue-<N>-*.md`. No match means no declaration, never someone
#    else's. `EW_PLAN_FILE` overrides for a branch whose name carries no number.
#
# 2. MANGLED VALUE. The old parser stripped `**Lane:**` then cut at the first
#    `*` or `.`, so `**Lane:** Code (touches \`website/astro.config.mjs\` ...)`
#    yielded `Code (touches \`website/astro` and failed downstream as an unknown
#    lane. The six lanes are a CLOSED set, so match against it instead of
#    trimming open-ended prose (workflow-process.md
#    RULE: parse-structured-input-dont-regex-and-iterate). `match_canonical_lane`
#    and `CANONICAL_LANES` are defined at the top of this file so `--self-test`
#    can exercise them; the 11-case regression lock lives there.

PLAN_FILE="${EW_PLAN_FILE:-}"
if [ -n "$PLAN_FILE" ] && [ ! -f "$PLAN_FILE" ]; then
  # An EXPLICIT override that does not resolve is an error, never a fallback.
  # Silently detecting the lane instead would make a typo, a stale path, or a
  # path relative to the wrong worktree look exactly like "this branch has no
  # plan" — the caller asked for a specific document and must be told it is not
  # there.
  echo "FAIL: EW_PLAN_FILE does not exist: $PLAN_FILE" >&2
  echo "      (cwd: $(pwd))" >&2
  exit 2
fi
if [ -z "$PLAN_FILE" ]; then
  BRANCH_NAME=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  # An EXPLICIT `issue-<N>` wins over position. Taking the first run of digits
  # picks the version out of `exp/v2-issue-1570` and then silently reads no plan
  # at all, which is the failure mode this whole change removes. Only when the
  # branch names no issue explicitly does it fall back to the first number, which
  # covers the house convention `fix/1463-slug`.
  BRANCH_ISSUE=$(echo "$BRANCH_NAME" | grep -oE 'issue[-_/]?[0-9]+' | head -1 |
    grep -oE '[0-9]+' || echo "")
  if [ -z "$BRANCH_ISSUE" ]; then
    BRANCH_ISSUE=$(echo "$BRANCH_NAME" | grep -oE '[0-9]+' | head -1 || echo "")
  fi
  if [ -n "$BRANCH_ISSUE" ]; then
    # Deliberately NOT `ls -t … | head -1`. A git checkout gives tracked files
    # identical mtimes, so mtime carries no revision ordering and picking the
    # "newest" would be an arbitrary choice between real alternatives — the same
    # class of silent wrong-plan bug this whole change exists to remove. Issue
    # 498 already has two plans on disk.
    #
    # One match is used. Zero falls back to the detected lane with a warning.
    # More than one is AMBIGUOUS and refuses to guess.
    # The trailing `-` is load-bearing: it stops issue 498 matching issue 4980.
    PLAN_MATCHES=()
    while IFS= read -r match; do
      [ -n "$match" ] && PLAN_MATCHES+=("$match")
    done < <(find "$PROJECT_ROOT/docs/feature-requests" -maxdepth 1 \
      -name "issue-${BRANCH_ISSUE}-*.md" 2>/dev/null | sort || true)

    if [ "${#PLAN_MATCHES[@]}" -gt 1 ]; then
      echo "FAIL: issue ${BRANCH_ISSUE} has ${#PLAN_MATCHES[@]} plans; refusing to guess which one declares this PR's lane." >&2
      for match in "${PLAN_MATCHES[@]}"; do echo "      $match" >&2; done
      echo "      Set EW_PLAN_FILE=<path> to name the one this PR implements." >&2
      exit 2
    fi
    [ "${#PLAN_MATCHES[@]}" -eq 1 ] && PLAN_FILE="${PLAN_MATCHES[0]}"
  fi
fi

DECLARED=""
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  echo "==> Plan: $PLAN_FILE"
  # Read EVERY matching line, then decide once — never first-wins. Taking the
  # first line that happens to parse means a plan quoting a valid declaration
  # above its real preface silently wins with the quotation. Taking the first
  # line unconditionally means a quotation that does NOT parse hard-fails a plan
  # whose real declaration is fine two lines down. Neither is safe to guess at,
  # so this collects the DISTINCT canonical lanes the file declares:
  #
  #   exactly one  -> use it (repeats of the same lane are not a conflict)
  #   more than one -> AMBIGUOUS, refuse, same rule as two plans for one issue
  #   none, but a declaration line exists -> the declaration is invalid
  FIRST_LANE_LINE=""
  LANE_HITS=()
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -n "$FIRST_LANE_LINE" ] || FIRST_LANE_LINE="$candidate"
    if hit=$(match_canonical_lane "$candidate"); then LANE_HITS+=("$hit"); fi
  done < <(grep -iE "$LANE_LINE_PATTERN" "$PLAN_FILE" 2>/dev/null || true)

  DISTINCT_LANES=()
  while IFS= read -r lane; do
    [ -n "$lane" ] && DISTINCT_LANES+=("$lane")
  done < <(if [ "${#LANE_HITS[@]}" -gt 0 ]; then printf '%s\n' "${LANE_HITS[@]}" | sort -u; fi)

  if [ "${#DISTINCT_LANES[@]}" -gt 1 ]; then
    echo "FAIL: plan declares ${#DISTINCT_LANES[@]} different lanes; refusing to guess which is the PR's." >&2
    echo "      $PLAN_FILE" >&2
    for lane in "${DISTINCT_LANES[@]}"; do echo "      - $lane" >&2; done
    echo "      Keep ONE lane declaration. If the plan quotes the preface format" >&2
    echo "      as an example, reword the quotation so it is not a bare" >&2
    echo "      'Lane: <name>' line." >&2
    exit 2
  fi
  [ "${#DISTINCT_LANES[@]}" -eq 1 ] && DECLARED="${DISTINCT_LANES[0]}"

  if [ -n "$FIRST_LANE_LINE" ] && [ -z "$DECLARED" ]; then
    echo "FAIL: plan declares a lane that is not one of: $CANONICAL_LANES" >&2
    echo "      $PLAN_FILE" >&2
    echo "      $FIRST_LANE_LINE" >&2
    echo "      The lane token must come FIRST after the label. Trailing prose," >&2
    echo "      parens, backticks and bold are fine. 'Mixed' is not a lane —" >&2
    echo "      declare one primary lane, then 'mixed_pr: true' on its own line." >&2
    exit 2
  fi
else
  echo "==> Plan: <none for this branch>"
fi
if [ -z "$DECLARED" ]; then
  echo "WARN: no plan lane declared for this branch; using detected lane"
  DECLARED=$(fallback_lane_from_detected "$DETECTED")
  LANE_FELL_BACK=true
fi
echo "==> Declared lane: $DECLARED"

# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` printed a second 0; `|| true` keeps one.
DETECTED_COUNT=$(echo "$DETECTED" | tr ',' '\n' | grep -c . || true)
IS_MIXED=false
if [ "$DETECTED_COUNT" -gt 1 ]; then
  IS_MIXED=true
  if [ "${LANE_FELL_BACK:-false}" = true ]; then
    echo "WARN: mixed lanes ($DETECTED) and no plan lane: only $DECLARED evidence is checked; declare the lane in the plan"
  fi
fi

# --- Phase 3 walk (lane-specific obligations live in workflow-process.md §11) ---
# Per Codex code-diff review: each step records its real exit status.
# Obligations are added to `obligations_satisfied` ONLY when the step exits 0.
# Failed steps go to `obligations_skipped` with a `skip-note.txt` entry so
# the run dir is honest about what actually passed.
SATISFIED=()
SKIPPED=()
SKIP_NOTES=()

record_step() {
  local name="$1"
  local rc="$2"
  local note="$3"
  if [ "$rc" -eq 0 ]; then
    SATISFIED+=("$name")
  else
    SKIPPED+=("$name")
    SKIP_NOTES+=("$note")
    # Append to skip-note.txt for visibility
    {
      echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $name: $note (exit=$rc)"
    } >> "$RUN_DIR/skip-note.txt"
  fi
}

echo "==> Phase 3.1: Logic tests"
if [ "$DECLARED" = "Code" ]; then
  if [ -x "$PROJECT_ROOT/scripts/xcode-test.sh" ]; then
    if "$PROJECT_ROOT/scripts/xcode-test.sh" > "$RUN_DIR/tests.log" 2>&1; then
      record_step "tests" 0 "xcode-test passed"
    else
      record_step "tests" 1 "xcode-test failed (see tests.log)"
    fi
  else
    record_step "tests" 1 "xcode-test.sh not executable"
  fi
elif [ "$DECLARED" = "Docs/dev-tooling" ]; then
  echo "ShellCheck + self-test for Docs/dev-tooling lane" > "$RUN_DIR/shellcheck.txt"
  if shellcheck "$PROJECT_ROOT"/scripts/validate-pr.sh "$PROJECT_ROOT"/scripts/check-validation.sh "$PROJECT_ROOT"/scripts/attest.sh >> "$RUN_DIR/shellcheck.txt" 2>&1; then
    record_step "shellcheck" 0 "shellcheck clean"
  else
    record_step "shellcheck" 1 "shellcheck reported issues (see shellcheck.txt)"
  fi
  ST_RC=0
  "$PROJECT_ROOT/scripts/check-validation.sh" --self-test > "$RUN_DIR/self-test.txt" 2>&1 || ST_RC=$?
  if [ "$ST_RC" -eq 0 ]; then
    VR_RC=0
    "$PROJECT_ROOT/scripts/validate-pr.sh" --self-test >> "$RUN_DIR/self-test.txt" 2>&1 || VR_RC=$?
    if [ "$VR_RC" -eq 0 ]; then
      record_step "self-test" 0 "both validators passed --self-test"
    else
      record_step "self-test" 1 "validate-pr.sh --self-test failed"
    fi
  else
    record_step "self-test" 1 "check-validation.sh --self-test failed"
  fi
fi

echo "==> Phase 3.2: Smoke (Tuist/Xcode DEV build + signed copy + launch) — the single rebuild, expected AFTER Codex code-diff is clean"
if [ "$DECLARED" = "Code" ]; then
  # #913 PR4: smoke runs the canonical Xcode-engine dev builder
  # scripts/build-dev-app.sh (Tuist generate → xcodebuild the EnviousWispr-Dev
  # scheme in the Dev config → self-signed → copy to build/EnviousWispr Local.app
  # → launch). It exits non-zero on any failure, which we propagate. Replaces the
  # retired SwiftPM dev bundler (release build + hand-rolled bundle).
  DEV_BUILD_SCRIPT="$PROJECT_ROOT/scripts/build-dev-app.sh"
  DEV_APP="$PROJECT_ROOT/build/EnviousWispr Local.app"
  if [ -x "$DEV_BUILD_SCRIPT" ]; then
    if "$DEV_BUILD_SCRIPT" > "$RUN_DIR/smoke.log" 2>&1; then
      RUNNING_VER=$(plutil -extract CFBundleVersion raw "$DEV_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
      jq -n --arg sha "$HEAD_SHA" --arg ver "$RUNNING_VER" --arg bundle "$DEV_APP" \
        '{head_sha:$sha, build_version:$ver, bundle_path:$bundle, smoke_step:"tuist_dev_build_signed_copy_launch", note:"Tuist/Xcode DEV build produced signed self-signed .dev bundle and launched it"}' \
        > "$RUN_DIR/smoke.json"
      record_step "smoke" 0 "Tuist/Xcode DEV build + launch succeeded ($RUNNING_VER)"
    else
      record_step "smoke" 1 "scripts/build-dev-app.sh failed (see smoke.log) — Tuist build, signing, copy, OR launch broken"
    fi
  else
    record_step "smoke" 1 "scripts/build-dev-app.sh not executable — cannot run Code-lane smoke"
  fi
fi

echo "==> Phase 3.3: Live UAT (lane-specific) — runs on the post-Codex-clean smoke build above"
case "$DECLARED" in
  Code)
    # Stage 1 stub: write a STRUCTURED JSON skip record. Real Code-lane
    # Live UAT runs from a wispr-eyes recipe declared in the plan's
    # §11.1 Live UAT spec; this stub does NOT execute one. Record the
    # skip honestly so check-validation.sh can read valid JSON without
    # crashing under set -e.
    jq -n --arg head "$HEAD_SHA" \
      '{
        recipe: "stub",
        sentence: null,
        expected_token: null,
        observed_transcript: null,
        exit_code: null,
        app_path: null,
        head_sha: $head,
        skipped: true,
        skip_reason: "Stage 1 stub — real Live UAT runs from plan-driven wispr-eyes recipe; caller must invoke separately and overwrite this file"
      }' > "$RUN_DIR/live-uat.json"
    record_step "live-uat" 1 "Stage 1 stub — caller must run wispr-eyes recipe and overwrite live-uat.json"
    ;;
  "Docs/dev-tooling")
    echo "Live UAT N/A for Docs/dev-tooling lane (per workflow-process.md §11)" > "$RUN_DIR/live-uat-na.txt"
    # Per Codex round 2 P2: scope the broken-refs grep to production hook
    # surfaces only (.claude/scripts/, .claude/settings.json) and exclude
    # the PR #498 framework scripts. Framework documentation can mention
    # the deleted concept freely; real leftover refs in production fail.
    # #4064 source probe: only a completed clean search satisfies this obligation.
    if check_broken_refs "$PROJECT_ROOT" "$RUN_DIR/broken-refs-grep.txt"; then
      record_step "broken-refs" 0 "hook source search completed cleanly under existing exclusions"
    else
      refs_rc=$?
      record_step "broken-refs" "$refs_rc" "hook source check needs review (exit=$refs_rc; 1=candidates, 2=unavailable); see broken-refs-grep.txt"
    fi
    # Per Codex round 3 P2: writing a stub `codex-prose.txt` and immediately
    # marking codex-prose as satisfied lets a Docs/dev-tooling PR pass
    # validation without the actual prose review running. Record codex-prose
    # as SKIPPED until the caller overwrites the file with real review output.
    # If the caller already wrote real codex review output (file exists with
    # >50 bytes and doesn't start with the STUB marker), preserve it and
    # mark the obligation satisfied.
    if [ -s "$RUN_DIR/codex-prose.txt" ] \
       && ! head -1 "$RUN_DIR/codex-prose.txt" | grep -q "^\[STUB" \
       && [ "$(wc -c < "$RUN_DIR/codex-prose.txt")" -gt 50 ]; then
      record_step "codex-prose" 0 "real codex review output already present in run dir (preserved by validate-pr.sh)"
    else
      cat > "$RUN_DIR/codex-prose.txt" <<EOF
[STUB — caller must overwrite]
Run: ~/.claude/bin/codex-run $RUN_DIR/codex-prose.txt review --base origin/main
(usage-limit fallback: see ~/.claude/knowledge/ai/codex-cli.md — never a bare launcher, never a > redirect)
Then re-run scripts/validate-pr.sh OR call scripts/attest.sh codex-prose "what I observed"
EOF
      record_step "codex-prose" 1 "Stage 1 stub — caller must run 'codex review' and overwrite codex-prose.txt + attest"
    fi
    ;;
  Content|"CI/workflow"|Eval-harness|Worker)
    # Code lane is handled in its own branch above (synthetic dictation
    # via wispr-eyes recipe). Lanes other than Code and Docs/dev-tooling
    # are not yet auto-orchestrated by
    # validate-pr.sh's Phase 3.3 stub. Per Codex round 3 P2: announce this
    # honestly rather than silently producing a half-broken run dir. The
    # caller must invoke the lane-specific Live UAT (e.g., wispr-eyes for
    # Code; Astro preview for Content; deploy + endpoint smoke for Worker)
    # and write the artifacts directly to the run dir, then attest each.
    record_step "${DECLARED}-orchestration" 1 "Stage 1 stub — validate-pr.sh does not yet auto-orchestrate non-Docs/dev-tooling lane Live UAT; caller invokes the lane recipe and attests each artifact"
    ;;
esac

echo "==> Phase 3.4: Codex code-diff review (caller's responsibility; MUST be clean BEFORE the smoke + Live UAT rebuild above — script not auto-invoking)"
if [ ! -s "$RUN_DIR/codex-review.txt" ] && [ "$DECLARED" = "Code" ]; then
  cat > "$RUN_DIR/codex-review-todo.txt" <<EOF
Run: ~/.claude/bin/codex-run $RUN_DIR/codex-review.txt review --base origin/main
(usage-limit fallback: see ~/.claude/knowledge/ai/codex-cli.md — never a bare launcher, never a > redirect)
EOF
  record_step "codex-review" 1 "Stage 1 stub — caller must run codex review and overwrite codex-review.txt"
fi

# --- Write run.json ---
COMPLETED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DETECTED_JSON=$(detected_json_from_lanes "$DETECTED")
CHANGED_JSON=$(printf '%s\n' "$CHANGED" | jq -R . | jq -s 'map(select(. != ""))')
SATISFIED_JSON=$(printf '%s\n' "${SATISFIED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s 'map(select(. != ""))')
SKIP_NOTES_JSON=$(printf '%s\n' "${SKIP_NOTES[@]}" | jq -R . | jq -s 'map(select(. != ""))')

jq -n \
  --argjson schema "$SCHEMA_VERSION" \
  --arg head "$HEAD_SHA" \
  --arg branch "$BRANCH" \
  --arg lane "$DECLARED" \
  --argjson detected "$DETECTED_JSON" \
  --argjson changed "$CHANGED_JSON" \
  --argjson mixed "$IS_MIXED" \
  --arg started "$STARTED_AT" \
  --arg completed "$COMPLETED_AT" \
  --argjson satisfied "$SATISFIED_JSON" \
  --argjson skipped "$SKIPPED_JSON" \
  --argjson notes "$SKIP_NOTES_JSON" \
  '{
    schema_version: $schema,
    head_sha: $head,
    branch: $branch,
    declared_lane: $lane,
    detected_lanes: $detected,
    changed_files: $changed,
    is_mixed_pr: $mixed,
    started_at: $started,
    completed_at: $completed,
    obligations_satisfied: $satisfied,
    obligations_skipped: $skipped,
    skip_notes: $notes
  }' > "$RUN_DIR/run.json"

# --- Final assertion ---
echo "==> Final: check-validation.sh"
"$PROJECT_ROOT/scripts/check-validation.sh" "$RUN_DIR"
EXIT_CODE=$?

echo ""
echo "==> Run directory: $RUN_DIR"
echo "==> Exit code: $EXIT_CODE"
exit $EXIT_CODE
