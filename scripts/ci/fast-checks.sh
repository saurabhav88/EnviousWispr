#!/usr/bin/env bash
# scripts/ci/fast-checks.sh: the ONE list of quick, deterministic checks (#3524).
#
# Cloud CI and the local git `pre-push` hook run this same file, so the list of
# checks cannot drift between them. Before #3524 these commands lived inline in
# pr-check.yml's `build-check` job and nothing ran them before a push: 32 of the
# 60 failed cloud attempts audited for 2026-09-23..10-07 were checks that already
# existed in CI and never ran on the Mac first
# (docs/audits/2026-10-07-ci-failure-audit/README.md, gitignored).
#
# Usage:
#   fast-checks.sh [--ci] [--tree <dir>]   run every member; exit 1 if any FAILS
#   fast-checks.sh --list [--ci]           print member names, one per line
#   fast-checks.sh --self-test             prove the runner's outcome contract
#
#   --tree <dir>  run every member with <dir> as its working directory (default:
#                 the checkout this script lives in). The pre-push hook passes a
#                 detached worktree of the pushed commit, so uncommitted and
#                 untracked files cannot change the verdict.
#   --ci          skip members whose CI home is another job (marked `other-job`
#                 below); build-check passes it.
#
# Outcome contract, one line per member:
#   ==> <name>: PASS
#   ==> <name>: FAIL (exit <n>)          any nonzero exit, whatever the member's
#                                        own exit code means; the member's output
#                                        above the line says why
#   ==> <name>: SKIP (missing tool: <t>) a declared tool is not installed; the
#                                        member is not run. Cloud CI has every
#                                        tool, so a SKIP here is a local gap only.
# A member function that does not exist is a FAIL (runner fault), never a pass.
# There is no "could not run" outcome: every current member is local-only and
# key-free, so a nonzero exit is a defect in the tree.
#
# Portability: runs under macOS /bin/bash 3.2 and Ubuntu bash 5. No associative
# arrays, no EPOCHREALTIME, no mapfile.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TREE="$(cd "$SCRIPT_DIR/../.." && pwd)"

# name | required tools (space-separated) | CI home (build-check or other-job)
# Tools are declared transitively (what the member's scripts call), except the
# POSIX baseline every supported machine has: grep, sed, awk, find, cut, tr.
# Order is CI's step order, then the two members whose CI home is another job.
MEMBERS=(
  "ci-self-tests|bash python3 git jq|build-check"
  "dependency-direction|bash grep|build-check"
  "lane-verdict-self-test|bash python3|build-check"
  "dev-app-lock-self-test|python3 ps|build-check"
  "download-link-lint|bash|build-check"
  "runtime-uat-self-tests|python3|build-check"
  "judge-contracts|python3|build-check"
  "eval-harness-self-tests|python3|build-check"
  "language-data-generator|python3|build-check"
  "third-party-notices|bash python3 perl|other-job"
  "worker-tests|node|other-job"
)

# ---------------------------------------------------------------------------
# Members. Bodies are the former pr-check.yml `run:` blocks, verbatim with their
# causal comments (minus `set -euo pipefail`, which the runner applies).
# ---------------------------------------------------------------------------

# CI step: CI self-tests (classify-changes + fetch-depth + compile cache + cache paths + schedule guard + metrics)
member_ci_self_tests() {
  scripts/ci/classify-changes.sh --self-test
  scripts/ci/check-pr-check-fetch-depth.sh
  python3 scripts/ci/check-test-recipe.py --self-test
  # #3019: the schedule guard decides whether a macOS matrix runs at
  # all, and it now waits for an in-flight push run; its verdict matrix
  # (mocked gh, no network) had no CI caller before this. The metrics
  # instrument is advisory in every lane, so a broken parser would be
  # invisible there; here it is red.
  scripts/ci/post-merge-should-run.sh --self-test
  python3 scripts/ci/ci-metrics.py --self-test
  # #2580. `actions/cache` hashes the PATH LIST into a cache version, and
  # a restore matches on version BEFORE key — so two lists that differ in
  # any way describe caches that can never see each other, with nothing
  # red and every lane simply rebuilding forever. Measured: eight lines of
  # prose written inside a `path: |` block scalar became eight paths,
  # because YAML block scalars have no comments. Verified to fail against
  # that exact commit.
  python3 scripts/ci/check-cache-paths.py --self-test
  python3 scripts/ci/check-cache-paths.py
  # #2580. Runs here because the failure it catches is SILENT: a config
  # missing a setting, or written and never exported, leaves every lane
  # building correctly and slowly with nothing red. Needs no Xcode, so
  # this ubuntu aggregator can hold it.
  scripts/ci/configure-compilation-cache.sh --self-test
}

