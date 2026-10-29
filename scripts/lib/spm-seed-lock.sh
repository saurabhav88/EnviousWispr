#!/usr/bin/env bash
# scripts/lib/spm-seed-lock.sh — the ONE owner of the SwiftPM seed-snapshot lock
# protocol (#2157 chunk A). Sourced by `scripts/build-dev-app.sh`,
# `scripts/xcode-test.sh`, and `.claude/scripts/purge-derived-data.sh`.
#
# WHAT IS PROTECTED
# `~/Library/Caches/EnviousWispr/spm-seed/<key>/SourcePackages` — an immutable,
# fully-resolved SwiftPM tree, cloned into a fresh DerivedData with APFS
# copy-on-write. Measured 2026-08-18: 46.5 s to resolve from scratch versus 1.9 s
# to clone plus 9.0 s to validate.
#
# THREE PARTIES, ONE PROTOCOL
# Publisher, consumer and purger all touch a key. Giving each its own rule is how
# a purge deletes a snapshot out from under a clone. They share this file.
#
# THE PROTOCOL VERSION IS NOT DECORATION — READ THIS BEFORE CHANGING THE FORMAT
# `scripts/` is TRACKED, so this file exists in EVERY checkout, and there are
# routinely ten checkouts at ten different commits, all coordinating through ONE
# machine-global directory. "Single owner" is true in the repo and FALSE at
# runtime. A format change is therefore NOT atomic: an older worktree's copy can
# meet a newer lock. Every lock records `EW_SEED_LOCK_VERSION`, and a reader that
# does not implement the version it finds FAILS CLOSED — treats the key as busy,
# never assumes compatibility, never upgrades a lock it did not write, never
# reclaims one it cannot parse. Bump the version for any on-disk shape change.
#
# WHY mkdir AND NOT flock
# `mkdir` is an atomic test-and-set on every filesystem here and leaves an
# inspectable directory for the ownership record. `flock` would need a companion
# file and an open descriptor held across the entire clone.
#
# FAILURE PHILOSOPHY: every path fails toward DOING THE WORK. A lock we cannot
# take, parse, or trust is a CACHE MISS — the caller resolves packages normally
# and the build succeeds, just slower. Nothing here may ever fail a build.
#
# Public result variables are read by sourced callers.
# shellcheck disable=SC2034
# Portability: written for bash 3.2 (`/bin/bash` on macOS), because
# `#!/usr/bin/env bash` finds Homebrew's bash 5 here but not everywhere.

# #4197 adds only an in-memory ABI. Persisted key-owner records remain v1.
# Fresh startup resolves its own path but runs no metadata/dependency probe.
if declare -F _ew_seed_guard_source >/dev/null 2>&1; then
    if _ew_seed_guard_source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" 2; then :; else return 2; fi
elif [ -n "${EW_SEED_HELD_LOCKS[*]-}" ] || [ -n "${EW_SEED_TEMP_DIRS[*]-}" ] || [ "${EW_SEED_CONSUMED:-0}" != 0 ] || [ "${_EW_SEED_NEXT:-0}" != 0 ]; then
    echo 'seed-lock: active state from an incompatible source; original cleanup retained' >&2
    return 2
fi
_ew_seed_loading_origin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2
if [ "${_EW_SEED_ABI:-}" != 2 ] || [ "${_EW_SEED_ORIGIN:-}" != "$_ew_seed_loading_origin" ]; then
    _EW_SEED_ABI=2
    _EW_SEED_ORIGIN="$_ew_seed_loading_origin"
    _EW_SEED_HELPER="$_EW_SEED_ORIGIN/remove-tree.py"
    _EW_SEED_NEXT=0
    _EW_SEED_OWNER_DEPTH="${BASH_SUBSHELL:-0}"
    _EW_SEED_CAPTURED_ROOT=''
    _EW_SEED_CAPTURED_ROOT_ID=''
    _EW_SEED_R_KIND=(); _EW_SEED_R_ORIGIN=(); _EW_SEED_R_ROOT=()
    _EW_SEED_R_ROOT_ID=(); _EW_SEED_R_REMOVE_ROOT=(); _EW_SEED_R_REMOVE_ID=()
    _EW_SEED_R_KEY=(); _EW_SEED_R_PATH=(); _EW_SEED_R_PHASE=()
    _EW_SEED_R_LOCK=(); _EW_SEED_R_IDENT=(); _EW_SEED_R_OWNER=()
    _EW_SEED_FRAME=0
    _EW_SEED_MUTATED=0
    _EW_SEED_WAS_RETAINED=0
    _EW_SEED_UNRESOLVED_TEMP=0
    EW_SEED_CLEANUP_COMPLETE=1
    EW_SEED_REMOVE_OUTCOME=absent
fi
EW_SEED_LOCK_VERSION=1
EW_SEED_ROOT="${EW_SEED_ROOT:-$HOME/Library/Caches/EnviousWispr/spm-seed}"
EW_SEED_LOCK_RECLAIM_AGE_MIN="${EW_SEED_LOCK_RECLAIM_AGE_MIN:-60}"

_ew_seed_warn() { printf 'seed-lock: %s\n' "$*" >&2; }

