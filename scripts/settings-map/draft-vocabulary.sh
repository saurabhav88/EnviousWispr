#!/usr/bin/env bash
# Drafts Settings search vocabulary for ONE searchable Settings Map id (#3482).
#
#   scripts/settings-map/draft-vocabulary.sh <id>
#   scripts/settings-map/draft-vocabulary.sh --self-test
#
# 1. Exports the id's metadata from the compiled Settings Map through the opt-in
#    SettingsMapExportTests (the one extraction owner). An unknown, renamed,
#    structural or exempt id fails here, before any model runs.
# 2. Builds a prompt from scripts/settings-map/draft-brief.md plus that export only.
# 3. Runs Codex through ~/.claude/bin/codex-run in a fresh isolated context: a new
#    empty working folder outside every repository (so no AGENTS.md, CLAUDE.md,
#    plan, fixture or query file is in reach), a private CODEX_HOME holding only
#    the auth link (no global instructions, memories or config), web search off,
#    read-only sandbox, --ignore-rules, --ephemeral.
# 4. Writes an UNREVIEWED draft and a hash receipt to
#    build/settings-map-drafts/<id>-<UTC time>.<random>/. It never edits the shipped
#    resource or any review receipt, and never validates the shipped schema:
#    adoption goes through review and the Swift validator (see README.md).
#
# Exit: 0 draft written · 2 usage · 3 export refused or failed (no model ran)
#       4 launcher failed (quota, auth, stall: codex-run's own code is printed)
#       5 the model's answer is not one JSON object for this id.
# No paid fallback: a failed launch stops.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIEF="$ROOT/scripts/settings-map/draft-brief.md"
DRAFTS_ROOT="$ROOT/build/settings-map-drafts"
CODEX_AUTH="$HOME/.codex/auth.json"
EXPORT_FN=export_metadata
LAUNCH_FN=launch_codex

die() {
  local code="$1"
  shift
  echo "draft-vocabulary: $*" >&2
  exit "$code"
}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Writes the export for $1 to $2; the log goes to $3.
export_metadata() {
  TEST_RUNNER_EW_SETTINGS_MAP_EXPORT="$2" TEST_RUNNER_EW_SETTINGS_MAP_EXPORT_ID="$1" \
    "$ROOT/scripts/xcode-test.sh" --configuration Debug \
    --filter EnviousWisprTests/SettingsMapExportTests >"$3" 2>&1
}

# Runs Codex in folder $1 with CODEX_HOME $2; the prompt arrives on stdin; the
# answer lands at $3.last.
launch_codex() {
  (cd "$1" && CODEX_HOME="$2" "$HOME/.claude/bin/codex-run" "$3" \
    -c tools.web_search=false exec --sandbox read-only --skip-git-repo-check \
    --ignore-rules --ephemeral -C "$1")
}

draft() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 2 "not an id: '$id'"
  [ -f "$BRIEF" ] || die 2 "missing $BRIEF"

  local dir
  # Every step checks its own status: draft may run where errexit does not apply.
  mkdir -p "$DRAFTS_ROOT" || die 2 "cannot create $DRAFTS_ROOT"
  dir="$(mktemp -d "$DRAFTS_ROOT/$id-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || die 2 "cannot create a draft folder"
  local export_json="$dir/export.json"

  echo "draft-vocabulary: exporting $id from the compiled Settings Map (log: $dir/export.log)"
  local status=0
  "$EXPORT_FN" "$id" "$export_json" "$dir/export.log" || status=$?
  if [ "$status" -ne 0 ] || [ ! -s "$export_json" ]; then
    local reason
    reason="$(grep -A1 'recorded an issue' "$dir/export.log" | grep -Eo "$id is (a structural Settings Map node|not a searchable Settings Map id)[^\"]*|the built app has no [a-z]+ catalog[^\"]*|app products beside the tests[^\"]*|[a-z]+: no catalog entry[^\"]*" \
      | head -1 || true)"
    die 3 "${reason:-export failed (status $status, no export file); see $dir/export.log}. No model ran."
  fi
  # The export must be this id only, freshly written by this run.
  python3 - "$export_json" "$id" <<'PY' || die 3 "export is not exactly one entry for $id; no model ran"
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
entries = document.get("entries")
sys.exit(0 if document.get("schema") == "settings-map-export" and isinstance(entries, list)
         and len(entries) == 1 and entries[0].get("id") == sys.argv[2] else 1)