# CI step: Dependency direction (#3095)
member_dependency_direction() {
  # The module graph does not enforce itself under Xcode (measured
  # 2026-08-26, recorded in the script): this grep IS the wall between
  # modules and between the unit suite and the desktop. PR #508 moved it
  # out of CI into the local push hook so the catch happens before the
  # push, with CI as the backstop; the backstop never landed. Measured
  # cost of that: the script was red on main from #2707 (2026-09-08)
  # until #3095, unnoticed: the hook only sees pushes made from one
  # tool on one machine, and its audit log holds none of the four
  # source PRs that landed last. Runs here, in the required aggregator,
  # because it needs only bash and grep and finishes in under a second.
  bash scripts/check-dependency-direction.sh
}

# CI step: Lane verdict self-test (#2401)
member_lane_verdict_self_test() {
  # The owner that decides whether a test lane counts as passing is
  # itself only as good as its own suite, and a suite nothing invokes
  # first fires in someone else's run. It lives HERE, inside the
  # required aggregator, because that is the gate this owner protects.
  #
  # Runs on Linux deliberately: every case either drives the judge
  # directly on a JSON payload or exercises a shell path that
  # short-circuits before `xcrun`, so it needs no Xcode. The sibling
  # scripts/lib suites are NOT wired in yet — a real gap, stated rather
  # than papered over by adding suites whose macOS assumptions have not
  # been checked on this runner.
  bash scripts/lib/lane-verdict-test.sh
}

# CI step: Dev-app lock self-test (#3400)
member_dev_app_lock_self_test() {
  # The shared dev-app claim every build takes. Its test runs a private
  # copy against a temp folder, so it touches no real lock, and needs
  # only python3, ps and flock, which this Linux runner has. This step
  # is the first Linux run of it; the suite was written on macOS.
  python3 scripts/lib/dev-app-lock-test.py
}

# CI step: Download-link lint (doorway tagging + on-site /#download)
member_download_link_lint() {
  scripts/ci/check-download-link-utms.sh --self-test
  scripts/ci/check-download-link-utms.sh
}

# CI step: RuntimeUAT PTT binding policy + Swift/Python key parity + instance guard
member_runtime_uat_self_tests() {
  # #1997. The UAT harness resolves which key to hold for push-to-talk.
  # When it cannot, it must REFUSE — a harness that presses a guessed key
  # reports the resulting silence as a product failure, which is what
  # happened on 2026-08-10. These self-tests lock that policy, and the
  # parity case fails if Swift's standalone-modifier set and Python's
  # MODIFIER_KEYS drift apart in EITHER direction: an app-only key makes
  # the harness refuse (safe), but a Python-only key makes it post a
  # modifier event at a Carbon-registered hotkey and produce exactly that
  # false product FAIL.
  #
  # #2426 adds the third. The membership rule for this step is that a
  # module here imports nothing heavy: no Quartz, no PyObjC, so it can be
  # imported on the hosted runner without an untested assumption about
  # what that runner has. `ptt_binding` and `faultInjection` already met
  # it. `wispr_eyes` does not — it reaches ApplicationServices through
  # `ui_helpers` — so its single-instance guard was MOVED to
  # `instance_guard.py`, which imports only `os`, `subprocess` and `sys`.
  # That is what makes the third line safe to add: the rule was satisfied
  # rather than waived. The guard refuses a UAT verdict when a second
  # EnviousWispr is running, because every instance answers the same
  # global hotkey and writes the same `app.log`, so a marker count drawn
  # from that log is unattributable — measured 2026-08-25 as two real
  # recordings from one gesture, reading as the app double-counting.
  python3 Tests/RuntimeUAT/ptt_binding.py --self-test
  python3 Tests/RuntimeUAT/faultInjection.py --self-test
  python3 Tests/RuntimeUAT/instance_guard.py --self-test
  # #2775 UAT front door. These three are PyObjC-free by design (like the
  # instance guard, #2426) so they run on the hosted runner. uat_catalog's
  # self-test fails if a public wispr_eyes function has no trust-status row.
  python3 Tests/RuntimeUAT/uat_catalog.py --self-test
  python3 Tests/RuntimeUAT/log_verdict.py --self-test
  python3 Tests/RuntimeUAT/preflight.py --self-test
  # uat.py imports no PyObjC at module level, so its verdict-classifier
  # self-test (the contract Codex diff review hammered) runs here too.
  python3 Tests/RuntimeUAT/uat.py --self-test
}