_ew_seed_active() {
    local n=1
    while [ "$n" -le "${_EW_SEED_NEXT:-0}" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" != "done" ]; then return 0; fi
        n=$((n + 1))
    done
    [ "${EW_SEED_CONSUMED:-0}" = 1 ]
}

_ew_seed_guard_source() {
    local incoming="$1" abi="$2"
    if _ew_seed_active; then
        if [ "${_EW_SEED_ABI:-}" != "$abi" ] || [ "${_EW_SEED_ORIGIN:-}" != "$incoming" ]; then
            _ew_seed_warn 'active source/ABI cannot be replaced; finish the original owner first'
            return 2
        fi
    fi
    return 0
}

_ew_seed_depth() {
    # Real build/purge callers invoke mutating APIs directly. In a subshell $$
    # still names its parent; minting a v1 lease there could outlive that parent
    # or inherit authority to its records. Unsupported subshell mutation is a
    # cache miss, not a new wire format. Read-only queries may still be captured.
    local depth="${BASH_SUBSHELL:-0}"
    if [ "$depth" != 0 ]; then
        _ew_seed_warn 'subshell mutation cannot own a v1 lease; cache miss'
        return 1
    fi
    if _ew_seed_active; then
        if [ "$_EW_SEED_OWNER_DEPTH" != "$depth" ]; then
            _ew_seed_warn 'inherited active registry belongs to another shell realm; cache miss'
            return 1
        fi
    else
        _EW_SEED_OWNER_DEPTH="$depth"
    fi
    return 0
}

_ew_seed_valid_key() {
    # Both real producers yield nonhidden components (hashes or prune entries).
    # Hidden names belong to metadata, even if a caller enabled dotglob.
    case "${1:-}" in ''|.*|*/*) _ew_seed_warn 'invalid key or reserved metadata namespace'; return 1 ;; esac
    return 0
}

_ew_seed_live() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ] && [ "$1" -le "$_EW_SEED_NEXT" ] && [ "${_EW_SEED_R_KIND[$1]:-done}" != "done" ]
}

_ew_seed_add() {
    _EW_SEED_NEXT=$((_EW_SEED_NEXT + 1))
    local n="$_EW_SEED_NEXT"
    _EW_SEED_R_KIND[$n]="$1"; _EW_SEED_R_ORIGIN[$n]="$2"
    _EW_SEED_R_ROOT[$n]="$3"; _EW_SEED_R_REMOVE_ROOT[$n]="$4"
    _EW_SEED_R_KEY[$n]="$5"; _EW_SEED_R_PATH[$n]="$6"
    _EW_SEED_R_PHASE[$n]="$7"; _EW_SEED_R_LOCK[$n]="${8:-0}"
    _EW_SEED_R_IDENT[$n]="${9:-}"; _EW_SEED_R_OWNER[$n]="${10:-}"
    _EW_SEED_R_ROOT_ID[$n]="${11:-}"; _EW_SEED_R_REMOVE_ID[$n]="${12:-}"
    _EW_SEED_NEW_RECORD="$n"
}

_ew_seed_done() {
    local n="$1"
    _EW_SEED_R_KIND[$n]="done"; _EW_SEED_R_PHASE[$n]=complete
    _EW_SEED_R_PATH[$n]=''; _EW_SEED_R_OWNER[$n]=''
    _EW_SEED_R_ROOT[$n]=''; _EW_SEED_R_REMOVE_ROOT[$n]=''
    _EW_SEED_R_KEY[$n]=''; _EW_SEED_R_LOCK[$n]=0
}

_ew_seed_count_kind() {
    local kind="$1" n=1 count=0
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = "$kind" ]; then count=$((count + 1)); fi
        n=$((n + 1))
    done
    printf '%s\n' "$count"
}

_ew_seed_find_lock() {
    local key="$1" n=1
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = lock ] && [ "${_EW_SEED_R_KEY[$n]:-}" = "$key" ]; then
            printf '%s\n' "$n"; return 0
        fi
        n=$((n + 1))
    done
    return 1
}

_ew_seed_find_gate() {
    local root="$1" key="$2" n=1
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = gate ] && [ "${_EW_SEED_R_ROOT[$n]:-}" = "$root" ] && [ "${_EW_SEED_R_KEY[$n]:-}" = "$key" ]; then
            printf '%s\n' "$n"; return 0
        fi
        n=$((n + 1))
    done
    return 1
}

_ew_seed_find_temp() {
    local lock="$1" path="$2" n=1
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = temp ] && [ "${_EW_SEED_R_LOCK[$n]:-0}" = "$lock" ] && [ "${_EW_SEED_R_PATH[$n]:-}" = "$path" ]; then
            printf '%s\n' "$n"; return 0
        fi
        n=$((n + 1))
    done
    return 1
}

_ew_seed_observe() {
    local root="$1" target="$2" expected="${3:-}" command="${4:-inspect}" out rc packet extra
    _EW_SEED_OBS_ID=''; _EW_SEED_OBS_ROOT_ID=''; _EW_SEED_OBS_EXISTS=''; _EW_SEED_OBS_OWNER=''
    if [ "$command" = owner ] && [ -n "$expected" ]; then
        if out="$(python3 "$_EW_SEED_HELPER" owner "$root" "$target" "$expected")"; then rc=0; else rc=$?; fi
    else
        if out="$(python3 "$_EW_SEED_HELPER" "$command" "$root" "$target")"; then rc=0; else rc=$?; fi
    fi
    case "$rc" in 0|3) ;; *) _ew_seed_warn "could not inspect $target; retained"; return 1 ;; esac
    if ! packet="$(python3 -c 'import base64,json,os,sys
x=json.loads(sys.argv[1]); rc=int(sys.argv[2]); command=sys.argv[3]
assert type(x) is dict and x["root"]==os.path.normpath(sys.argv[4]) and x["target"]==os.path.normpath(sys.argv[5])
def ident(v):
 assert type(v) is str
 p=v.split(":"); assert len(p)==2 and all(s and s.isascii() and s.isdecimal() for s in p)
 assert v=="{}:{}".format(int(p[0]),int(p[1])); return v
assert type(x["exists"]) is bool and (rc==3)==(not x["exists"])
r=ident(x["root_identity"]); i=ident(x["identity"]) if x["exists"] else "-"; owner="m"
if command=="owner" and x["exists"]:
 assert type(x["owner_exists"]) is bool
 if x["owner_exists"]:
  b=x["owner_base64"]; assert type(b) is str and b.isascii(); base64.b64decode(b,validate=True); owner="p:"+b
print(r,i,"1" if x["exists"] else "0",owner)' "$out" "$rc" "$command" "$root" "$target")"; then
        _ew_seed_warn "incomplete metadata for $target; retained"; return 1
    fi
    if IFS=' ' read -r _EW_SEED_OBS_ROOT_ID _EW_SEED_OBS_ID _EW_SEED_OBS_EXISTS _EW_SEED_OBS_OWNER extra <<< "$packet"; then :; else return 1; fi
    if [ -n "$extra" ]; then return 1; fi
    if [ "$_EW_SEED_OBS_EXISTS" = 1 ] && [ -n "$expected" ] && [ "$_EW_SEED_OBS_ID" != "$expected" ]; then
        _ew_seed_warn "observed replacement at $target; retained"; return 1
    fi
    return "$rc"
}

_ew_seed_namespace() {
    local path="$1" out packet exists ident extra
    if out="$(python3 "$_EW_SEED_HELPER" inspect "$path")"; then :; else return 1; fi
    if ! packet="$(python3 -c 'import json,os,sys
x=json.loads(sys.argv[1]); assert type(x) is dict and x["root"]==os.path.normpath(sys.argv[2]) and type(x["exists"]) is bool
if x["exists"]:
 v=x["identity"]; p=v.split(":"); assert len(p)==2 and all(s and s.isascii() and s.isdecimal() for s in p); print("1",v)
else:
 assert type(x["creation_parent"]) is str and os.path.isabs(x["creation_parent"])
 v=x["parent_identity"]; p=v.split(":"); assert len(p)==2 and all(s and s.isascii() and s.isdecimal() for s in p); print("0",v)' "$out" "$path")"; then return 1; fi
    if IFS=' ' read -r exists ident extra <<< "$packet"; then :; else return 1; fi
    [ -z "$extra" ] || return 1
    _EW_SEED_NS_EXISTS="$exists"; _EW_SEED_NS_IDENT="$ident"
    return 0
}

# Operational namespace work happens after caller cleanup traps are installed.
ew_seed_prepare_namespace() {
    local path="$1"
    if ! _ew_seed_depth || ! _ew_seed_namespace "$path"; then return 1; fi
    if [ "$_EW_SEED_NS_EXISTS" = 0 ]; then
        if mkdir -p -- "$path"; then :; else _ew_seed_warn "cannot prepare $path; cache miss"; return 1; fi
        if ! _ew_seed_namespace "$path" || [ "$_EW_SEED_NS_EXISTS" != 1 ]; then return 1; fi
    fi
    return 0
}

_ew_seed_select_root() {
    if ! _ew_seed_depth; then return 1; fi
    if _ew_seed_active && [ -n "$_EW_SEED_CAPTURED_ROOT" ] && [ "$_EW_SEED_CAPTURED_ROOT" != "$EW_SEED_ROOT" ]; then
        _ew_seed_warn 'root changed with active ownership/provenance; cache miss'; return 1
    fi
    if ! ew_seed_prepare_namespace "$EW_SEED_ROOT"; then return 1; fi
    if _ew_seed_active && [ -n "$_EW_SEED_CAPTURED_ROOT_ID" ] && [ "$_EW_SEED_CAPTURED_ROOT_ID" != "$_EW_SEED_NS_IDENT" ]; then
        _ew_seed_warn 'seed namespace identity changed; cache miss'; return 1
    fi
    _EW_SEED_CAPTURED_ROOT="$EW_SEED_ROOT"; _EW_SEED_CAPTURED_ROOT_ID="$_EW_SEED_NS_IDENT"
    return 0
}

_ew_seed_ensure_child() {
    local root="$1" child="$2" rc
    if _ew_seed_observe "$root" "$child"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) return 0 ;;
        3) if mkdir -- "$child" 2>/dev/null; then :; fi
           if _ew_seed_observe "$root" "$child"; then return 0; fi ;;
    esac
    _ew_seed_warn "unsafe/unavailable namespace $child; cache miss"
    return 1
}

_ew_seed_b64() { python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode("utf-8")).decode("ascii"))' "$1"; }

_ew_seed_owner_values() {
    local token="$1" packet extra
    _EW_SEED_OWNER_VERSION=''; _EW_SEED_OWNER_PID=''; _EW_SEED_OWNER_STARTED=''
    case "$token" in p:*) ;; *) return 1 ;; esac
    if ! packet="$(python3 -c 'import base64,sys
raw=base64.b64decode(sys.argv[1],validate=True); text=raw.decode("utf-8")
assert "\x00" not in text and "\r" not in text
lines=text.splitlines(); assert len(lines)==3
parts=[line.partition("=") for line in lines]; assert all(p[1] for p in parts)
x={p[0]:p[2] for p in parts}; assert len(x)==3 and set(x)=={"version","pid","started"}
assert x["version"] and x["version"].isascii() and x["version"].isdecimal()
assert x["pid"] and x["pid"].isascii() and x["pid"].isdecimal() and int(x["pid"])>0
assert x["started"]
print(x["version"],x["pid"],base64.b64encode(x["started"].encode()).decode())' "${token#p:}")"; then return 1; fi
    if IFS=' ' read -r _EW_SEED_OWNER_VERSION _EW_SEED_OWNER_PID _EW_SEED_OWNER_STARTED extra <<< "$packet"; then :; else return 1; fi
    [ -z "$extra" ]
}

# Retained v1 process-identity rationale and implementation. Its second-resolution
# timestamp is not a kernel generation token; the wire format is unchanged.
# --- ownership identity ------------------------------------------------------
# A PID alone is not an identity: PIDs are recycled, so an aged lock whose PID was
# reused looks alive, and one whose PID is gone might be a different process with
# the same number. Pair it with the process START TIME, which no recycled PID
# reproduces. Verified available on macOS 2026-08-18.
# Returns THREE states, not two, and that distinction is the whole point:
#   0 + identity on stdout -> the process exists
#   1                      -> it PROVABLY does not
#   2                      -> we could not tell, because `ps` itself failed
# The previous version printed the identity and let an empty string mean "gone".
# An empty string is ALSO what a missing or failing `/bin/ps` produces, and the
# caller's comment said "provably dead" — a certainty the code could not deliver.
# Reclaiming on that reading takes the lock from a LIVE owner, which is the
# grant-too-often direction: two writers on one snapshot, or a purge deleting a
# tree mid-clone. Measured on macOS 2026-08-18: live pid rc=0, dead pid rc=1 and
# empty, missing binary rc=127 and empty.
# The absolute path is a variable ONLY so the "the tool itself failed" state
# can be reached in a test. Nothing sets it in production. A state that cannot
# be reached from a test is a state nobody has checked, and this is the one
# whose misreading is silent: it takes a live owner's lock.
EW_SEED_PS="${EW_SEED_PS:-/bin/ps}"
ew_seed_process_identity() {
  local out rc
  out="$(LC_ALL=C "$EW_SEED_PS" -o lstart= -p "$1" 2>/dev/null)"; rc=$?
  out="$(printf '%s' "$out" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [ "$rc" -eq 1 ] && [ -z "$out" ]; then
    return 1
  fi
  return 2
}


_ew_seed_owner_abandoned() {
    local token="$1" current rc encoded
    if ! _ew_seed_owner_values "$token"; then _ew_seed_warn 'malformed owner record; leaving it alone'; return 1; fi
    if [ "$_EW_SEED_OWNER_VERSION" != "$EW_SEED_LOCK_VERSION" ]; then
        _ew_seed_warn "held by unknown protocol version '$_EW_SEED_OWNER_VERSION'; leaving it alone"; return 1
    fi
    if current="$(ew_seed_process_identity "$_EW_SEED_OWNER_PID")"; then rc=0; else rc=$?; fi
    case "$rc" in
        1) return 0 ;;
        2) _ew_seed_warn "could not determine whether pid $_EW_SEED_OWNER_PID is alive; leaving it alone"; return 1 ;;
    esac
    if encoded="$(_ew_seed_b64 "$current")"; then :; else return 1; fi
    [ "$encoded" != "$_EW_SEED_OWNER_STARTED" ]
}

_ew_seed_age() {
    local path="$1" minutes="$2" out
    case "$minutes" in ''|*[!0-9]*) _ew_seed_warn 'age probe failed (invalid duration); leaving it alone'; return 1 ;; esac
    if out="$(/usr/bin/find "$path" -maxdepth 0 -mmin "+$minutes" -print)"; then :; else
        _ew_seed_warn 'age probe failed; leaving it alone'; return 1
    fi
    [ -n "$out" ]
}

# Public predicate remains read-only; the guarded operation re-observes it.
ew_seed_lock_dir() { printf '%s\n' "$EW_SEED_ROOT/.locks/$1"; }
ew_seed_lock_is_reclaimable() {
    local key="$1" age="$2" path="$EW_SEED_ROOT/.locks/$1"
    if ! _ew_seed_valid_key "$key"; then return 1; fi
    if ! _ew_seed_observe "$EW_SEED_ROOT" "$path" '' owner; then return 1; fi
    if ! _ew_seed_age "$path" "$age"; then return 1; fi
    if [ "$_EW_SEED_OBS_OWNER" = m ]; then
        _ew_seed_warn "$key has no owner record and is older than ${age}m; reclaiming"; return 0
    fi
    _ew_seed_owner_abandoned "$_EW_SEED_OBS_OWNER"
}

_ew_seed_root_matches() {
    if ! _ew_seed_namespace "$1"; then return 1; fi
    [ "$_EW_SEED_NS_EXISTS" = 1 ] && [ -n "$2" ] && [ "$_EW_SEED_NS_IDENT" = "$2" ]
}

_ew_seed_gate_begin() {
    local root="$1" key="$2" lock="${3:-0}" root_id="$4" gate existing rc
    if [ "$_EW_SEED_FRAME" != 0 ] || ! _ew_seed_depth || ! _ew_seed_valid_key "$key"; then return 1; fi
    if ! _ew_seed_root_matches "$root" "$root_id"; then _ew_seed_warn 'captured root is unavailable/changed'; return 1; fi
    gate="$root/.mutations/$key"
    _EW_SEED_MUTATED=0; _EW_SEED_WAS_RETAINED=0; _EW_SEED_UNRESOLVED_TEMP=0
    if existing="$(_ew_seed_find_gate "$root" "$key")"; then
        if [ "${_EW_SEED_R_PHASE[$existing]:-}" != retained ] || [ -z "${_EW_SEED_R_IDENT[$existing]:-}" ]; then
            _ew_seed_warn "mutation gate unresolved/active: $gate; holder UNKNOWN outside retained record"; return 1
        fi
        if _ew_seed_observe "$root" "$gate" "${_EW_SEED_R_IDENT[$existing]}"; then rc=0; else rc=$?; fi
        case "$rc" in
            0) _EW_SEED_FRAME="$existing"; _EW_SEED_WAS_RETAINED=1
               _EW_SEED_R_PHASE[$existing]=active; _EW_SEED_R_LOCK[$existing]="$lock"; return 0 ;;
            3) _ew_seed_done "$existing"; _EW_SEED_WAS_RETAINED=1 ;;
            *) _ew_seed_warn "mutation gate changed/unknown; retained: $gate"; return 1 ;;
        esac
    fi
    if ! _ew_seed_ensure_child "$root" "$root/.mutations"; then return 1; fi
    if ! mkdir -- "$gate" 2>/dev/null; then
        _ew_seed_warn "mutation gate busy: $gate; contender $$, holder UNKNOWN; cache miss"
        return 1
    fi
    # Registration is immediate; unknown identity is retained, never adopted.
    _ew_seed_add gate mutation "$root" "$root" "$key" "$gate" active "$lock" '' '' "$root_id" "$root_id"
    _EW_SEED_FRAME="$_EW_SEED_NEW_RECORD"
    if _ew_seed_observe "$root" "$gate"; then
        if [ "$_EW_SEED_OBS_ROOT_ID" = "$root_id" ]; then
            _EW_SEED_R_IDENT[$_EW_SEED_FRAME]="$_EW_SEED_OBS_ID"; return 0
        fi
    fi
    _EW_SEED_R_PHASE[$_EW_SEED_FRAME]=retained
    _ew_seed_warn "created mutation gate has uncertain identity: $gate; retained for inspection"
    _EW_SEED_FRAME=0
    return 1
}

_ew_seed_owner_complete() {
    _ew_seed_owner_values "$1" && [ "$_EW_SEED_OWNER_VERSION" = "$EW_SEED_LOCK_VERSION" ]
}

_ew_seed_publish_owner() {
    # Captured bytes remain policy-owned here; the Python primitive only makes
    # exclusive, identity-conditioned publication and never parses v1.
    python3 "$_EW_SEED_HELPER" publish-owner "$1" "$2" "$3" "$4"
}

_ew_seed_gate_end() {
    local gate="$_EW_SEED_FRAME" root key lock path rc safe=1 expected
    if ! _ew_seed_live "$gate"; then _EW_SEED_FRAME=0; return 1; fi
    root="${_EW_SEED_R_ROOT[$gate]:-}"; key="${_EW_SEED_R_KEY[$gate]:-}"
    lock="${_EW_SEED_R_LOCK[$gate]:-0}"; path="$root/.locks/$key"
    if ! _ew_seed_root_matches "$root" "${_EW_SEED_R_ROOT_ID[$gate]:-}"; then
        _EW_SEED_R_PHASE[$gate]=retained; _EW_SEED_FRAME=0
        _ew_seed_warn 'captured gate root changed/unknown; retained'
        return 1
    fi
    # A refusing contender releases its own short gate. A possibly destructive
    # operation (or retained unsafe frame) must establish long-lived protection.
    if [ "$_EW_SEED_MUTATED" = 1 ] || [ "$_EW_SEED_WAS_RETAINED" = 1 ]; then
        safe=0
        if _ew_seed_observe "$root" "$path" '' owner; then rc=0; else rc=$?; fi
        if [ "$_EW_SEED_OBS_ROOT_ID" != "${_EW_SEED_R_ROOT_ID[$gate]}" ]; then rc=1; fi
        if [ "$rc" = 3 ] && [ "$_EW_SEED_UNRESOLVED_TEMP" = 0 ]; then
            safe=1
            if _ew_seed_live "$lock"; then _ew_seed_done "$lock"; fi
        elif [ "$rc" = 0 ] && _ew_seed_owner_complete "$_EW_SEED_OBS_OWNER"; then
            safe=1
        elif _ew_seed_live "$lock" && [ -n "${_EW_SEED_R_IDENT[$lock]:-}" ] && [ -n "${_EW_SEED_R_OWNER[$lock]:-}" ]; then
            expected="${_EW_SEED_R_OWNER[$lock]}"
            if _ew_seed_owner_complete "p:$expected" &&
               _ew_seed_publish_owner "$root" "$path" "${_EW_SEED_R_IDENT[$lock]}" "$expected"; then
                if _ew_seed_observe "$root" "$path" "${_EW_SEED_R_IDENT[$lock]}" owner &&
                   [ "$_EW_SEED_OBS_OWNER" = "p:$expected" ]; then safe=1; fi
            fi
        fi
    fi
    if [ "$safe" = 1 ] && [ -n "${_EW_SEED_R_IDENT[$gate]:-}" ]; then
        if python3 "$_EW_SEED_HELPER" rmdir "$root" "${_EW_SEED_R_PATH[$gate]}" "${_EW_SEED_R_IDENT[$gate]}"; then rc=0; else rc=$?; fi
        case "$rc" in
            0|3) _ew_seed_done "$gate"; _EW_SEED_FRAME=0; return 0 ;;
        esac
    fi
    _EW_SEED_R_PHASE[$gate]=retained
    _ew_seed_warn "mutation gate retained: ${_EW_SEED_R_PATH[$gate]}; unresolved protection, not automatic crash debris"
    _EW_SEED_FRAME=0
    return 1
}

_ew_seed_remove_record() {
    local record="$1" root path expected rc owner phase origin
    EW_SEED_REMOVE_OUTCOME=retained
    if ! _ew_seed_live "$record" || [ "$_EW_SEED_FRAME" = 0 ]; then return 1; fi
    root="${_EW_SEED_R_REMOVE_ROOT[$record]:-}"; path="${_EW_SEED_R_PATH[$record]:-}"
    expected="${_EW_SEED_R_IDENT[$record]:-}"; owner="${_EW_SEED_R_OWNER[$record]:-}"
    origin="${_EW_SEED_R_ORIGIN[$record]:-}"; phase="${_EW_SEED_R_PHASE[$record]:-}"
    if [ -z "$expected" ] || [ -z "$root" ] || [ -z "$path" ]; then
        _ew_seed_warn 'unknown record identity/namespace cannot authorize removal'; return 1
    fi
    if [ "${_EW_SEED_R_KIND[$record]}" = lock ]; then
        if _ew_seed_observe "$root" "$path" "$expected" owner; then rc=0; else rc=$?; fi
    else
        if _ew_seed_observe "$root" "$path" "$expected"; then rc=0; else rc=$?; fi
    fi
    if [ -z "${_EW_SEED_R_REMOVE_ID[$record]:-}" ] || [ "$_EW_SEED_OBS_ROOT_ID" != "${_EW_SEED_R_REMOVE_ID[$record]}" ]; then return 1; fi
    if [ "$rc" = 3 ]; then _ew_seed_done "$record"; EW_SEED_REMOVE_OUTCOME=absent; return 0; fi
    if [ "$rc" != 0 ]; then return 1; fi
    if [ "${_EW_SEED_R_KIND[$record]}" = lock ]; then
        if [ "$origin" = reclaim ]; then
            if [ -n "$owner" ]; then owner="p:$owner"; else owner=m; fi
            if [ "$_EW_SEED_OBS_OWNER" != "$owner" ]; then
                _ew_seed_warn 'abandoned owner changed since observation; retained'; return 1
            fi
            if [ "$_EW_SEED_OBS_OWNER" != m ] && ! _ew_seed_owner_abandoned "$_EW_SEED_OBS_OWNER"; then return 1; fi
        elif [ "$phase" = published ]; then
            if [ "$_EW_SEED_OBS_OWNER" != "p:$owner" ] || [ -z "$owner" ]; then
                _ew_seed_warn 'registered published owner changed; retained'; return 1
            fi
        elif [ "$_EW_SEED_OBS_OWNER" != m ] && [ "$_EW_SEED_OBS_OWNER" != "p:$owner" ]; then
            _ew_seed_warn 'unpublished rollback encountered another owner; retained'; return 1
        fi
    fi
    _EW_SEED_MUTATED=1
    if python3 "$_EW_SEED_HELPER" remove "$root" "$path" "$expected"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) EW_SEED_REMOVE_OUTCOME=removed; _ew_seed_done "$record"; return 0 ;;
        3) EW_SEED_REMOVE_OUTCOME=absent; _ew_seed_done "$record"; return 0 ;;
        *) _ew_seed_warn "cleanup retained/incomplete: $path"; return 1 ;;
    esac
}

_ew_seed_reclaim_in_frame() {
    # RECLAMATION NEEDS A SHIPPED CALLER. `ew_seed_lock_is_reclaimable` existed
    # and its only caller was the gitignored purge script, so on a fresh clone or
    # any other machine an abandoned lock was permanent: SIGKILL, power loss, or
    # the small window this function itself has, and that key loses seeding
    # forever with nothing to clear it. Same class as the cache that could only
    # be pruned by an untracked script — a mechanism whose recovery lives outside
    # the shipped tree has no recovery.
    # Reclaim only what is PROVABLY abandoned: aged AND its recorded owner gone.
    # Anything unreadable, unknown-version, or merely unresponsive is left alone,
    # and a single retry keeps this from becoming a spin.
    local root="$1" key="$2" age="$3" path candidate owner
    path="$root/.locks/$key"
    if ! _ew_seed_observe "$root" "$path" '' owner || ! _ew_seed_age "$path" "$age"; then return 1; fi
    owner="$_EW_SEED_OBS_OWNER"
    if [ "$owner" != m ] && ! _ew_seed_owner_abandoned "$owner"; then return 1; fi
    if [ "$owner" = m ]; then owner=''; else owner="${owner#p:}"; fi
    _ew_seed_add lock reclaim "$root" "$root" "$key" "$path" reclaiming 0 "$_EW_SEED_OBS_ID" "$owner" "$_EW_SEED_OBS_ROOT_ID" "$_EW_SEED_OBS_ROOT_ID"
    candidate="$_EW_SEED_NEW_RECORD"
    _EW_SEED_R_LOCK[$candidate]="$candidate"
    _EW_SEED_R_LOCK[$_EW_SEED_FRAME]="$candidate"
    if _ew_seed_remove_record "$candidate"; then
        return 0
    fi
    return 1
}

ew_seed_lock_reclaim() {
    local key="$1" age="${2:-$EW_SEED_LOCK_RECLAIM_AGE_MIN}" root rc result=1
    EW_SEED_REMOVE_OUTCOME=retained; EW_SEED_CLEANUP_COMPLETE=1
    if ! _ew_seed_valid_key "$key" || ! _ew_seed_select_root; then EW_SEED_CLEANUP_COMPLETE=0; return 1; fi
    root="$_EW_SEED_CAPTURED_ROOT"
    if ! _ew_seed_gate_begin "$root" "$key" 0 "$_EW_SEED_CAPTURED_ROOT_ID"; then EW_SEED_CLEANUP_COMPLETE=0; return 1; fi
    if _ew_seed_observe "$root" "$root/.locks/$key" '' owner; then rc=0; else rc=$?; fi
    if [ "$_EW_SEED_OBS_ROOT_ID" != "$_EW_SEED_CAPTURED_ROOT_ID" ]; then rc=1; fi
    if [ "$rc" = 3 ]; then EW_SEED_REMOVE_OUTCOME=absent; result=3
    elif [ "$rc" = 0 ] && _ew_seed_reclaim_in_frame "$root" "$key" "$age"; then result=0
    else EW_SEED_CLEANUP_COMPLETE=0; fi
    if _ew_seed_gate_end; then :; else EW_SEED_CLEANUP_COMPLETE=0; fi
    return "$result"
}

ew_seed_lock_acquire() {
    local key="$1" root path lock started encoded rc found
    if ! _ew_seed_valid_key "$key" || ! _ew_seed_select_root; then return 1; fi
    if found="$(_ew_seed_find_lock "$key")"; then
        _ew_seed_warn "key already registered ($found); cache miss"; return 1
    fi
    root="$_EW_SEED_CAPTURED_ROOT"; path="$root/.locks/$key"
    if ! _ew_seed_ensure_child "$root" "$root/.locks" || ! _ew_seed_gate_begin "$root" "$key" 0 "$_EW_SEED_CAPTURED_ROOT_ID"; then return 1; fi
    if ! mkdir -- "$path" 2>/dev/null; then
        if ! _ew_seed_reclaim_in_frame "$root" "$key" "$EW_SEED_LOCK_RECLAIM_AGE_MIN"; then
            if _ew_seed_gate_end; then :; fi
            return 1
        fi
        if ! mkdir -- "$path" 2>/dev/null; then
            if _ew_seed_gate_end; then :; fi
            return 1
        fi
    fi
    _EW_SEED_MUTATED=1
    _ew_seed_add lock owned "$root" "$root" "$key" "$path" created 0 '' '' "$_EW_SEED_CAPTURED_ROOT_ID" "$_EW_SEED_CAPTURED_ROOT_ID"
    lock="$_EW_SEED_NEW_RECORD"
    _EW_SEED_R_LOCK[$lock]="$lock"; _EW_SEED_R_LOCK[$_EW_SEED_FRAME]="$lock"
    if _ew_seed_observe "$root" "$path" && [ "$_EW_SEED_OBS_ROOT_ID" = "${_EW_SEED_R_REMOVE_ID[$lock]}" ]; then
        _EW_SEED_R_IDENT[$lock]="$_EW_SEED_OBS_ID"
    else
        if _ew_seed_gate_end; then :; fi
        return 1
    fi
    if started="$(ew_seed_process_identity "$$")"; then :; else
        if _ew_seed_remove_record "$lock"; then :; fi
        if _ew_seed_gate_end; then :; fi
        return 1
    fi
  # TRACK IT IMMEDIATELY, BEFORE ANY OTHER WORK. Registering after the owner
  # record was written left a window in which HUP/INT/TERM stranded a lock the
  # EXIT cleanup did not know about. Between `mkdir` and this line there is now
  # nothing that can be interrupted.
    # Historical correction (#4197): mkdir and registration ARE interruptible.
    # The independent mutation gate protects that unpublished gap; uncertainty
    # retains the gate rather than pretending EXIT can reconstruct ownership.
  # WRITE THE OWNER RECORD ATOMICALLY, and the reason is not tidiness — it is
  # that a PARTIAL record is PERMANENT. Redirecting straight into `owner` meant a
  # signal mid-write could leave `version=` truncated or empty, and
  # `ew_seed_lock_is_reclaimable` deliberately refuses an unknown version, so
  # that key would read as busy for the rest of the machine's life and lose
  # seeding entirely. Same-directory rename is atomic, so `owner` is now either
  # ABSENT or COMPLETE — never in between. That also narrows "malformed" back to
  # what it was meant to mean: a record written by a version we do not know,
  # which SHOULD fail closed.
    # #4197 uses an exclusive same-directory hard link for the same complete-or-
    # absent guarantee while refusing to replace an unexpected existing owner.
    # Publication remains complete-or-absent. Exclusive hard-link publication
    # now also refuses to overwrite an unexpected owner in the same instance.
    if encoded="$(python3 -c 'import base64,sys; print(base64.b64encode(("version=1\npid="+sys.argv[1]+"\nstarted="+sys.argv[2]+"\n").encode()).decode())' "$$" "$started")"; then :; else
        if _ew_seed_remove_record "$lock"; then :; fi
        if _ew_seed_gate_end; then :; fi
        return 1
    fi
    _EW_SEED_R_OWNER[$lock]="$encoded"; _EW_SEED_R_PHASE[$lock]=publishing
    if _ew_seed_publish_owner "$root" "$path" "${_EW_SEED_R_IDENT[$lock]}" "$encoded"; then
        _EW_SEED_R_PHASE[$lock]=published
        if _ew_seed_gate_end; then :; fi
        return 0
    fi
    if _ew_seed_remove_record "$lock"; then :; fi
    if _ew_seed_gate_end; then :; fi
    return 1
}

_ew_seed_lock_authority() {
    local lock="$1" rc expected
    if ! _ew_seed_live "$lock" || [ "${_EW_SEED_R_KIND[$lock]:-}" != lock ] || [ -z "${_EW_SEED_R_IDENT[$lock]:-}" ]; then return 1; fi
    if _ew_seed_observe "${_EW_SEED_R_ROOT[$lock]}" "${_EW_SEED_R_PATH[$lock]}" "${_EW_SEED_R_IDENT[$lock]}" owner; then rc=0; else rc=$?; fi
    if [ "$_EW_SEED_OBS_ROOT_ID" != "${_EW_SEED_R_ROOT_ID[$lock]}" ]; then return 1; fi
    if [ "$rc" = 3 ]; then return 3; fi
    if [ "$rc" != 0 ]; then return 1; fi
    if [ "${_EW_SEED_R_ORIGIN[$lock]}" = reclaim ]; then
        expected="${_EW_SEED_R_OWNER[$lock]:-}"
        if [ -n "$expected" ]; then expected="p:$expected"; else expected=m; fi
        [ "$_EW_SEED_OBS_OWNER" = "$expected" ] || return 1
        [ "$expected" = m ] || _ew_seed_owner_abandoned "$expected" || return 1
    elif [ "${_EW_SEED_R_PHASE[$lock]}" = published ]; then
        [ -n "${_EW_SEED_R_OWNER[$lock]:-}" ] && [ "$_EW_SEED_OBS_OWNER" = "p:${_EW_SEED_R_OWNER[$lock]}" ] || return 1
    elif [ "$_EW_SEED_OBS_OWNER" != m ] && [ "$_EW_SEED_OBS_OWNER" != "p:${_EW_SEED_R_OWNER[$lock]:-}" ]; then
        return 1
    fi
    return 0
}

_ew_seed_requested_records() {
    local key="$1" root="$2" n=1
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" != "done" ] && [ "${_EW_SEED_R_KEY[$n]:-}" = "$key" ] && [ "${_EW_SEED_R_ROOT[$n]:-}" = "$root" ]; then return 0; fi
        n=$((n + 1))
    done
    return 1
}

_ew_seed_cleanup_key() {
    local record="$1" root key root_id lock=0 rc n maximum temp failed=0
    if ! _ew_seed_live "$record"; then return 0; fi
    root="${_EW_SEED_R_ROOT[$record]:-}"; key="${_EW_SEED_R_KEY[$record]:-}"
    root_id="${_EW_SEED_R_ROOT_ID[$record]:-}"
    if [ "${_EW_SEED_R_KIND[$record]:-}" = lock ]; then lock="$record"
    elif [ "${_EW_SEED_R_KIND[$record]:-}" = gate ]; then
        if _ew_seed_live "${_EW_SEED_R_LOCK[$record]:-0}"; then lock="${_EW_SEED_R_LOCK[$record]}"; fi
    else return 1; fi
    if ! _ew_seed_gate_begin "$root" "$key" "$lock" "$root_id"; then return 1; fi
    if [ "$lock" != 0 ]; then
        if _ew_seed_lock_authority "$lock"; then rc=0; else rc=$?; fi
        case "$rc" in
            0|3) ;;
            *) _ew_seed_warn "ownership changed/unknown for $key; registered state retained"
               if _ew_seed_gate_end; then :; fi
               return 1 ;;
        esac
        maximum="$_EW_SEED_NEXT"; n=1
        while [ "$n" -le "$maximum" ]; do
            if [ "${_EW_SEED_R_KIND[$n]:-done}" = temp ] && [ "${_EW_SEED_R_LOCK[$n]:-0}" = "$lock" ]; then
                temp="$n"
                if [ -z "${_EW_SEED_R_IDENT[$temp]:-}" ]; then
                    if _ew_seed_observe "${_EW_SEED_R_REMOVE_ROOT[$temp]}" "${_EW_SEED_R_PATH[$temp]}"; then rc=0; else rc=$?; fi
                    if [ -z "${_EW_SEED_R_REMOVE_ID[$temp]:-}" ] || [ "$_EW_SEED_OBS_ROOT_ID" != "${_EW_SEED_R_REMOVE_ID[$temp]}" ]; then
                        _ew_seed_warn 'captured staging root changed/unknown; record retained'; failed=1
                    elif [ "$rc" = 3 ]; then
                        _ew_seed_done "$temp"
                    elif [ "$rc" = 0 ] && [ "${_EW_SEED_R_ORIGIN[$temp]}" != new ]; then
                        _EW_SEED_R_IDENT[$temp]="$_EW_SEED_OBS_ID"
                        if _ew_seed_remove_record "$temp"; then :; else failed=1; fi
                    else
                        _ew_seed_warn 'unbound new staging/unknown metadata cannot be adopted for cleanup'; failed=1
                    fi
                elif _ew_seed_remove_record "$temp"; then :; else failed=1; fi
            fi
            n=$((n + 1))
        done
        if [ "$failed" = 0 ]; then
            if _ew_seed_remove_record "$lock"; then :; else failed=1; fi
        else
            _EW_SEED_UNRESOLVED_TEMP=1
            _ew_seed_warn "staging retained for $key; key lock protection retained"
        fi
    fi
    if _ew_seed_gate_end; then :; else failed=1; fi
    if _ew_seed_requested_records "$key" "$root"; then return 1; fi
    # A failed native command may nevertheless leave verified absence; the
    # final registry, not a stale exit code, determines cleanup completion.
    return 0
}

ew_seed_lock_release() {
    local key="$1" record n=1
    EW_SEED_CLEANUP_COMPLETE=1
    if ! _ew_seed_depth; then EW_SEED_CLEANUP_COMPLETE=0; return 0; fi
    if record="$(_ew_seed_find_lock "$key")"; then
        if _ew_seed_cleanup_key "$record"; then :; else EW_SEED_CLEANUP_COMPLETE=0; fi
        return 0
    fi
    # Unheld release deletes no key. A separately registered owned gate may
    # still need its own bounded completion after its key was already removed.
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = gate ] && [ "${_EW_SEED_R_KEY[$n]:-}" = "$key" ]; then
            if _ew_seed_cleanup_key "$n"; then :; else EW_SEED_CLEANUP_COMPLETE=0; fi
        fi
        n=$((n + 1))
    done
    return 0
}

ew_seed_release_all() {
    local n=1 maximum="$_EW_SEED_NEXT" aggregate=1 kind linked
    EW_SEED_CLEANUP_COMPLETE=1
    if ! _ew_seed_depth; then EW_SEED_CLEANUP_COMPLETE=0; return 0; fi
    while [ "$n" -le "$maximum" ]; do
        kind="${_EW_SEED_R_KIND[$n]:-done}"
        if [ "$kind" = lock ]; then
            if _ew_seed_cleanup_key "$n"; then :; else aggregate=0; fi
        elif [ "$kind" = gate ]; then
            linked="${_EW_SEED_R_LOCK[$n]:-0}"
            if ! _ew_seed_live "$linked"; then
                if _ew_seed_cleanup_key "$n"; then :; else aggregate=0; fi
            fi
        elif [ "$kind" = temp ]; then
            linked="${_EW_SEED_R_LOCK[$n]:-0}"
            if ! _ew_seed_live "$linked"; then
                _ew_seed_warn 'orphan registry association retained, not guessed'; aggregate=0
            fi
        fi
        n=$((n + 1))
    done
    EW_SEED_CLEANUP_COMPLETE="$aggregate"
    return 0
}

ew_seed_on_exit() {
    local n=1
    # Caller invokes this only from its composed EXIT handler, after owned
    # foreground/async work has quiesced. The interrupted operation will not
    # resume; its recorded frame can now be retried rather than nested.
    while [ "$n" -le "$_EW_SEED_NEXT" ]; do
        if [ "${_EW_SEED_R_KIND[$n]:-done}" = gate ] && [ "${_EW_SEED_R_PHASE[$n]:-}" = active ]; then
            _EW_SEED_R_PHASE[$n]=retained
        fi
        n=$((n + 1))
    done
    _EW_SEED_FRAME=0
    ew_seed_release_all
    return 0
}

_ew_seed_stage_path_valid() {
    local key="$1" root="$2" path="$3" leaf
    [ "${path%/*}" = "$root" ] || return 1
    leaf="${path##*/}"
    case "$leaf" in ".staging."*|".SourcePackages.seed.$key."*) return 0 ;; esac
    return 1
}