PY

  local prompt="$dir/prompt.md"
  cat "$BRIEF" "$export_json" >"$prompt" || die 2 "cannot write $prompt"

  # A fresh isolated context, outside every repository.
  local iso
  iso="$(mktemp -d "${TMPDIR:-/tmp}/ew-vocab-draft.XXXXXX")" || die 4 "cannot create an isolated folder"
  local cleanup
  printf -v cleanup 'rm -rf -- %q' "$iso"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  mkdir "$iso/work" "$iso/codex-home" || die 4 "cannot create the isolated folders"
  ln -s "$CODEX_AUTH" "$iso/codex-home/auth.json" || die 4 "cannot link the Codex auth file"
  if git -C "$iso/work" rev-parse --git-dir >/dev/null 2>&1; then
    die 4 "isolation failed: $iso/work is inside a git repository"
  fi
  local ancestor="$iso/work"
  while [ "$ancestor" != "/" ]; do
    for name in AGENTS.md CLAUDE.md; do
      [ ! -e "$ancestor/$name" ] || die 4 "isolation failed: $ancestor/$name is in reach"
    done
    ancestor="$(dirname "$ancestor")"
  done
  [ "$(ls -A "$iso/codex-home")" = "auth.json" ] || die 4 "isolation failed: CODEX_HOME is not empty"

  echo "draft-vocabulary: drafting in an isolated Codex session ($iso)"
  status=0
  "$LAUNCH_FN" "$iso/work" "$iso/codex-home" "$iso/out.txt" <"$prompt" || status=$?
  [ "$status" -eq 0 ] || die 4 "codex-run failed with exit $status (quota, auth or stall); no draft written"
  [ -s "$iso/out.txt.last" ] || die 4 "codex-run exited 0 without an answer file"
  cp "$iso/out.txt.last" "$dir/answer.txt" || die 4 "cannot keep the answer"

  python3 - "$dir/answer.txt" "$id" "$dir/draft.json" <<'PY' || die 5 "the answer is not one JSON object for $id; see $dir/answer.txt"
import json, sys
text = open(sys.argv[1], encoding="utf-8").read()
start, end = text.find("{"), text.rfind("}")
if start < 0 or end < start:
    sys.exit(1)
draft = json.loads(text[start:end + 1])
if draft.get("id") != sys.argv[2] or not isinstance(draft.get("blocks"), list):
    sys.exit(1)
with open(sys.argv[3], "w", encoding="utf-8") as handle:
    json.dump(draft, handle, ensure_ascii=False, indent=1)
    handle.write("\n")
PY

  {
    echo "status: UNREVIEWED draft. Review it, then adopt it through scripts/settings-map/README.md."
    echo "id: $id"
    echo "repository HEAD: $(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "brief sha256: $(sha "$BRIEF")"
    echo "export sha256: $(sha "$export_json")"
    echo "prompt sha256: $(sha "$prompt")"
    echo "answer sha256: $(sha "$dir/answer.txt")"
    echo "draft sha256: $(sha "$dir/draft.json")"
    echo "launch: codex-run exec, read-only sandbox, web search off, --ignore-rules, --ephemeral"
    echo "isolation: working folder outside every repository; CODEX_HOME held only auth.json"
  } >"$dir/receipt.txt" || die 2 "cannot write the receipt"
  echo "draft-vocabulary: UNREVIEWED draft at $dir/draft.json (receipt: $dir/receipt.txt)"
}

# ---- self-test: stubbed exporter and launcher; no build, no model ------------
shipped_state() {
  find "$ROOT/Sources/EnviousWisprAppKit/Resources/SettingsSearchVocabulary.json" \
    "$ROOT/scripts/settings-map/receipts" -type f -exec shasum -a 256 {} + 2>/dev/null | sort
}