# CI step: Judge receipt + billing contracts (#2007/#2008)
member_judge_contracts() {
  # Also carries the judge BILLING gate: grading on a personal vendor API key is
  # banned. Routing and the billing classification both derive from one route
  # table, and an unrecognised id is refused before either funded transport can
  # run — the personal-key transports were deleted outright, so there is nothing
  # for a typo to fall through to.
  #
  # A judge run that dropped work must never read as a complete receipt.
  # Three layers have to agree: behavior_judge.py detects the gap,
  # judge_ollama_bench.sh refuses to cache a partial receipt, and
  # report_ollama_bench.py refuses to rank one. Before #2007 an
  # adjudication pass that returned NOTHING produced a CLEAR receipt
  # advertising a recheck it never ran, and the benchmark then cached that
  # receipt and skipped the model forever while the report refused it.
  #
  # Wired into build-check because that is the only REQUIRED check — a
  # suite no gate invokes reports nothing, so nothing ever looks wrong
  # (#1965, #2013). Pure stdlib, no network, no judge calls; the suite
  # asserts its own exact test count, because the runner it borrows from
  # exits 0 when it discovers zero tests.
  python3 scripts/eval/behavior_judge_test.py
}

# CI step: Eval harness self-tests (#2013)
member_eval_harness_self_tests() {
  # These two suites were TRACKED and had NEVER been executed by any CI
  # job — 25 cases whose green status meant nothing, and which anyone
  # reading the repo would reasonably assume were guarding something.
  # Same class as #1965: a suite no gate invokes reports nothing, so
  # nothing ever looks wrong. Worse than `0 tests`, which prints a zero.
  #
  # Neither subject imports outside the stdlib (alias_suggestion_gate:
  # argparse difflib json os re subprocess sys; v4_adversarial_runner:
  # argparse json os sys time datetime pathlib), so both run here under
  # bare python3 with no pytest install. Each asserts its own exact test
  # count, because both runners exit 0 on ZERO discovered tests.
  #
  # test_custom_vocab_mirror (#2609) joins them under the same rule: it
  # pins the gate's CUSTOM VOCABULARY block to production's
  # (priority, canonical) sort order. Importing acceptance_gate pulls in
  # only the stdlib and reads no key, so it runs here on the same terms.
  python3 scripts/eval/tests/test_alias_scorer.py
  python3 scripts/eval/tests/test_v4_adversarial_runner.py
  # The registry rebuild's history-loss guards (#2581): a deleted or
  # renamed ARMS row must be REFUSED, not silently dropped. Same runner
  # shape and exact-count assertion as the two above.
  python3 scripts/eval/tests/test_rebuild_model_registry.py
  python3 scripts/eval/tests/test_custom_vocab_mirror.py
  # #2851 phase 2: the pack-mode section envelope (wrap/unwrap/accept mirror)
  # and the runner's --pack/--dry-run plumbing, driven with a fake call_once.
  # Same runner shape and exact-count assertion; imports nothing outside the
  # stdlib and reads no key.
  python3 scripts/eval/tests/test_section_envelope.py
  # #996: the eval-package pin seeding (compile-eval-packages.sh) merges
  # a runner's tracked runner-only pins into the app's pins and refuses
  # a pin that would shadow an app pin. Stdlib only; same count rule.
  python3 scripts/eval/tests/test_seed_eval_package_pins.py
  # #2789: the one key-free check the retired cloud polish workflow carried.
  # Compares the canonical cloud prompt file, its Python mirror and the Swift
  # builder's text after stripping outer whitespace; exit 2 on drift. Imports
  # only the stdlib and reads no key, so it runs here on the same terms.
  python3 scripts/eval/acceptance_gate.py --mode selftest
}

# CI step: Language data generator (#1677)
member_language_data_generator() {
  # The committed German data files under Sources/EnviousWisprPostProcessing/Generated/
  # are OUTPUT of scripts/itn/generate.py from pinned local sources. Without this
  # step a hand edit, a source change or a generator change that no longer
  # reproduces a committed file would pass every other lane, because the Swift
  # tests read the committed bytes, not the generator. --check regenerates all four
  # outputs in a temp dir and byte-compares them. Normal generation and --check
  # use local inputs. The suite's --refresh rejection test fails on an unpinned
  # fixture before any network request. Narrow discovery selects generator tests,
  # not corpus-validator tests. Needs only python3 and the stdlib.
  python3 scripts/itn/generate.py --check
  python3 -m unittest discover -s scripts/itn/tests -p 'test_generate.py'
}

