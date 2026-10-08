#!/usr/bin/env bash
# Switch the tracked git hooks in scripts/githooks on for this repository, check them, or
# switch them off (#3524). One shared, repository-local, RELATIVE setting covers every
# worktree, and each worktree runs its OWN copy of the hooks:
#   core.hooksPath=scripts/githooks
# This script is the only owner of that policy; callers run it and report its result.
#
# Usage:
#   install.sh              install; refuses a hook directory that exists and is not ours
#   install.sh --check      one line; exit 0 OK, 1 not installed (installable),
#                           3 cannot install here (foreign hooks, worktree override,
#                           no hook in this checkout), 2 could not tell
#   install.sh --ensure     for build and test entry points: silent when OK, installs when
#                           installable, one line otherwise; same exit statuses as --check
#   install.sh --uninstall  restore the setting recorded before the first install
#   install.sh --self-test
#
# The value from before the first install is kept once, never overwritten, in
# <git-common-dir>/ew-hookspath-previous: "unset", or "set" plus the exact value.
set -euo pipefail

WANT="scripts/githooks"
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PREVIOUS_NAME="ew-hookspath-previous"

COMMON=""          # absolute git common directory
LOCAL_STATE=""     # "set" or "unset": the repository-local value this script replaces
LOCAL_VALUE=""
REASON=""          # the one line --check prints

say() { echo "==> git hooks: $*" >&2; }

# capture <command...>: CAPTURED gets the command's output exactly, minus only the one
# newline git prints after a value, so a value's own trailing newlines survive (plain
# command substitution strips them all). Returns the command's status.
CAPTURED=""
capture() {
  local out rc
  if out="$("$@"; rc=$?; printf x; exit "$rc")"; then rc=0; else rc=$?; fi
  out="${out%x}"
  CAPTURED="${out%$'\n'}"
  return "$rc"
}

# Read the repository-local value. Returns 2 when git cannot answer.
read_local() {
  local rc
  if capture git -C "$ROOT" config --local --get core.hooksPath; then rc=0; else rc=$?; fi
  case "$rc" in
    (0) LOCAL_STATE="set"; LOCAL_VALUE="$CAPTURED" ;;
    (1) LOCAL_STATE="unset"; LOCAL_VALUE="" ;;
    (*) return 2 ;;
  esac
}