self_test() {
  local scratch passed=0 failed=0 before
  # The quote in the name checks that every cleanup handler quotes its paths.
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/ew-vocab-selftest's.XXXXXX")"
  export TMPDIR="$scratch"
  before="$(shipped_state)"
  DRAFTS_ROOT="$scratch/drafts"
  CODEX_AUTH="$scratch/auth.json"
  echo '{}' >"$CODEX_AUTH"
  EXPORT_FN=stub_export
  LAUNCH_FN=stub_launch

  check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      echo "self-test FAIL: $name: want $want, got $got" >&2
    fi
  }
  run() { (draft "$1") >"$scratch/run.log" 2>&1 && echo 0 || echo $?; }

  # Exporter stub: good.id exports; structural.id and exempt.id refuse as the test does.
  stub_export() {
    case "$1" in
      good.id | launcherfails.id | notjson.id)
        printf '{"schema":"settings-map-export","version":1,"entries":[{"id":"%s"}]}' "$1" >"$2" ;;
      structural.id) echo "✘ Test recorded an issue: $1 is a structural Settings Map node; it has no vocabulary" >"$3"; return 65 ;;
      wrongentry.id) printf '{"schema":"settings-map-export","version":1,"entries":[{"id":"other"}]}' >"$2" ;;
      *) echo "✘ Test recorded an issue: $1 is not a searchable Settings Map id (unknown, renamed or exempt)" >"$3"; return 65 ;;
    esac
  }
  # Launcher stub: records what it was given, then answers per id.
  stub_launch() {
    cat >"$scratch/stdin.txt"
    ls -A "$1" >"$scratch/workcontents.txt"
    ls -A "$2" >"$scratch/home.txt"
    (cd "$1" && git rev-parse --git-dir >/dev/null 2>&1) && echo inrepo >"$scratch/repo.txt" || echo outside >"$scratch/repo.txt"
    case "$(grep -o '"id":"[a-z.]*"' "$scratch/stdin.txt" | head -1)" in
      *launcherfails.id*) return 76 ;;
      *notjson.id*) echo "no json here" >"$3.last" ;;
      *) printf 'Draft:\n{"id":"good.id","blocks":[{"language":"en","words":[],"phrases":["p"]}]}\n' >"$3.last" ;;
    esac
  }

  check "usage: bad id" 2 "$(run 'bad id!')"
  check "unknown id refused before the model" 3 "$(run unknown.id)"
  check "unknown id: launcher never ran" "no" "$([ -e "$scratch/stdin.txt" ] && echo yes || echo no)"
  check "unknown id message" 1 "$(grep -c 'not a searchable Settings Map id' "$scratch/run.log")"
  check "structural id refused" 3 "$(run structural.id)"
  check "structural id message" 1 "$(grep -c 'structural Settings Map node' "$scratch/run.log")"
  check "export for another id refused" 3 "$(run wrongentry.id)"
  check "still no launch" "no" "$([ -e "$scratch/stdin.txt" ] && echo yes || echo no)"
  check "launcher failure stops" 4 "$(run launcherfails.id)"
  check "launcher failure: no draft" 0 "$(find "$DRAFTS_ROOT" -path '*launcherfails.id*' -name draft.json | wc -l | tr -d ' ')"
  check "non-JSON answer stops" 5 "$(run notjson.id)"
  check "good draft" 0 "$(run good.id)"
  local good
  good="$(find "$DRAFTS_ROOT" -maxdepth 1 -name 'good.id-*' | head -1)"
  check "draft written" yes "$([ -s "$good/draft.json" ] && echo yes || echo no)"
  check "receipt says UNREVIEWED" 1 "$(grep -c '^status: UNREVIEWED' "$good/receipt.txt")"
  check "receipt binds the answer" "$(sha "$good/answer.txt")" "$(sed -n 's/^answer sha256: //p' "$good/receipt.txt")"
  check "prompt is brief plus export only" "$(cat "$BRIEF" "$good/export.json" | shasum -a 256 | cut -d' ' -f1)" "$(sha "$scratch/stdin.txt")"
  check "CODEX_HOME held only the auth link" auth.json "$(cat "$scratch/home.txt")"
  check "Codex ran outside every repository" outside "$(cat "$scratch/repo.txt")"
  check "Codex ran in an empty folder" "" "$(cat "$scratch/workcontents.txt")"
  check "shipped resource and receipts untouched" "$before" "$(shipped_state)"
  local real_root="$DRAFTS_ROOT"
  : >"$scratch/not-a-folder"
  DRAFTS_ROOT="$scratch/not-a-folder/drafts"
  check "an unwritable draft folder stops the run" 2 "$(run good.id)"
  DRAFTS_ROOT="$real_root"
  check "no isolated folder is left behind" 0 "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ew-vocab-draft.*' -newer "$scratch/auth.json" | wc -l | tr -d ' ')"

  rm -rf "$scratch"
  echo "self-test: $passed passed, $failed failed"
  [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  "" | -h | --help) sed -n '2,8p' "$0"; exit 2 ;;
  *) [ $# -eq 1 ] || die 2 "one id only"; draft "$1" ;;
esac