# CI home: build-and-test, step "Verify third-party notices are in sync", which
# runs it before any macOS work. Here so the Mac runs it before a push. The
# causal comment below is that step's, verbatim.
#
# #1778: the notices gate used to run ONLY during release packaging, so a
# dependency bump that forgot the generator sat green on main until someone
# tried to ship - v2.4.1 lost two release runs to exactly that (Sparkle
# 2.9.4 via #1733, swift-syntax via #1741). `--check` reads only committed
# files (no .build/checkouts), so it is seconds and runs unconditionally:
# a paths filter here would be one more thing that can drift out of sync.
member_third_party_notices() {
  scripts/ci/gen-third-party-notices.sh --check
}

# CI home: the worker-tests job (pr-check.yml), which sets up Node 22 and runs
# exactly this loop unconditionally. Here so the Mac runs it before a push.
member_worker_tests() {
  for w in daily-report weekly-digest sentry-triage download-counter shared; do
    echo "==> $w"
    ( cd "workers/$w" && node --test )
  done
}

# ---------------------------------------------------------------------------
# Runner
#
# Every step that can fail says so: a runner fault is a FAIL with the step named,
# never a silent pass. Steps and their self-test controls (all below):
#   runner tool check (pgrep) ............ "a missing runner tool is a FAIL"
#   create the log directory ............. "a log directory that cannot be created"
#   select members (record, write) ....... "a malformed member record", "a selection
#                                          that cannot be written", "an empty selection"
#   open the selection ................... "an unreadable selection"
#   read each record ..................... "a blank selection line"
#   write each name / launch / wait ...... status-versus-log cases, "SIGKILL" cases
#   read the name, the log, the outcome .. "an unreadable name file", "an unreadable log"
#   print the verdict .................... "a closed standard output"
#   remove the logs ...................... "logs that cannot be removed"
#   interruption, descendant probe ....... "interrupted run" cases (real entrypoint),
#                                          "a failing descendant probe"
# "no members launched" is a defensive guard with no control: the selection check
# and the blank-line check reject every input that could reach it.
# ---------------------------------------------------------------------------

RUNNER_LOGS=""
ACTIVE_PIDS=""
CLEANUP_INCOMPLETE=""

# A member's whole process tree: interruption walks each running member's
# descendants by parent PID (`pgrep -P`, on macOS and Linux alike) and signals
# them before the member itself, so the Python and Node processes a member
# started stop too, and nothing outside our own tree is touched. (Process
# groups via `set -m` were tried first; whether a non-interactive bash gives a
# background job its own group depends on how bash itself was launched.)
stop_tree() { # stop_tree <pid>: TERM every descendant, deepest first, then pid
  local children rc child
  # pgrep exits 1 for "no children"; anything else means we could not look, so
  # the cleanup is reported incomplete rather than assumed done.
  children="$(pgrep -P "$1")"
  rc=$?
  if [ "$rc" -gt 1 ]; then CLEANUP_INCOMPLETE="could not list the child processes of $1 (pgrep exit $rc)"; fi
  for child in $children; do
    stop_tree "$child"
  done
  kill -TERM "$1" 2> /dev/null
}

stop_members() {
  local pid
  for pid in $ACTIVE_PIDS; do
    stop_tree "$pid"
  done
  for pid in $ACTIVE_PIDS; do
    wait "$pid" 2> /dev/null
  done
  ACTIVE_PIDS=""
}

on_interrupt() {
  stop_members
  [ -n "$RUNNER_LOGS" ] && rm -rf "$RUNNER_LOGS"
  if [ -n "$CLEANUP_INCOMPLETE" ]; then
    echo "==> fast-checks: FAIL (interrupted; cleanup incomplete: $CLEANUP_INCOMPLETE)"
  else
    echo "==> fast-checks: FAIL (interrupted)"
  fi
  exit 130
}

have_tool() { command -v "$1" > /dev/null 2>&1; }