ew_seed_track_temp() {
    local path="$1" root="$2" key="$3" lock rc
    if ! _ew_seed_depth || ! _ew_seed_stage_path_valid "$key" "$root" "$path"; then return 1; fi
    if lock="$(_ew_seed_find_lock "$key")"; then :; else _ew_seed_warn 'staging intent requires registered key ownership'; return 1; fi
    if [ "${_EW_SEED_R_ORIGIN[$lock]}" != owned ] || [ "${_EW_SEED_R_PHASE[$lock]}" != published ]; then return 1; fi
    if _ew_seed_observe "$root" "$path"; then rc=0; else rc=$?; fi
    if [ "$rc" != 3 ]; then _ew_seed_warn 'new staging intent requires verified absence'; return 1; fi
    _ew_seed_add temp new "${_EW_SEED_R_ROOT[$lock]}" "$root" "$key" "$path" intent "$lock" '' '' "${_EW_SEED_R_ROOT_ID[$lock]}" "$_EW_SEED_OBS_ROOT_ID"
    EW_SEED_TEMP_RECORD="$_EW_SEED_NEW_RECORD"
    return 0
}

ew_seed_begin_temp() {
    local key="$1" root="$2" path="$3" lock record result=1
    if ! _ew_seed_depth || ! _ew_seed_stage_path_valid "$key" "$root" "$path"; then return 1; fi
    if lock="$(_ew_seed_find_lock "$key")"; then :; else return 1; fi
    if ! _ew_seed_gate_begin "${_EW_SEED_R_ROOT[$lock]}" "$key" "$lock" "${_EW_SEED_R_ROOT_ID[$lock]}"; then return 1; fi
    if _ew_seed_lock_authority "$lock" && ew_seed_track_temp "$path" "$root" "$key"; then
        record="$EW_SEED_TEMP_RECORD"
        if mkdir -- "$path"; then
            if _ew_seed_observe "$root" "$path" && [ "$_EW_SEED_OBS_ROOT_ID" = "${_EW_SEED_R_REMOVE_ID[$record]}" ]; then
                _EW_SEED_R_IDENT[$record]="$_EW_SEED_OBS_ID"; _EW_SEED_R_PHASE[$record]=bound; result=0
            fi
        fi
    fi
    if _ew_seed_gate_end; then :; fi
    return "$result"
}