# Does the default hooks directory hold a hook that would stop running? Sample files are
# git's own templates and never run.
default_hooks_in_use() {
  local dir f
  dir="$COMMON/hooks"
  [ -d "$dir" ] || return 1
  for f in "$dir"/*; do
    [ -e "$f" ] || continue
    case "$f" in (*.sample) continue ;; esac
    [ -f "$f" ] && [ -x "$f" ] && return 0
  done
  return 1
}

# Decide this checkout's state. Sets REASON; returns the --check status.
classify() {
  local effective scope origin rest value rc hooks resolved
  capture git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir \
    || { REASON="could not tell: $ROOT is not readable as a git checkout"; return 2; }
  COMMON="$CAPTURED"
  read_local || { REASON="could not tell: git could not read the local core.hooksPath"; return 2; }
  if capture git -C "$ROOT" config --show-scope --show-origin --get core.hooksPath; then rc=0; else rc=$?; fi
  effective="$CAPTURED"
  case "$rc" in
    (0)
      scope="${effective%%$'\t'*}"; rest="${effective#*$'\t'}"
      origin="${rest%%$'\t'*}"; value="${rest#*$'\t'}" ;;
    (1) scope="none"; origin="none"; value="" ;;
    (*) REASON="could not tell: git could not read the effective core.hooksPath"; return 2 ;;
  esac
  capture git -C "$ROOT" rev-parse --git-path hooks \
    || { REASON="could not tell: git could not resolve the hooks directory"; return 2; }
  hooks="$CAPTURED"
  case "$hooks" in (/*) resolved="$hooks" ;; (*) resolved="$ROOT/$hooks" ;; esac
  resolved="${resolved%/}"

  if [ ! -f "$ROOT/$WANT/pre-push" ] || [ ! -x "$ROOT/$WANT/pre-push" ]; then
    REASON="NOT COVERED: this checkout has no executable $WANT/pre-push ($ROOT); CI remains the check"
    return 3
  fi
  if [ "$scope" = "local" ] && [ "$value" = "$WANT" ] && [ "$resolved" = "$ROOT/$WANT" ]; then
    REASON="OK (core.hooksPath=$WANT, $scope scope, $origin; $ROOT/$WANT/pre-push runs on push)"
    return 0
  fi
  case "$scope" in
    (worktree|command)
      REASON="CANNOT INSTALL: a $scope-scope core.hooksPath ($value, $origin) overrides the repository setting in $ROOT; remove it to use $WANT"
      return 3 ;;
  esac
  if [ "$scope" = "none" ]; then
    if default_hooks_in_use; then
      REASON="CANNOT INSTALL: $COMMON/hooks holds hooks that would stop running; move them or set core.hooksPath yourself"
      return 3
    fi
    REASON="NOT INSTALLED (core.hooksPath is unset)"
    return 1
  fi
  if [ "$resolved" = "$ROOT/$WANT" ]; then
    REASON="NOT INSTALLED (core.hooksPath=$value comes from $scope scope, $origin, not the repository's own config)"
    return 1
  fi
  if [ -d "$resolved" ]; then
    REASON="CANNOT INSTALL: core.hooksPath ($scope scope, $origin) names an existing hook directory that is not ours: $resolved"
    return 3
  fi
  REASON="NOT INSTALLED (core.hooksPath=$value from $scope scope, $origin, names a missing directory)"
  return 1
}

# Read the record of the value from before the first install. Sets RECORD_KIND ("set" or
# "unset") and RECORD_VALUE. Returns 0 for a valid record, 1 when there is none, 2 when
# one exists but cannot be read or is not exactly one of the two forms.
RECORD_KIND=""
RECORD_VALUE=""
read_record() {
  local final content
  final="$COMMON/$PREVIOUS_NAME"
  RECORD_KIND=""; RECORD_VALUE=""
  [ -e "$final" ] || [ -L "$final" ] || return 1
  [ -f "$final" ] && [ ! -L "$final" ] || return 2
  # The trailing x keeps a value's own trailing newlines through command substitution.
  content="$(cat "$final" && printf x)" || return 2
  content="${content%x}"
  if [ "$content" = $'unset\n' ]; then
    RECORD_KIND="unset"
  elif [ "${content%%$'\n'*}" = "set" ] && [ "$content" != "set" ]; then
    RECORD_KIND="set"; RECORD_VALUE="${content#set$'\n'}"
  else
    return 2
  fi
}

# Keep the value from before the first install, once. Writes a complete temp file, then
# publishes it with link(2), which never overwrites, so a repeated or concurrent install
# keeps the first. Returns 0 only when a valid record exists afterwards; an existing record
# that cannot be read or is malformed returns 2 and nothing is written.
record_previous() {
  local final tmp rc
  final="$COMMON/$PREVIOUS_NAME"
  if read_record; then return 0; else rc=$?; fi
  [ "$rc" -eq 1 ] || return 2
  tmp="$(mktemp "$COMMON/$PREVIOUS_NAME.XXXXXX")" || return 2
  if [ "$LOCAL_STATE" = "set" ]; then
    printf 'set\n%s' "$LOCAL_VALUE" > "$tmp" || { rm -f "$tmp"; return 2; }
  else
    printf 'unset\n' > "$tmp" || { rm -f "$tmp"; return 2; }
  fi
  if ln "$tmp" "$final" 2> /dev/null; then :; fi
  rm -f "$tmp"
  # Whoever published first, the record must now read back as valid.
  read_record || return 2
}

check() {
  local rc
  if classify; then rc=0; else rc=$?; fi
  say "$REASON"
  return "$rc"
}

# install [quiet]: quiet prints nothing when already OK.
install() {
  local rc
  if classify; then rc=0; else rc=$?; fi
  case "$rc" in
    (0) [ "${1:-}" = "quiet" ] || say "$REASON"; return 0 ;;
    (1) ;;
    (*) say "$REASON"; return "$rc" ;;
  esac
  record_previous || { say "could not tell: the record of the previous core.hooksPath ($COMMON/$PREVIOUS_NAME) could not be written or read; nothing changed"; return 2; }
  git -C "$ROOT" config --local core.hooksPath "$WANT" || { say "could not write core.hooksPath"; return 2; }
  if classify; then rc=0; else rc=$?; fi
  if [ "$rc" -eq 0 ]; then
    say "installed: $REASON. Undo: $WANT/install.sh --uninstall"
    return 0
  fi
  say "installed, but the check still reads: $REASON"
  return "$rc"
}

uninstall() {
  local final rc
  capture git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir || { say "could not tell: not a git checkout"; return 2; }
  COMMON="$CAPTURED"
  read_local || { say "could not tell: git could not read the local core.hooksPath"; return 2; }
  final="$COMMON/$PREVIOUS_NAME"
  if [ "$LOCAL_STATE" != "set" ] || [ "$LOCAL_VALUE" != "$WANT" ]; then
    say "not installed in the local config; nothing changed"
    return 0
  fi
  if read_record; then rc=0; else rc=$?; fi
  case "$rc" in
    (0) ;;
    (1) RECORD_KIND="unset" ;; # installed with no record: the setting did not exist before
    (*) say "could not tell: $final cannot be read or is malformed; nothing changed"; return 2 ;;
  esac
  case "$RECORD_KIND" in
    (set)
      git -C "$ROOT" config --local core.hooksPath "$RECORD_VALUE" || return 2
      say "uninstalled: core.hooksPath restored to $RECORD_VALUE" ;;
    (unset)
      git -C "$ROOT" config --local --unset-all core.hooksPath || return 2
      say "uninstalled: core.hooksPath unset, as before" ;;
  esac
  rm -f "$final"
}

self_test() {
  local tmp fails=0 cases=0 rc repo script n pids
  set +e
  script="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
  tmp="$(cd "$(mktemp -d)" && pwd -P)"
  # Isolate from the real global and system git configuration.
  : > "$tmp/global-config"
  export GIT_CONFIG_GLOBAL="$tmp/global-config" GIT_CONFIG_NOSYSTEM=1

  ok() { # ok <label> <actual> <expected>
    cases=$((cases + 1))
    if [ "$2" = "$3" ]; then echo "ok    $1"; else echo "FAIL  $1: got [$2] want [$3]"; fails=$((fails + 1)); fi
  }
  # fresh <name>: an owned repository with this installer and a hook, path with a space
  fresh() {
    repo="$tmp/$1 repo"
    git init --quiet -b main "$repo"
    git -C "$repo" config user.email self-test@example.invalid
    git -C "$repo" config user.name self-test
    mkdir -p "$repo/scripts/githooks"
    cp "$script" "$repo/scripts/githooks/install.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/githooks/pre-push"
    chmod +x "$repo/scripts/githooks/install.sh" "$repo/scripts/githooks/pre-push"
    git -C "$repo" add -A
    git -C "$repo" commit --quiet -m base
  }
  # The copy runs under the same bash as this self-test, so both versions are exercised.
  run() { "$BASH" "$repo/scripts/githooks/install.sh" "$@" > "$tmp/out" 2>&1; }
  prev() { cat "$repo/.git/$PREVIOUS_NAME" 2> /dev/null || echo "<none>"; }
  local_value() { git -C "$repo" config --local --get core.hooksPath || echo "<unset>"; }

  # 1. unset: installs, records "unset", checks OK
  fresh unset
  run; rc=$?
  ok "unset: installs and records unset" "$rc|$(local_value)|$(prev)" "0|$WANT|unset"
  run --check; rc=$?
  ok "unset: --check reads OK afterwards" "$rc|$(grep -c '^==> git hooks: OK' "$tmp/out")" "0|1"

  # 2. a stale absolute path to a missing directory (the Desktop case) is replaced and kept exactly
  fresh stale
  git -C "$repo" config core.hooksPath "$tmp/Desktop/EnviousWispr/.git/hooks"
  run --check; rc=$?
  ok "stale path: --check reads NOT INSTALLED" "$rc" "1"
  run; rc=$?
  ok "stale path: installs and records the exact old value" "$rc|$(local_value)|$(prev)" "0|$WANT|set
$tmp/Desktop/EnviousWispr/.git/hooks"

  # 3. a repeated install never overwrites the first record
  git -C "$repo" config core.hooksPath "$tmp/elsewhere-missing"
  run; rc=$?
  ok "repeat: second install keeps the first record" "$rc|$(prev)" "0|set
$tmp/Desktop/EnviousWispr/.git/hooks"

  # 4. concurrent installs from one original keep that original (10 rounds of 4)
  local round bad=0
  for round in 1 2 3 4 5 6 7 8 9 10; do
    fresh "race$round"
    git -C "$repo" config core.hooksPath "$tmp/missing $round"
    pids=""
    for n in 1 2 3 4; do "$BASH" "$repo/scripts/githooks/install.sh" > "$tmp/race.$n" 2>&1 & pids="$pids $!"; done
    # shellcheck disable=SC2086 # a list of PIDs
    wait $pids
    [ "$(prev)" = "set
$tmp/missing $round" ] && [ "$(local_value)" = "$WANT" ] || bad=$((bad + 1))
  done
  ok "concurrent: every round keeps the original value" "$bad" "0"

  # 5. an existing foreign directory is refused and left untouched
  fresh foreign
  mkdir -p "$tmp/husky"
  git -C "$repo" config core.hooksPath "$tmp/husky"
  run; rc=$?
  ok "foreign directory: refused, nothing changed" "$rc|$(local_value)|$(prev)|$(grep -c 'CANNOT INSTALL' "$tmp/out")" "3|$tmp/husky|<none>|1"

  # 6. relative values resolve against the checkout: existing is foreign, missing is replaced,
  #    and an empty value (git reads it as the checkout root) is foreign
  fresh relative
  mkdir -p "$repo/.husky"
  git -C "$repo" config core.hooksPath ".husky"
  run --check; rc=$?
  ok "relative existing directory: foreign" "$rc" "3"
  git -C "$repo" config core.hooksPath "gone/hooks"
  run; rc=$?
  ok "relative missing directory: replaced and recorded" "$rc|$(prev)" "0|set
gone/hooks"
  fresh empty
  git -C "$repo" config core.hooksPath ""
  run; rc=$?
  ok "empty value: foreign, nothing changed" "$rc|$(local_value)|$(prev)" "3||<none>"

  # 7. live hooks in the default directory are not silently switched off
  fresh default-live
  printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-commit"; chmod +x "$repo/.git/hooks/pre-commit"
  run; rc=$?
  ok "unset with live default hooks: refused" "$rc|$(local_value)" "3|<unset>"

  # 8. a worktree-specific override is reported, and the shared OK in the main checkout does
  #    not make the worktree OK
  fresh override
  run > /dev/null 2>&1
  git -C "$repo" config extensions.worktreeConfig true
  git -C "$repo" worktree add --quiet --detach "$tmp/override wt" HEAD
  git -C "$tmp/override wt" config --worktree core.hooksPath "$tmp/wt-hooks"
  "$BASH" "$tmp/override wt/scripts/githooks/install.sh" --check > "$tmp/out" 2>&1; rc=$?
  ok "worktree override: CANNOT INSTALL naming the worktree config file" "$rc|$(grep -c 'worktree-scope core.hooksPath .*config.worktree' "$tmp/out")" "3|1"
  run --check; rc=$?
  ok "worktree override: the main checkout still reads OK" "$rc" "0"
  git -C "$tmp/override wt" config --worktree --unset core.hooksPath
  "$BASH" "$tmp/override wt/scripts/githooks/install.sh" --check > "$tmp/out" 2>&1; rc=$?
  ok "a plain worktree shares the installed setting and reads OK" "$rc" "0"

  # 9. a missing or non-executable hook in the calling checkout is never OK
  chmod -x "$repo/scripts/githooks/pre-push"
  run --check; rc=$?
  ok "non-executable pre-push: NOT COVERED" "$rc|$(grep -c 'NOT COVERED' "$tmp/out")" "3|1"
  rm -f "$repo/scripts/githooks/pre-push"
  run --check; rc=$?
  ok "missing pre-push: NOT COVERED" "$rc" "3"

  # 10. uninstall restores a recorded value exactly, and removes the record
  fresh restore-set
  git -C "$repo" config core.hooksPath "$tmp/old path/hooks"
  run > /dev/null 2>&1
  run --uninstall; rc=$?
  ok "uninstall restores a recorded value" "$rc|$(local_value)|$(prev)" "0|$tmp/old path/hooks|<none>"

  # 11. uninstall restores "unset", and leaves unrelated settings alone
  fresh restore-unset
  git -C "$repo" config core.editor "self-test-editor"
  run > /dev/null 2>&1
  run --uninstall; rc=$?
  ok "uninstall restores unset and keeps other settings" "$rc|$(local_value)|$(git -C "$repo" config --get core.editor)" "0|<unset>|self-test-editor"
  run --uninstall; rc=$?
  ok "uninstall when not installed changes nothing" "$rc|$(local_value)" "0|<unset>"

  # 12. --ensure: silent when OK, installs when missing, reports and returns 3 when foreign
  fresh ensure
  run --ensure; rc=$?
  ok "ensure installs when missing" "$rc|$(local_value)|$(grep -c 'installed' "$tmp/out")" "0|$WANT|1"
  run --ensure; rc=$?
  ok "ensure is silent when already OK" "$rc|$(wc -c < "$tmp/out" | tr -d ' ')" "0|0"
  git -C "$repo" config core.hooksPath "$tmp/husky"
  run --ensure; rc=$?
  ok "ensure reports a foreign directory and changes nothing" "$rc|$(local_value)" "3|$tmp/husky"

  # 13. our value set only in global config is not the repository's install: installable,
  #     and installing records the unset local value
  fresh global-only
  git config --global core.hooksPath "$WANT"
  run --check; rc=$?
  ok "global-only value: NOT INSTALLED, not OK" "$rc" "1"
  run; rc=$?
  ok "global-only value: install writes the local setting" "$rc|$(local_value)|$(prev)" "0|$WANT|unset"
  git config --global --unset core.hooksPath

  # 14. the OK line names the effective scope and the config file it came from
  fresh origin
  run > /dev/null 2>&1
  run --check; rc=$?
  ok "OK names local scope and its config file" "$rc|$(grep -c 'local scope, file:.git/config' "$tmp/out")" "0|1"

  # 15-18. a record that cannot be written, read or trusted never authorises a config write
  fresh unwritable
  git -C "$repo" config core.hooksPath "$tmp/gone"
  chmod 555 "$repo/.git"
  run; rc=$?
  chmod 755 "$repo/.git"
  ok "record cannot be written: could not tell, config unchanged" "$rc|$(local_value)|$(prev)" "2|$tmp/gone|<none>"
  local bad_record label
  for bad_record in directory garbage unreadable; do
    fresh "bad-$bad_record"
    git -C "$repo" config core.hooksPath "$tmp/gone"
    case "$bad_record" in
      (directory) mkdir "$repo/.git/$PREVIOUS_NAME" ;;
      (garbage) printf 'maybe\n%s' "$tmp/x" > "$repo/.git/$PREVIOUS_NAME" ;;
      (unreadable) printf 'unset\n' > "$repo/.git/$PREVIOUS_NAME"; chmod 000 "$repo/.git/$PREVIOUS_NAME" ;;
    esac
    run; rc=$?
    label="$(local_value)"
    chmod 644 "$repo/.git/$PREVIOUS_NAME" 2> /dev/null
    ok "existing $bad_record record: install could not tell, config unchanged" "$rc|$label" "2|$tmp/gone"
  done
  # uninstall with a corrupt record leaves our setting in place
  fresh bad-uninstall
  run > /dev/null 2>&1
  printf 'set' > "$repo/.git/$PREVIOUS_NAME"
  run --uninstall; rc=$?
  ok "corrupt record: uninstall could not tell, config unchanged" "$rc|$(local_value)" "2|$WANT"

  # 20-23. values with a trailing newline, a tab or spaces survive read, record and
  #        uninstall byte for byte (compared through git's own NUL-terminated output),
  #        and a foreign directory whose name ends in a newline stays protected
  local odd
  for odd in "$tmp/nl dir"$'\n' "$tmp/tab"$'\t'"dir"; do
    fresh "odd$((cases))"
    git -C "$repo" config core.hooksPath "$odd"
    printf '%s\0' "$odd" > "$tmp/want"
    run; rc=$?
    printf 'set\n%s' "$odd" > "$tmp/want-record"
    cmp -s "$tmp/want-record" "$repo/.git/$PREVIOUS_NAME"; local record_rc=$?
    run --uninstall
    git -C "$repo" config --local --null --get core.hooksPath > "$tmp/got"
    cmp -s "$tmp/want" "$tmp/got"; local restore_rc=$?
    ok "odd value round trip: $(printf '%q' "$odd" | sed "s|$tmp|TMP|")" "$rc|$record_rc|$restore_rc" "0|0|0"
  done
  fresh foreign-nl
  mkdir "$tmp/foreign"$'\n'
  git -C "$repo" config core.hooksPath "$tmp/foreign"$'\n'
  run; rc=$?
  git -C "$repo" config --local --null --get core.hooksPath > "$tmp/got"
  printf '%s\0' "$tmp/foreign"$'\n' > "$tmp/want"
  cmp -s "$tmp/want" "$tmp/got"; local kept_rc=$?
  ok "a foreign directory whose name ends in a newline is refused, untouched" "$rc|$kept_rc|$(prev)" "3|0|<none>"

  # 24. git cannot answer: could not tell, never OK
  fresh broken
  run > /dev/null 2>&1
  printf '[core\n' >> "$repo/.git/config"
  run --check; rc=$?
  ok "an unreadable config is could-not-tell" "$rc|$(grep -c 'could not tell' "$tmp/out")" "2|1"

  rm -rf "$tmp"
  echo "self-test: $cases cases, $fails failure(s)"
  [ "$fails" -eq 0 ]
}

case "${1:-}" in
  ("") install ;;
  (--check) check ;;
  (--ensure) install quiet ;;
  (--uninstall) uninstall ;;
  (--self-test) self_test ;;
  (*) echo "usage: $0 [--check|--ensure|--uninstall|--self-test]" >&2; exit 2 ;;
esac