# run_member <name> <tools> <function> <tree>; prints the outcome line.
# Returns 0 for PASS and SKIP, 1 for FAIL.
run_member() {
  local name="$1" tools="$2" fn="$3" tree="$4" tool rc started elapsed
  for tool in $tools; do
    if ! command -v "$tool" > /dev/null 2>&1; then
      echo "==> $name: SKIP (missing tool: $tool)"
      return 0
    fi
  done
  if ! declare -F "$fn" > /dev/null; then
    echo "==> $name: FAIL (runner fault: no function $fn)"
    return 1
  fi
  started=$SECONDS
  ( cd "$tree" && set -euo pipefail && "$fn" )
  rc=$?
  elapsed=$((SECONDS - started))
  if [ "$rc" -eq 0 ]; then
    echo "==> $name: PASS (${elapsed}s)"
    return 0
  fi
  echo "==> $name: FAIL (exit $rc, ${elapsed}s)"
  return 1
}

# Prints the records this mode runs. A malformed record (not three fields) is a
# fault, not a member to skip.
selected_members() {
  local ci="$1" record name tools home
  # ${a[@]+...}: bash 3.2 treats an empty array as unset under `set -u`.
  for record in ${MEMBERS[@]+"${MEMBERS[@]}"}; do
    IFS='|' read -r name tools home <<< "$record" || return 1
    case "$home" in build-check | other-job) ;; *) return 1 ;; esac
    [ -n "$name" ] || return 1
    if [ "$ci" -eq 1 ] && [ "$home" = "other-job" ]; then continue; fi
    printf '%s\n' "$record" || return 1
  done
}

without_pid() { # without_pid <pid> <space-separated pids>
  local p kept=""
  for p in $2; do [ "$p" = "$1" ] || kept="$kept $p"; done
  printf '%s' "$kept"
}

runner_fault() { # prints the FAIL line, removes the logs, returns 1
  echo "==> fast-checks: FAIL (runner fault: $1)"
  stop_members
  [ -n "$RUNNER_LOGS" ] && rm -rf "$RUNNER_LOGS"
  RUNNER_LOGS=""
  return 1
}