ew_seed_complete_temp() {
    local key="$1" path="$2" lock record rc
    if ! _ew_seed_depth; then return 1; fi
    if lock="$(_ew_seed_find_lock "$key")" && record="$(_ew_seed_find_temp "$lock" "$path")"; then :; else return 1; fi
    if _ew_seed_observe "${_EW_SEED_R_REMOVE_ROOT[$record]}" "$path"; then rc=0; else rc=$?; fi
    if [ "$rc" = 3 ] && [ "$_EW_SEED_OBS_ROOT_ID" = "${_EW_SEED_R_REMOVE_ID[$record]}" ]; then
        _ew_seed_done "$record"; return 0
    fi
    _ew_seed_warn 'renamed staging could not be confirmed absent; record retained'
    return 1
}

ew_seed_cleanup_candidate() {
    local key="$1" root="$2" path="$3" origin="${4:-stale}" lock record rc result=1
    EW_SEED_CLEANUP_COMPLETE=1; EW_SEED_REMOVE_OUTCOME=retained
    if ! _ew_seed_depth || ! _ew_seed_valid_key "$key"; then EW_SEED_CLEANUP_COMPLETE=0; return 1; fi
    if lock="$(_ew_seed_find_lock "$key")"; then :; else EW_SEED_CLEANUP_COMPLETE=0; return 1; fi
    if ! _ew_seed_gate_begin "${_EW_SEED_R_ROOT[$lock]}" "$key" "$lock" "${_EW_SEED_R_ROOT_ID[$lock]}"; then EW_SEED_CLEANUP_COMPLETE=0; return 1; fi
    if _ew_seed_lock_authority "$lock"; then
        if record="$(_ew_seed_find_temp "$lock" "$path")"; then
            if [ -n "${_EW_SEED_R_IDENT[$record]:-}" ]; then
                if _ew_seed_remove_record "$record"; then result=0; fi
            fi
        else
            if [ "$origin" = snapshot ]; then
                if [ "$root" = "${_EW_SEED_R_ROOT[$lock]}" ] && [ "$path" = "$root/$key" ]; then rc=0; else rc=1; fi
            elif _ew_seed_stage_path_valid "$key" "$root" "$path"; then rc=0; else rc=1; fi
            if [ "$rc" = 0 ]; then
                if _ew_seed_observe "$root" "$path"; then rc=0; else rc=$?; fi
                if [ "$rc" = 3 ]; then
                    EW_SEED_REMOVE_OUTCOME=absent; result=0
                else
                    _ew_seed_add temp "$origin" "${_EW_SEED_R_ROOT[$lock]}" "$root" "$key" "$path" cleanup "$lock" '' '' "${_EW_SEED_R_ROOT_ID[$lock]}" "$_EW_SEED_OBS_ROOT_ID"
                    record="$_EW_SEED_NEW_RECORD"
                    if [ "$rc" = 0 ]; then
                        _EW_SEED_R_IDENT[$record]="$_EW_SEED_OBS_ID"
                        if _ew_seed_remove_record "$record"; then result=0; fi
                    fi
                fi
            fi
        fi
    fi
    if [ "$result" != 0 ]; then
        _EW_SEED_UNRESOLVED_TEMP=1; EW_SEED_CLEANUP_COMPLETE=0
        _ew_seed_warn "candidate retained for $key; no new copying authorized"
    fi
    if _ew_seed_gate_end; then :; else EW_SEED_CLEANUP_COMPLETE=0; fi
    return "$result"
}