# run_all runs every selected member AT THE SAME TIME, each into its own log,
# then prints the logs and outcome lines in member order. In sequence they took
# 43 s on the Mac (2026-10-07), too slow for a pre-push hook; in parallel the wait
# is about the slowest member. Members do not share writes (audit:
# docs/audits/2026-10-07-ci-failure-audit/, gitignored).
run_all() {
  local ci="$1" tree="$2" record name tools home fn failed=0 skipped=0 out i n child_rc
  local pids_by_index="" output_ok=1
  have_tool pgrep || { runner_fault "missing runner tool: pgrep"; return 1; }
  RUNNER_LOGS="$(mktemp -d)" || { RUNNER_LOGS=""; runner_fault "cannot create a log directory"; return 1; }
  trap on_interrupt INT TERM
  selected_members "$ci" > "$RUNNER_LOGS/selected" || { runner_fault "cannot select members"; return 1; }
  [ -s "$RUNNER_LOGS/selected" ] || { runner_fault "no members selected"; return 1; }
  exec 3< "$RUNNER_LOGS/selected" || { runner_fault "cannot open the member selection"; return 1; }

  i=0
  while IFS='|' read -r name tools home <&3; do
    [ -n "$name" ] || { exec 3<&-; runner_fault "blank line in the member selection"; return 1; }
    i=$((i + 1))
    fn="member_${name//-/_}"
    printf '%s\n' "$name" > "$RUNNER_LOGS/$i.name" || { exec 3<&-; runner_fault "cannot write $RUNNER_LOGS/$i.name"; return 1; }
    run_member "$name" "$tools" "$fn" "$tree" > "$RUNNER_LOGS/$i.log" 2>&1 &
    pids_by_index="$pids_by_index $!"
    ACTIVE_PIDS="$ACTIVE_PIDS $!"
  done
  exec 3<&-
  [ "$i" -gt 0 ] || { runner_fault "no members launched"; return 1; }

  n=0
  for pid in $pids_by_index; do
    n=$((n + 1))
    # The exit status is the verdict; the log only explains it. A nonzero status
    # fails the member even if its log ends in PASS; a zero status needs a PASS or
    # SKIP outcome line.
    if wait "$pid"; then child_rc=0; else child_rc=$?; fi
    ACTIVE_PIDS="$(without_pid "$pid" "$ACTIVE_PIDS")"
    name="$(cat "$RUNNER_LOGS/$n.name")" || { runner_fault "cannot read $RUNNER_LOGS/$n.name"; return 1; }
    echo "::group::$name" || output_ok=0
    cat "$RUNNER_LOGS/$n.log" || { echo "::endgroup::"; runner_fault "cannot read the log of $name"; return 1; }
    echo "::endgroup::" || output_ok=0
    out="$(tail -1 "$RUNNER_LOGS/$n.log")" || { runner_fault "cannot read the outcome of $name"; return 1; }
    case "$child_rc|$out" in
      "0|==> $name: PASS"*) ;;
      "0|==> $name: SKIP"*) skipped=$((skipped + 1)) ;;
      "0|"*) failed=$((failed + 1)); out="==> $name: FAIL (runner fault: exit 0 with no outcome line)" ;;
      *"==> $name: FAIL"*) failed=$((failed + 1)) ;;
      *) failed=$((failed + 1)); out="==> $name: FAIL (runner fault: exit $child_rc, last line: ${out:-none})" ;;
    esac
    # The outcome line again, outside the group, so a folded CI log still shows it.
    echo "$out" || output_ok=0
  done
  trap - INT TERM
  rm -rf "$RUNNER_LOGS" || { runner_fault "cannot remove $RUNNER_LOGS"; return 1; }
  RUNNER_LOGS=""
  echo "==> fast-checks: $i members, $failed failed, $skipped skipped" || output_ok=0
  # A verdict nobody could read is not a pass.
  [ "$output_ok" -eq 1 ] || return 1
  [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Self-test: drives run_member and run_all with stub members, in this process.
# No environment switch changes what a real run does.
# ---------------------------------------------------------------------------

# The member list, frozen independently of MEMBERS. Adding or removing a member
# is a deliberate edit to both.
EXPECTED_MEMBERS="ci-self-tests dependency-direction lane-verdict-self-test dev-app-lock-self-test download-link-lint runtime-uat-self-tests judge-contracts eval-harness-self-tests language-data-generator third-party-notices worker-tests"

member_names() { local r; for r in "$@"; do printf '%s ' "${r%%|*}"; done; }

inventory_matches() { # inventory_matches <expected words> <record>...
  local expected="$1"; shift
  [ "$(member_names "$@" | sed 's/ $//')" = "$expected" ]
}

self_test() {
  local tmp fails=0 cases=0 out rc name pid killed_rc
  tmp="$(mktemp -d)" || { echo "self-test: cannot create a temp dir"; return 1; }

  check() { # check <label> <actual> <expected>
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
  }
  last_outcome() { printf '%s\n' "$1" | grep '^==> ' | tail -2 | head -1; }

  # --- run_member
  stub_pass() { echo "stub ran"; }
  stub_exit1() { return 1; }
  stub_exit7() { return 7; }
  stub_touch() { touch "$tmp/invoked"; }
  stub_seterr() { false; echo "not reached"; }

  out="$(run_member a "bash" stub_pass "$tmp" 2>&1)"; rc=$?
  check "a passing member prints PASS and returns 0" "$rc|$(printf '%s' "$out" | tail -1 | cut -d' ' -f1-3)" "0|==> a: PASS"
  out="$(run_member b "bash" stub_exit1 "$tmp" 2>&1)"; rc=$?
  check "exit 1 is FAIL" "$rc|$(printf '%s' "$out" | tail -1 | cut -d, -f1)" "1|==> b: FAIL (exit 1"
  out="$(run_member c "bash" stub_exit7 "$tmp" 2>&1)"; rc=$?
  check "any other nonzero is FAIL too, never a softer outcome" "$rc|$(printf '%s' "$out" | tail -1 | cut -d, -f1)" "1|==> c: FAIL (exit 7"
  out="$(run_member d "bash definitely-not-a-tool-3524" stub_touch "$tmp" 2>&1)"; rc=$?
  check "a missing tool is SKIP and the member is not run" "$rc|$out|$([ -e "$tmp/invoked" ] && echo invoked || echo not-invoked)" "0|==> d: SKIP (missing tool: definitely-not-a-tool-3524)|not-invoked"
  out="$(run_member e "bash" member_does_not_exist_3524 "$tmp" 2>&1)"; rc=$?
  check "a missing member function is a runner fault FAIL" "$rc|$out" "1|==> e: FAIL (runner fault: no function member_does_not_exist_3524)"
  out="$(run_member f "bash" stub_seterr "$tmp" 2>&1)"; rc=$?
  check "errexit applies inside a member (a failing command stops it)" "$rc|$(printf '%s' "$out" | grep -c 'not reached')" "1|0"

  # --- inventory and selection
  check "the member list equals the frozen inventory" "$(inventory_matches "$EXPECTED_MEMBERS" ${MEMBERS[@]+"${MEMBERS[@]}"} && echo match || echo drift)" "match"
  check "a dropped member is detected as drift" "$(inventory_matches "$EXPECTED_MEMBERS" "${MEMBERS[@]:1}" && echo match || echo drift)" "drift"
  for name in $EXPECTED_MEMBERS; do
    check "member function exists for $name" "$(declare -F "member_${name//-/_}" > /dev/null && echo yes || echo no)" "yes"
  done
  check "--ci leaves out exactly the other-job members" "$(selected_members 1 | cut -d'|' -f1 | grep -c -e third-party-notices -e worker-tests)|$(selected_members 1 | wc -l | tr -d ' ')" "0|9"

  local saved_members=("${MEMBERS[@]}")
  MEMBERS=("bad-record-without-fields")
  out="$(run_all 0 "$tmp" 2>/dev/null)"; rc=$?
  check "a malformed member record is a selection fault" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: cannot select members)"
  MEMBERS=()
  out="$(run_all 0 "$tmp" 2>/dev/null)"; rc=$?
  check "an empty selection is a FAIL, never a pass" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: no members selected)"

  # --- aggregation
  MEMBERS=("p|bash|build-check" "q|bash|build-check")
  member_p() { return 0; }
  member_q() { return 3; }
  out="$(run_all 0 "$tmp" 2>/dev/null)"; rc=$?
  check "one failing member fails the run" "$rc|$(printf '%s' "$out" | tail -1)" "1|==> fast-checks: 2 members, 1 failed, 0 skipped"

  # --- runner faults (log directory)
  out="$( mktemp() { return 1; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a log directory that cannot be created is a FAIL" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: cannot create a log directory)"

  # --- status and log must agree (stub run_member in a subshell so the real one is untouched)
  MEMBERS=("r|bash|build-check")
  out="$( run_member() { echo "==> r: PASS (0s)"; return 1; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a nonzero child status fails even when its log says PASS" "$rc|$(last_outcome "$out")" "1|==> r: FAIL (runner fault: exit 1, last line: ==> r: PASS (0s))"
  out="$( run_member() { echo "something else"; return 0; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a zero child status with no outcome line fails" "$rc|$(last_outcome "$out")" "1|==> r: FAIL (runner fault: exit 0 with no outcome line)"

  # --- a child that really dies of SIGKILL
  /bin/bash -c 'kill -KILL "$$"' 2> /dev/null &
  pid=$!
  if wait "$pid" 2> /dev/null; then killed_rc=0; else killed_rc=$?; fi
  check "the control child really died of SIGKILL" "$killed_rc" "137"
  out="$( run_member() { echo "==> r: PASS (0s)"; /bin/bash -c 'kill -KILL "$PPID"'; sleep 5; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a member killed by SIGKILL fails the run" "$rc|$(last_outcome "$out")" "1|==> r: FAIL (runner fault: exit 137, last line: ==> r: PASS (0s))"

  # --- every other runner fault, each with its own control
  out="$( have_tool() { [ "$1" != pgrep ]; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a missing runner tool is a FAIL" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: missing runner tool: pgrep)"
  MEMBERS=("p|bash|build-check")
  out="$( selected_members() { command printf 'p|bash|build-check\n'; return 1; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a selection that cannot be written is a FAIL" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: cannot select members)"
  out="$( selected_members() { command printf 'p|bash|build-check\n'; chmod 000 "$RUNNER_LOGS/selected"; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "an unreadable selection is a FAIL" "$rc|$(printf '%s' "$out" | grep -c 'cannot open the member selection')" "1|1"
  out="$( selected_members() { command printf '\n'; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "a blank selection line is a FAIL" "$rc|$out" "1|==> fast-checks: FAIL (runner fault: blank line in the member selection)"
  out="$( cat() { case "$1" in (*.name) return 1 ;; (*) command cat "$@" ;; esac; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "an unreadable name file is a FAIL" "$rc|$(printf '%s' "$out" | grep -c 'runner fault: cannot read .*1.name')" "1|1"
  out="$( cat() { case "$1" in (*.log) return 1 ;; (*) command cat "$@" ;; esac; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "an unreadable log is a FAIL" "$rc|$(printf '%s' "$out" | grep -c 'runner fault: cannot read the log of p')" "1|1"
  out="$( rm() { case "$*" in (*-rf*) return 1 ;; (*) command rm "$@" ;; esac; }; run_all 0 "$tmp" 2>/dev/null )"; rc=$?
  check "logs that cannot be removed are a FAIL" "$rc|$(printf '%s' "$out" | grep -c 'runner fault: cannot remove')" "1|1"
  ( run_all 0 "$tmp" >&- 2> /dev/null ); rc=$?
  check "a closed standard output is a FAIL, never a pass nobody saw" "$rc" "1"

  # --- interruption stops the member's whole process tree, through the REAL
  # entrypoint: a private copy of this script whose only change is one stub
  # member appended before `main`. The copy fails closed if that edit misses.
  local copy="$tmp/fast-checks-copy.sh" marker='main "$@"'
  if [ "$(grep -cx "$marker" "$0")" != 1 ]; then
    check "the interruption copy can be made" "no single main line" "made"
  else
    {
      sed "/^main \"\$@\"\$/d" "$0"
      printf '%s\n' 'MEMBERS=("s|bash|build-check")'
      printf 'member_s() { sleep 30 & echo $! > "%s/grandchild"; wait; }\n' "$tmp"
      printf '%s\n' "$marker"
    } > "$copy"
    bash "$copy" --tree "$tmp" > "$tmp/interrupted.out" 2>&1 &
    pid=$!
    local waited=0
    while [ ! -s "$tmp/grandchild" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    kill -TERM "$pid"
    if wait "$pid"; then rc=0; else rc=$?; fi
    local gc; gc="$(cat "$tmp/grandchild" 2> /dev/null)"
    sleep 0.2
    check "an interrupted run exits 130 and says so" "$rc|$(tail -1 "$tmp/interrupted.out")" "130|==> fast-checks: FAIL (interrupted)"
    check "precondition: the member started its own child before the interrupt" "$([ -n "$gc" ] && echo started || echo none)" "started"
    check "interruption stops the member's own child process" "$([ -n "$gc" ] && kill -0 "$gc" 2> /dev/null && echo still-running || echo stopped)" "stopped"
    # Clean up only this test's own child, by its recorded PID, if it survived.
    [ -n "$gc" ] && kill "$gc" 2> /dev/null

    # The same interruption with a descendant probe that fails: the runner must say
    # the cleanup is incomplete, never claim it stopped everything.
    rm -f "$tmp/grandchild"
    {
      sed "/^main \"\$@\"\$/d" "$0"
      printf '%s\n' 'MEMBERS=("s|bash|build-check")'
      printf 'member_s() { sleep 30 & echo $! > "%s/grandchild"; wait; }\n' "$tmp"
      printf '%s\n' 'pgrep() { return 2; }'
      printf '%s\n' "$marker"
    } > "$copy"
    bash "$copy" --tree "$tmp" > "$tmp/interrupted.out" 2>&1 &
    pid=$!
    waited=0
    while [ ! -s "$tmp/grandchild" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    kill -TERM "$pid"
    if wait "$pid"; then rc=0; else rc=$?; fi
    gc="$(cat "$tmp/grandchild" 2> /dev/null)"
    check "a failing descendant probe is reported as incomplete cleanup" "$rc|$(tail -1 "$tmp/interrupted.out" | grep -c '^==> fast-checks: FAIL (interrupted; cleanup incomplete: could not list the child processes')" "130|1"
    [ -n "$gc" ] && kill "$gc" 2> /dev/null
  fi

  MEMBERS=("${saved_members[@]}")
  rm -rf "$tmp"
  echo "self-test: $cases cases, $fails failure(s)"
  [ "$fails" -eq 0 ]
}

main() {
  local mode=run ci=0 tree="$DEFAULT_TREE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --ci) ci=1 ;;
      --tree) [ $# -ge 2 ] || { echo "fast-checks: --tree needs a directory" >&2; exit 2; }; tree="$2"; shift ;;
      --list) mode=list ;;
      --self-test) mode=self-test ;;
      *) echo "fast-checks: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$mode" in
    self-test) self_test ;;
    list) selected_members "$ci" | cut -d'|' -f1 ;;
    run)
      [ -n "$tree" ] && [ -d "$tree" ] || { echo "fast-checks: no such tree: '${tree}' (could not resolve this checkout?)" >&2; exit 2; }
      run_all "$ci" "$tree"
      ;;
  esac
}

main "$@"
