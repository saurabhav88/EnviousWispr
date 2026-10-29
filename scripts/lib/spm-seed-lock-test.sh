#!/usr/bin/env bash
# scripts/lib/spm-seed-lock-test.sh — two-way test for the seed lock protocol
# (#2157 chunk A).
#
# WHY EVERY CASE HAS A TWIN
# A lock has two failure directions and only one announces itself:
#   - refuses too often  -> cache misses, builds are slower, obviously wrong.
#   - grants too often   -> two writers on one snapshot, or a purge deleting a
#                           tree mid-clone. Silent, and it corrupts.
# So each "acquires" case has a "refuses" twin, and the reclamation cases are
# written from the dangerous side: proving a LIVE owner is never reclaimed
# matters more than proving a dead one is.
#
# Runs entirely against a temporary seed root. Touches no real cache, needs no
# build, no network and no signing identity.
set -uo pipefail

# Private-copy race controls. The only pause is inserted into the copied
# subject after a checked one-site match; production has no pause/test knob.
if [ "${1:-}" = "--race-control" ]; then
  shift
  PYTHONDONTWRITEBYTECODE=1 python3 - "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" "$@" <<'PYRACE'
import hashlib, json, os, pathlib, select, signal, stat, subprocess, sys, tempfile

here = pathlib.Path(sys.argv[1])
mode, baseline = sys.argv[2], pathlib.Path(sys.argv[3])
assert mode in ('baseline', 'serialized', 'replacement', 'holder')
old = baseline.read_text()
assert hashlib.sha256(old.encode()).hexdigest() == 'cdbbe85888a0b7e9561989624e6de3878a544042fd5133eb5f78fbe145af059f'
base = pathlib.Path(tempfile.mkdtemp(prefix='ew-4197-race-')).resolve()
anchor = os.lstat(base)
root = base / 'seed'
lock = root / '.locks/race'
children, descriptors = [], []

def pipe():
    r, w = os.pipe()
    descriptors.extend((r, w))
    return r, w

def receive(fd):
    # deadline-fallback: hang guard, same 30s fixture precedent as
    # scripts/lib/dev-app-lock-test.py:94; elapsed time is never the oracle.
    if not select.select([fd], [], [], 30)[0]:
        evidence = [(proc.returncode, proc.communicate(timeout=1))
                    for proc in children if proc.poll() is not None]
        raise AssertionError(('subject did not signal completion', evidence))
    token = os.read(fd, 1)
    assert token in (b'R', b'H', b'M'), ('unexpected subject signal', token)
    return token

actor = r'''
set -uo pipefail
_fixture_pause() {
  printf R >&"$PROBE_READY_FD"
  IFS= read -r _fixture_resume <&"$PROBE_GO_FD"
}
rm() {
  if [ "$#" -ne 2 ] || [ "$1" != -rf ]; then return 91; fi
  case "$2" in "$EW_SEED_ROOT"/*) ;; *) return 92 ;; esac
  if /usr/bin/python3 "$PROBE_HELPER" "$EW_SEED_ROOT" "$2"; then return 0; else
    _fixture_rc=$?; [ "$_fixture_rc" -eq 3 ]
  fi
}
. "$PROBE_SOURCE"
if ew_seed_lock_acquire race; then
  if [ "$PROBE_ROLE" = B ]; then printf sentinel > "$EW_SEED_ROOT/.locks/race/replacement-sentinel"; fi
  printf H >&"$PROBE_HELD_FD"
  IFS= read -r _fixture_stop <&"$PROBE_STOP_FD"
  ew_seed_lock_release race
else
  printf M >&"$PROBE_HELD_FD"
fi
'''

def source_copy(label, text, pause):
    directory = base / label
    directory.mkdir()
    if pause:
        if label.startswith('old'):
            needle = '      rm -rf "$dir" 2>/dev/null || true\n      mkdir "$dir" 2>/dev/null || return 1'
            replacement = '      _fixture_pause\n' + needle
        else:
            needle = '    if _ew_seed_remove_record "$candidate"; then'
            replacement = '    _fixture_pause\n' + needle
        assert text.count(needle) == 1, 'private pause rewrite did not match one site'
        text = text.replace(needle, replacement, 1)
    path = directory / 'spm-seed-lock.sh'
    path.write_text(text)
    (directory / 'remove-tree.py').write_bytes((here / 'remove-tree.py').read_bytes())
    return path

def launch(role, source, ready_w, go_r, held_w, stop_r):
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C',
           'PYTHONDONTWRITEBYTECODE': '1', 'TMPDIR': str(base),
           'EW_SEED_ROOT': str(root), 'PROBE_SOURCE': str(source),
           'PROBE_HELPER': str(here / 'remove-tree.py'), 'PROBE_ROLE': role,
           'PROBE_READY_FD': str(ready_w), 'PROBE_GO_FD': str(go_r),
           'PROBE_HELD_FD': str(held_w), 'PROBE_STOP_FD': str(stop_r)}
    if 'HOME' in os.environ: env['HOME'] = os.environ['HOME']
    proc = subprocess.Popen(['/bin/bash', '-c', actor], cwd=base, env=env,
                            pass_fds=(ready_w, go_r, held_w, stop_r),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, start_new_session=True)
    children.append(proc)
    return proc

try:
    lock.mkdir(parents=True)
    dead = subprocess.Popen(['/bin/sh', '-c', 'exit 0'])
    assert dead.wait(timeout=30) == 0
    (lock / 'owner').write_text('version=1\npid={}\nstarted=fixture-dead-process\n'.format(dead.pid))
    os.utime(lock, (1577836800, 1577836800))
    sibling = root / 'sibling-sentinel'
    sibling.write_text('keep')
    a_text = old if mode == 'baseline' else (here / 'spm-seed-lock.sh').read_text()
    b_text = (here / 'spm-seed-lock.sh').read_text() if mode in ('serialized', 'holder') else old
    a_src = source_copy('old-a' if mode == 'baseline' else 'new-a', a_text, mode != 'holder')
    b_src = source_copy('new-b' if mode in ('serialized', 'holder') else 'old-b', b_text, False)
    ready_r, ready_w = pipe(); go_r, go_w = pipe()
    a_r, a_w = pipe(); b_r, b_w = pipe()
    a_stop_r, a_stop_w = pipe(); b_stop_r, b_stop_w = pipe()
    a = launch('A', a_src, ready_w, go_r, a_w, a_stop_r)
    if mode == 'holder':
        a_result = receive(a_r)
        assert a_result == b'H' and a.poll() is None
        assert not (root / '.mutations/race').exists()
        assert 'pid={}\n'.format(a.pid) in (lock / 'owner').read_text()
    else:
        assert receive(ready_r) == b'R'
    b = launch('B', b_src, ready_w, go_r, b_w, b_stop_r)
    b_result = receive(b_r)
    if mode not in ('serialized', 'holder'):
        assert b_result == b'H' and b.poll() is None
        assert (lock / 'replacement-sentinel').read_text() == 'sentinel'
    else:
        assert b_result == b'M'
    # A pipe retains an early release, so arrived-before-read cannot lose wakeup.
    if mode != 'holder':
        os.write(go_w, b'continue\n')
        a_result = receive(a_r)
    else:
        assert not (root / '.mutations/race').exists()
        assert 'pid={}\n'.format(a.pid) in (lock / 'owner').read_text()
    sentinel = (lock / 'replacement-sentinel').exists()
    if mode == 'baseline':
        assert a_result == b'H' and not sentinel and b.poll() is None
        assert 'pid={}\n'.format(a.pid) in (lock / 'owner').read_text()
    elif mode in ('serialized', 'holder'):
        assert a_result == b'H' and not sentinel
        assert 'pid={}\n'.format(a.pid) in (lock / 'owner').read_text()
    else:
        assert a_result == b'M' and sentinel
        assert 'pid={}\n'.format(b.pid) in (lock / 'owner').read_text()
    assert sibling.read_text() == 'keep'
    for proc, outcome, stop in [(a, a_result, a_stop_w), (b, b_result, b_stop_w)]:
        if outcome == b'H': os.write(stop, b'finish\n')
        out, err = proc.communicate(timeout=30)
        assert proc.returncode == 0, (out, err)
    if mode == 'holder':
        assert not lock.exists() and not (root / '.mutations/race').exists()
    print(json.dumps({'mode': mode, 'participants_completed': 2,
                      'a': a_result.decode(), 'b': b_result.decode(),
                      'replacement_sentinel_survived': sentinel,
                      'rightful_holder_released': mode == 'holder',
                      'sibling_survived': True,
                      'baseline_bug_reproduced': mode == 'baseline'}))
finally:
    for proc in children:
        if proc.poll() is None:
            # This Popen created the entire session; no name-based/shared kill.
            assert os.getpgid(proc.pid) == proc.pid
            os.killpg(proc.pid, signal.SIGTERM)
            proc.communicate(timeout=30)
    for fd in descriptors:
        os.close(fd)
    current, parent = os.lstat(base), os.stat(base.parent)
    assert stat.S_ISDIR(current.st_mode)
    assert (current.st_dev, current.st_ino) == (anchor.st_dev, anchor.st_ino)
    assert current.st_dev == parent.st_dev and current.st_ino != parent.st_ino
    # Independently dependable bounded fixture teardown, not the injected rm.
    subprocess.run(['/usr/bin/find', '-P', str(base), '-xdev', '-delete'], check=True)
    assert not os.path.lexists(base)
PYRACE
  exit "$?"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; TMPROOT=""; KIDS=()

# Independent bounded fixture teardown; never call the helper being tested.
rm() {
  if [ "$#" = 2 ] && [ "$1" = -rf ]; then
    python3 - "$TMPROOT" "$FIXTURE_ID" "$2" <<'PYREMOVE'
import os, stat, subprocess, sys
root, expected, target = sys.argv[1:]
root, target = os.path.abspath(root), os.path.abspath(target)
s = os.lstat(root)
assert stat.S_ISDIR(s.st_mode) and f'{s.st_dev}:{s.st_ino}' == expected
assert target == root or target.startswith(root + os.sep)
current = root
for part in os.path.relpath(target, root).split(os.sep):
    if part == '.': continue
    current = os.path.join(current, part)
    try: entry = os.lstat(current)
    except FileNotFoundError: sys.exit(0)
    assert stat.S_ISDIR(entry.st_mode) and entry.st_dev == s.st_dev
subprocess.run(['/usr/bin/find', '-P', target, '-xdev', '-delete'], check=True)
assert not os.path.lexists(target)
PYREMOVE
  else
    command rm "$@"
  fi
}
cleanup() {
  local p
  for p in ${KIDS[@]+"${KIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${KIDS[@]+"${KIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
  [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

TMPROOT="$(mktemp -d /tmp/ew-seed-lock-XXXXXX)"
TMPROOT="$(cd "$TMPROOT" && pwd -P)"
FIXTURE_ID="$(/usr/bin/stat -f '%d:%i' "$TMPROOT")"
export EW_SEED_ROOT="$TMPROOT/spm-seed"
# shellcheck source=scripts/lib/spm-seed-lock.sh
. "$HERE/spm-seed-lock.sh"

# Intended-positive acquisition is setup, not the refusal behavior under test.
# Observe both the published registry and actual owner before dependent cases;
# absence after failed setup must never masquerade as successful cleanup.
require_owned_acquire() {
  local key="$1" record
  if ! ew_seed_lock_acquire "$key" || ! record="$(_ew_seed_find_lock "$key")" \
     || [ "${_EW_SEED_R_PHASE[$record]:-}" != published ] \
     || [ -z "${_EW_SEED_R_IDENT[$record]:-}" ] \
     || [ ! -f "$EW_SEED_ROOT/.locks/$key/owner" ] \
     || [ "$(sed -n 's/^pid=//p' "$EW_SEED_ROOT/.locks/$key/owner")" != "$$" ]; then
    bad "positive acquisition setup" "$key did not publish a registered owner"
    exit 1
  fi
}

K="testkey"

# --- acquire / refuse ---------------------------------------------------------
if require_owned_acquire "$K"; then ok "acquires a free lock"; else bad "acquire free lock" "refused a free key"; fi

# The twin. Without it, a function that always returns 0 passes the case above.
if ew_seed_lock_acquire "$K"; then
  bad "second acquire refused" "granted a lock that is already held"
else
  ok "refuses a lock already held (the twin: proves acquire is not always-yes)"
fi

if require_owned_acquire "otherkey"; then ok "a DIFFERENT key is unaffected"; else bad "per-key locking" "refused an unrelated key"; fi
ew_seed_lock_release "otherkey"

# --- ownership record ---------------------------------------------------------
OWNER="$EW_SEED_ROOT/.locks/$K/owner"
if [ -f "$OWNER" ] && grep -q "^version=$EW_SEED_LOCK_VERSION$" "$OWNER" \
   && grep -q "^pid=$$\$" "$OWNER" && grep -q "^started=." "$OWNER"; then
  ok "ownership records version, pid and start identity"
else
  bad "ownership record" "missing or incomplete: $(cat "$OWNER" 2>/dev/null | tr '\n' ' ')"
fi

# --- release ------------------------------------------------------------------
ew_seed_lock_release "$K"
if [ ! -d "$EW_SEED_ROOT/.locks/$K" ]; then ok "release removes the lock"; else bad "release" "lock directory survived"; fi
if require_owned_acquire "$K"; then ok "the key is acquirable again after release"; else bad "re-acquire" "still refused after release"; fi

# --- release_all --------------------------------------------------------------
require_owned_acquire "bulk1" >/dev/null 2>&1
require_owned_acquire "bulk2" >/dev/null 2>&1
ew_seed_release_all
if [ -z "$(ls -A "$EW_SEED_ROOT/.locks" 2>/dev/null)" ]; then
  ok "release_all clears every lock this process owns"
else
# shellcheck disable=SC2012  # a diagnostic message in a test; filenames are ours
  bad "release_all" "locks survived: $(ls "$EW_SEED_ROOT/.locks" 2>/dev/null | tr '\n' ' ')"
fi

# --- reclamation: THE DANGEROUS DIRECTION FIRST -------------------------------
# A live owner must NEVER be reclaimed. Getting this wrong deletes a tree while
# another process is cloning it.
require_owned_acquire "$K" >/dev/null 2>&1
# BACKDATE the lock so the AGE condition is satisfied. Without this the case
# passes for the wrong reason — `find -mmin +0` refuses a just-created directory,
# so the age check returns first and the liveness check is never reached. Caught
# by mutation: removing the liveness proof entirely left this case GREEN.
touch -t 202001010000 "$EW_SEED_ROOT/.locks/$K"
if ew_seed_lock_is_reclaimable "$K" 60; then
  bad "live owner protected" "reclaimed an AGED lock whose owner is THIS running process"
else
  ok "a LIVE owner is never reclaimed even when aged (liveness, not age, refuses)"
fi

ew_seed_lock_release "$K"

# Age is independently required: a FRESH lock is refused even when its owner is
# provably gone. Twin of the case above — together they prove BOTH conditions are
# load-bearing rather than one masking the other.
( : ) & FRESH_DEAD=$!
wait "$FRESH_DEAD" 2>/dev/null || true
mkdir -p "$EW_SEED_ROOT/.locks/freshdead"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"; printf 'pid=%s\n' "$FRESH_DEAD"; printf 'started=Mon Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/freshdead/owner"
if ew_seed_lock_is_reclaimable freshdead 60; then
  bad "age required" "reclaimed a FRESH lock whose owner is dead — age is not being checked"
else
  ok "a NOT-YET-AGED lock is refused even with a dead owner (age is load-bearing)"
fi

# Dead owner + aged: the only case that may be reclaimed. A real short-lived
# child gives a genuinely dead pid rather than an invented one.
( : ) & DEAD_PID=$!
wait "$DEAD_PID" 2>/dev/null || true
mkdir -p "$EW_SEED_ROOT/.locks/deadkey"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"; printf 'pid=%s\n' "$DEAD_PID"; printf 'started=Mon Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/deadkey/owner"
# Backdate so the age condition is satisfied.
touch -t 202001010000 "$EW_SEED_ROOT/.locks/deadkey"
if ew_seed_lock_is_reclaimable "deadkey" 60; then
  ok "an AGED lock whose owner is gone IS reclaimable"
else
  bad "dead owner reclaimable" "refused to reclaim a provably dead, aged lock"
fi

# --- fail-closed cases: every one of these must REFUSE ------------------------
mk_lock() { # <key> <owner-file-contents>
  mkdir -p "$EW_SEED_ROOT/.locks/$1"
  printf '%s' "$2" > "$EW_SEED_ROOT/.locks/$1/owner"
  touch -t 202001010000 "$EW_SEED_ROOT/.locks/$1"
}

mk_lock unknownver "version=99
pid=$DEAD_PID
started=Mon Jan  1 00:00:00 2020"
warn_out="$(ew_seed_lock_is_reclaimable unknownver 60 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an UNKNOWN protocol version fails closed (a newer checkout wrote it)"
else
  bad "unknown protocol version" "reclaimed a lock written by a version we do not implement"
fi
# It must also SAY SO. An aged lock we decline to judge sits forever, and silent
# refusal is indistinguishable from "there was nothing to do".
if printf '%s' "$warn_out" | grep -q "unknown protocol version"; then
  ok "an unknown-version refusal is ANNOUNCED, not silent"
else
  bad "unknown-version warning" "refused silently: '$warn_out'"
fi

mk_lock malformed "pid=notanumber
version=$EW_SEED_LOCK_VERSION
started=x"
warn_out="$(ew_seed_lock_is_reclaimable malformed 60 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a MALFORMED owner record fails closed"
else
  bad "malformed pid" "reclaimed a lock with an unparseable pid"
fi
if printf '%s' "$warn_out" | grep -q "malformed owner record"; then
  ok "a malformed-record refusal is ANNOUNCED, not silent"
else
  bad "malformed warning" "refused silently: '$warn_out'"
fi

# --- an ownerless lock: FRESH must be kept, AGED must be reclaimed -------------
# This replaces an assertion that refused EVERY ownerless lock. That was right
# while the owner record was written by a plain redirect, because a partial file
# was possible and a half-acquired lock had to be assumed live. The record is now
# renamed into place, so `owner` is either absent or complete, and "absent" only
# ever means the acquirer died between `mkdir` and the rename — microseconds.
# What the old assertion protected (never stealing a lock from a live acquirer)
# is now carried by the AGE check, which the fresh case below proves. The old
# behaviour had a cost the new one removes: a process killed inside that gap left
# a lock NOTHING could reclaim, so the key lost seeding permanently.
mkdir -p "$EW_SEED_ROOT/.locks/freshnoowner"
if ew_seed_lock_is_reclaimable freshnoowner 60; then
  bad "fresh ownerless lock" "stole a lock from an acquirer that is still mid-write"
else
  ok "a FRESH lock with no owner file is left alone (age is what protects it)"
fi

mkdir -p "$EW_SEED_ROOT/.locks/noowner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/noowner"
if ew_seed_lock_is_reclaimable noowner 60; then
  ok "an AGED lock with no owner file IS reclaimed (the acquirer died in the gap)"
else
  bad "aged ownerless lock" "left a stranded lock that nothing else can ever clear"
fi

if ew_seed_lock_is_reclaimable neverexisted 60; then
  bad "absent lock" "claimed a nonexistent lock is reclaimable"
else
  ok "an ABSENT lock is not reclaimable"
fi

# --- the lock is TRACKED before anything interruptible happens ----------------
# A signal between `mkdir` and the tracking line strands a lock the EXIT cleanup
# does not know about. Order cannot be tested by sending a signal at the right
# microsecond, so it is tested from INSIDE the window: the owner record calls
# `ew_seed_process_identity`, which runs AFTER the tracking line, so shadowing it
# lets the test observe the array at that exact moment. If the tracking line
# moves back below the write, this records "no" and the case goes red.
ORDER_PROBE="$TMPROOT/order-probe"
_real_identity_body="$(declare -f ew_seed_process_identity)"
ew_seed_process_identity() {
  local d="$EW_SEED_ROOT/.locks/ordering" i seen=no
  if i="$(_ew_seed_find_lock ordering)" && [ "${_EW_SEED_R_PATH[$i]}" = "$d" ]; then seen=yes; fi
  printf '%s\n' "$seen" > "$ORDER_PROBE"
  printf 'probe-identity\n'
}
require_owned_acquire ordering >/dev/null 2>&1
eval "$_real_identity_body"
if [ "$(cat "$ORDER_PROBE" 2>/dev/null)" = "yes" ]; then
  ok "the lock is registered for cleanup BEFORE its owner record is written"
else
  bad "tracking order" "the lock was still untracked while the owner record was being written"
fi
ew_seed_lock_release ordering

# --- the owner record is renamed into place, never written in place -----------
# A partial record is PERMANENT: `is_reclaimable` refuses an unknown version, so
# a truncated `version=` would make that key read as busy for the life of the
# machine. Atomicity is what makes "absent or complete" the only two states.
require_owned_acquire atomicowner >/dev/null 2>&1
_leftover=0
for _t in "$EW_SEED_ROOT/.locks/atomicowner"/.owner.*; do
  [ -e "$_t" ] && _leftover=$((_leftover + 1))
done
if [ "$_leftover" -eq 0 ] && [ -f "$EW_SEED_ROOT/.locks/atomicowner/owner" ] \
   && [ "$(sed -n 's/^version=//p' "$EW_SEED_ROOT/.locks/atomicowner/owner")" = "$EW_SEED_LOCK_VERSION" ]; then
  ok "a successful acquire leaves a COMPLETE owner record and no staging file"
else
  bad "atomic owner" "leftover=$_leftover owner=$(cat "$EW_SEED_ROOT/.locks/atomicowner/owner" 2>/dev/null | tr '\n' ' ')"
fi
ew_seed_lock_release atomicowner

# THE TWIN: when the rename fails, acquire must leave NOTHING — no lock
# directory for others to trip over, and no entry in the cleanup list pointing
# at a path that no longer exists.
_ew_seed_publish_owner() { return 1; }
_before="$(_ew_seed_count_kind lock)"
ew_seed_lock_acquire rollback >/dev/null 2>&1; _rc=$?
. "$HERE/spm-seed-lock.sh"
if [ "$_rc" -ne 0 ] && [ ! -e "$EW_SEED_ROOT/.locks/rollback" ] \
   && [ "$(_ew_seed_count_kind lock)" -eq "$_before" ]; then
  ok "a failed owner write rolls the lock back completely (the twin)"
else
  bad "acquire rollback" "rc=$_rc dir_present=$([ -e "$EW_SEED_ROOT/.locks/rollback" ] && echo yes || echo no) tracked=$(_ew_seed_count_kind lock) was=$_before"
fi

# --- liveness has THREE answers, and the third one used to be silent ----------
# "Cannot tell" was collapsed into "dead". The identity helper printed a string
# and an EMPTY string meant gone — but empty is also what a missing or failing
# process tool produces, and the caller's comment said "provably dead". Reading
# it that way takes the lock from a LIVE owner, which is the grant-too-often
# direction: two writers on one snapshot, or a purge deleting a tree mid-clone.
# Neither whole-diff review round found this; it came out of enumerating the
# class the two rounds belonged to.
live_id="$(ew_seed_process_identity "$$" 2>/dev/null)"; live_rc=$?
if [ "$live_rc" -eq 0 ] && [ -n "$live_id" ]; then
  ok "a LIVE pid returns 0 and an identity"
else
  bad "identity live" "rc=$live_rc id='$live_id' — a live pid did not report as alive"
fi

ew_seed_process_identity 999998 >/dev/null 2>&1; dead_rc=$?
if [ "$dead_rc" -eq 1 ]; then
  ok "an ABSENT pid returns 1 (provably dead)"
else
  bad "identity absent" "rc=$dead_rc — a dead pid did not report as provably absent"
fi

( EW_SEED_PS="$TMPROOT/no-such-tool"; ew_seed_process_identity "$$" >/dev/null 2>&1 ); broken_rc=$?
if [ "$broken_rc" -eq 2 ]; then
  ok "a BROKEN process tool returns 2 (could not tell) — never confused with dead"
else
  bad "identity indeterminate" "rc=$broken_rc — a broken tool did not report as indeterminate"
fi

# THE CONSEQUENCE, which is what actually matters: an aged lock whose owner
# cannot be checked must be LEFT ALONE. Its pid is this very test process, so a
# reclaim here would be stealing from a demonstrably live owner.
mkdir -p "$EW_SEED_ROOT/.locks/livecheck"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
  printf 'pid=%s\n' "$$"
  printf 'started=%s\n' "$(ew_seed_process_identity "$$")"; } > "$EW_SEED_ROOT/.locks/livecheck/owner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/livecheck"
warn_out="$( EW_SEED_PS="$TMPROOT/no-such-tool"; ew_seed_lock_is_reclaimable livecheck 60 2>&1 )"
( EW_SEED_PS="$TMPROOT/no-such-tool"; ew_seed_lock_is_reclaimable livecheck 60 >/dev/null 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then
  ok "an aged lock whose owner CANNOT be checked is left alone (never assumed dead)"
else
  bad "indeterminate reclaim" "reclaimed a lock from an owner it could not check — this process is alive"
fi
if printf '%s' "$warn_out" | grep -q "could not determine whether pid"; then
  ok "the could-not-check refusal is ANNOUNCED, not silent"
else
  bad "indeterminate warning" "refused silently: '$warn_out'"
fi

# THE TWIN: with a working tool and the same aged lock, a LIVE owner is still
# refused. Without this, a fix that simply refuses everything looks correct.
if ew_seed_lock_is_reclaimable livecheck 60 >/dev/null 2>&1; then
  bad "live owner reclaim" "reclaimed a lock held by a live process"
else
  ok "an aged lock held by a LIVE owner is refused with a working tool too (the twin)"
fi
rm -rf "$EW_SEED_ROOT/.locks/livecheck"

# --- a FAILED age probe is announced, not silently read as "not old enough" ----
# `2>/dev/null` on a probe whose emptiness you interpret destroys the channel
# separating "asked correctly, the answer is no" from "the question was
# malformed". A malformed age argument makes `find` error; both readings refuse,
# but only one of them says why.
mkdir -p "$EW_SEED_ROOT/.locks/badage"
printf 'version=%s\npid=%s\nstarted=x\n' "$EW_SEED_LOCK_VERSION" "$$" > "$EW_SEED_ROOT/.locks/badage/owner"
warn_out="$(ew_seed_lock_is_reclaimable badage "not-a-number" 2>&1)"
ew_seed_lock_is_reclaimable badage "not-a-number" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$warn_out" | grep -q "age probe failed"; then
  ok "a failed age probe refuses AND says so"
else
  bad "age probe" "rc=$rc out='$warn_out'"
fi
rm -rf "$EW_SEED_ROOT/.locks/badage"

# --- acquire REFUSES rather than take a lock it could never release -----------
# A lock whose owner record carries no start identity is refused by the judge for
# the life of the machine, so writing one is strictly worse than not taking the
# lock: a cache miss costs one slow resolve, an unreclaimable lock costs this key
# its seeding forever. This case exists because a mutation control found the
# guard untested — the fix was in place and nothing would have noticed it going.
_saved_ps="$EW_SEED_PS"; EW_SEED_PS="$TMPROOT/no-such-tool"
ew_seed_lock_acquire noidentity >/dev/null 2>&1; rc=$?
EW_SEED_PS="$_saved_ps"
if [ "$rc" -ne 0 ] && [ ! -e "$EW_SEED_ROOT/.locks/noidentity" ]; then
  ok "acquire REFUSES when it cannot establish its own identity, and leaves nothing"
else
  bad "acquire without identity" "rc=$rc dir=$([ -e "$EW_SEED_ROOT/.locks/noidentity" ] && echo present || echo absent)"
fi

# THE TWIN: with a working tool the same key acquires normally and records a
# start identity a judge can actually use.
if require_owned_acquire noidentity >/dev/null 2>&1 \
   && [ -n "$(sed -n 's/^started=//p' "$EW_SEED_ROOT/.locks/noidentity/owner")" ]; then
  ok "acquire succeeds with a working tool and records a usable identity (the twin)"
else
  bad "acquire identity twin" "acquire failed or wrote an empty start identity"
fi
ew_seed_lock_release noidentity

# --- an abandoned lock is reclaimed by ACQUIRE, in shipped code ---------------
# `ew_seed_lock_is_reclaimable` existed and its only caller was the gitignored
# purge script, so on a fresh clone or any other machine an abandoned lock was
# PERMANENT and that key lost seeding forever. Same class as a cache that only an
# untracked script could prune: a mechanism whose recovery lives outside the
# shipped tree has no recovery.
mkdir -p "$EW_SEED_ROOT/.locks/abandoned"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
  printf 'pid=%s\n' 999998
  printf 'started=Thu Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/abandoned/owner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/abandoned"
if require_owned_acquire abandoned >/dev/null 2>&1; then
  ok "acquire RECLAIMS an aged lock whose owner is provably dead"
else
  bad "acquire reclaim" "an abandoned lock stayed locked forever — seeding lost for that key"
fi
ew_seed_lock_release abandoned

# THE TWIN, and it is the one that matters: a lock held by a LIVE owner is never
# stolen, however old. Without it, a reclaim-everything version looks correct.
mkdir -p "$EW_SEED_ROOT/.locks/liveheld"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
  printf 'pid=%s\n' "$$"
  printf 'started=%s\n' "$(ew_seed_process_identity "$$")"; } > "$EW_SEED_ROOT/.locks/liveheld/owner"
touch -t 202001010000 "$EW_SEED_ROOT/.locks/liveheld"
if ew_seed_lock_acquire liveheld >/dev/null 2>&1; then
  bad "acquire reclaim scope" "stole a lock from a LIVE owner — two writers on one snapshot"
else
  ok "acquire never reclaims a lock whose owner is alive, however aged (the twin)"
fi

# A FRESH lock is not a candidate at all: age is what separates "abandoned" from
# "somebody just took it".
mkdir -p "$EW_SEED_ROOT/.locks/freshheld"
{ printf 'version=%s\n' "$EW_SEED_LOCK_VERSION"
  printf 'pid=%s\n' 999998
  printf 'started=Thu Jan  1 00:00:00 2020\n'; } > "$EW_SEED_ROOT/.locks/freshheld/owner"
if ew_seed_lock_acquire freshheld >/dev/null 2>&1; then
  bad "acquire reclaim age" "reclaimed a lock taken moments ago"
else
  ok "a FRESH lock is never reclaimed by acquire, dead owner or not"
fi

# #4197 lifecycle obligations: state, not a pathname alone, grants cleanup.
mkdir -p "$EW_SEED_ROOT/.locks/unheld"
printf keep > "$EW_SEED_ROOT/.locks/unheld/sentinel"
ew_seed_lock_release unheld
if [ -f "$EW_SEED_ROOT/.locks/unheld/sentinel" ]; then ok "unheld release cannot delete an existing key"; else bad "unheld release" "deleted foreign state"; fi

require_owned_acquire reload
_reload_count="$_EW_SEED_NEXT"
. "$HERE/spm-seed-lock.sh"
if [ "$_EW_SEED_NEXT" = "$_reload_count" ] && _ew_seed_find_lock reload >/dev/null; then ok "same-source reload preserves active registry"; else bad "reload" "lost ownership"; fi
mkdir "$TMPROOT/other-source"
cp "$HERE/spm-seed-lock.sh" "$TMPROOT/other-source/spm-seed-lock.sh"
if . "$TMPROOT/other-source/spm-seed-lock.sh"; then _reload_rc=0; else _reload_rc=$?; fi
if [ "$_reload_rc" = 2 ] && [ "$_EW_SEED_ORIGIN" = "$HERE" ] && _ew_seed_find_lock reload >/dev/null; then ok "active different-source reload refuses before replacing cleanup"; else bad "source swap" "status=$_reload_rc origin=$_EW_SEED_ORIGIN"; fi
(ew_seed_lock_release reload)
if [ -f "$EW_SEED_ROOT/.locks/reload/owner" ]; then ok "inherited subshell cannot release its parent's ownership"; else bad "subshell release" "deleted parent lock"; fi
ew_seed_lock_release reload

require_owned_acquire retained
if ! ew_seed_begin_temp retained "$TMPROOT" "$TMPROOT/.SourcePackages.seed.retained.1" || [ ! -d "$TMPROOT/.SourcePackages.seed.retained.1" ]; then bad "retained staging setup" "creation failed"; exit 1; fi
require_owned_acquire healthy
python3() {
  if [ "${1:-}" = "$_EW_SEED_HELPER" ] && [ "${2:-}" = remove ] && [ "${4:-}" = "$TMPROOT/.SourcePackages.seed.retained.1" ]; then return 1; fi
  command python3 "$@"
}
ew_seed_release_all
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ -d "$EW_SEED_ROOT/.locks/retained" ] && [ ! -e "$EW_SEED_ROOT/.locks/healthy" ]; then ok "release_all aggregates a failed temp before a successful later key"; else bad "aggregate cleanup" "lost incomplete result or protection"; fi
if [ ! -e "$EW_SEED_ROOT/.mutations/retained" ] && [ -d "$TMPROOT/.SourcePackages.seed.retained.1" ]; then ok "failed temp retains long key protection but releases valid short gate"; else bad "gate lifetime" "wrong retention"; fi
unset -f python3
ew_seed_release_all
if [ "$EW_SEED_CLEANUP_COMPLETE" = 1 ] && [ ! -e "$EW_SEED_ROOT/.locks/retained" ] && [ ! -e "$TMPROOT/.SourcePackages.seed.retained.1" ]; then ok "retained cleanup can retry its captured instance"; else bad "retry cleanup" "state survived"; fi

require_owned_acquire partialowner
_partial_owner="$(cat "$EW_SEED_ROOT/.locks/partialowner/owner")"
python3() {
  if [ "${1:-}" = "$_EW_SEED_HELPER" ] && [ "${2:-}" = remove ] && [ "${4:-}" = "$EW_SEED_ROOT/.locks/partialowner" ]; then
    command rm -f "$EW_SEED_ROOT/.locks/partialowner/owner"
    return 1
  fi
  command python3 "$@"
}
ew_seed_lock_release partialowner
unset -f python3
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ "$(cat "$EW_SEED_ROOT/.locks/partialowner/owner")" = "$_partial_owner" ] && [ ! -e "$EW_SEED_ROOT/.mutations/partialowner" ]; then ok "partial owner deletion restores exact v1 bytes before releasing gate"; else bad "owner restoration" "lost protection or released uncertain gate"; fi
ew_seed_lock_release partialowner

require_owned_acquire failedrestore
python3() {
  if [ "${1:-}" = "$_EW_SEED_HELPER" ] && [ "${2:-}" = remove ] && [ "${4:-}" = "$EW_SEED_ROOT/.locks/failedrestore" ]; then
    command rm -f "$EW_SEED_ROOT/.locks/failedrestore/owner"
    return 1
  fi
  command python3 "$@"
}
_ew_seed_publish_owner() { return 1; }
ew_seed_lock_release failedrestore
unset -f python3
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ -d "$EW_SEED_ROOT/.mutations/failedrestore" ] && [ -d "$EW_SEED_ROOT/.locks/failedrestore" ] && [ ! -e "$EW_SEED_ROOT/.locks/failedrestore/owner" ]; then ok "failed owner restoration retains the short gate and registered state"; else bad "failed restoration" "uncertain survivor exposed"; fi
. "$HERE/spm-seed-lock.sh"
ew_seed_lock_release failedrestore
ew_seed_lock_release failedrestore
if [ "$EW_SEED_CLEANUP_COMPLETE" = 1 ] && [ ! -e "$EW_SEED_ROOT/.mutations/failedrestore" ] && [ ! -e "$EW_SEED_ROOT/.locks/failedrestore" ]; then ok "verified retained gate can restore protection then complete its own cleanup"; else bad "retained gate retry" "did not complete"; fi

require_owned_acquire stagingroot
_consumer_root="$TMPROOT/consumer-root"; mkdir "$_consumer_root"
if ! ew_seed_begin_temp stagingroot "$_consumer_root" "$_consumer_root/.SourcePackages.seed.stagingroot.1"; then bad "bound staging setup" "creation failed"; exit 1; fi
printf keep > "$_consumer_root/.SourcePackages.seed.stagingroot.1/sentinel"
mv "$_consumer_root" "$TMPROOT/original-consumer-root"; mkdir "$_consumer_root"
ew_seed_lock_release stagingroot
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ -d "$EW_SEED_ROOT/.locks/stagingroot" ] && [ "$(_ew_seed_count_kind temp)" = 1 ] && [ -f "$TMPROOT/original-consumer-root/.SourcePackages.seed.stagingroot.1/sentinel" ]; then ok "absent staging under a replaced root cannot erase captured cleanup authority"; else bad "staging root replacement" "false completion or lost original staging"; fi
rmdir "$_consumer_root"; mv "$TMPROOT/original-consumer-root" "$_consumer_root"
ew_seed_lock_release stagingroot
if [ "$EW_SEED_CLEANUP_COMPLETE" = 1 ] && [ ! -e "$_consumer_root/.SourcePackages.seed.stagingroot.1" ] && [ ! -e "$EW_SEED_ROOT/.locks/stagingroot" ]; then ok "restoring captured staging root permits ordinary cleanup retry"; else bad "staging root retry" "did not complete"; fi

require_owned_acquire intentroot
if ! ew_seed_track_temp "$_consumer_root/.SourcePackages.seed.intentroot.1" "$_consumer_root" intentroot; then bad "intent staging setup" "registration failed"; exit 1; fi
mkdir "$_consumer_root/.SourcePackages.seed.intentroot.1"
mv "$_consumer_root" "$TMPROOT/original-intent-root"; mkdir "$_consumer_root"
ew_seed_lock_release intentroot
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ -d "$EW_SEED_ROOT/.locks/intentroot" ] && [ -d "$TMPROOT/original-intent-root/.SourcePackages.seed.intentroot.1" ]; then ok "unbound intent also retains authority when its captured root is replaced"; else bad "intent root replacement" "false absence completion"; fi
rmdir "$_consumer_root"; mv "$TMPROOT/original-intent-root" "$_consumer_root"
# An unbound new entry is never adopted, even after root restoration. Only
# private fixture teardown removes it; verified absence then completes intent.
rm -rf "$_consumer_root/.SourcePackages.seed.intentroot.1"
ew_seed_lock_release intentroot

require_owned_acquire changedroot
_old_root="$EW_SEED_ROOT"
EW_SEED_ROOT="$TMPROOT/unrelated-root"; mkdir "$EW_SEED_ROOT"
printf keep > "$EW_SEED_ROOT/sentinel"
ew_seed_lock_release changedroot
if [ ! -e "$_old_root/.locks/changedroot" ] && [ -f "$EW_SEED_ROOT/sentinel" ]; then ok "release uses captured root after configuration changes"; else bad "captured root" "wrong namespace touched"; fi
EW_SEED_ROOT="$_old_root"

python3() {
  if [ "${1:-}" = "$_EW_SEED_HELPER" ] && [ "${2:-}" = rmdir ] && [ "${4:-}" = "$EW_SEED_ROOT/.mutations/replacedgate" ]; then
    mv "$EW_SEED_ROOT/.mutations/replacedgate" "$TMPROOT/original-gate"
    mkdir "$EW_SEED_ROOT/.mutations/replacedgate"
  fi
  command python3 "$@"
}
require_owned_acquire replacedgate
unset -f python3
ew_seed_lock_release replacedgate
if [ "$EW_SEED_CLEANUP_COMPLETE" = 0 ] && [ -d "$EW_SEED_ROOT/.mutations/replacedgate" ] && [ -f "$EW_SEED_ROOT/.locks/replacedgate/owner" ]; then ok "changed gate identity is retained and cannot authorize key cleanup"; else bad "replaced gate" "unknown instance was adopted"; fi
# Private fixture restores its two known empty instances; production never does.
rmdir "$EW_SEED_ROOT/.mutations/replacedgate"
mv "$TMPROOT/original-gate" "$EW_SEED_ROOT/.mutations/replacedgate"
ew_seed_lock_release replacedgate
if [ "$EW_SEED_CLEANUP_COMPLETE" = 1 ] && [ ! -e "$EW_SEED_ROOT/.mutations/replacedgate" ] && [ ! -e "$EW_SEED_ROOT/.locks/replacedgate" ]; then ok "only the original verified gate can resume retained cleanup"; else bad "gate identity retry" "original could not resume or paths survived"; fi

_literal_key=$'literal space\nquote"dollar$'
if require_owned_acquire "$_literal_key"; then
  ew_seed_lock_release "$_literal_key"
  if [ "$EW_SEED_CLEANUP_COMPLETE" = 1 ] && [ ! -e "$EW_SEED_ROOT/.locks/$_literal_key" ]; then ok "literal whitespace and shell characters remain key data"; else bad "literal key release" "incomplete"; fi
else bad "literal key" "valid literal component refused"; fi
_saved_helper="$_EW_SEED_HELPER"; _EW_SEED_HELPER="$TMPROOT/no-such-helper"
if ew_seed_lock_acquire missinghelper; then bad "missing helper" "granted without physical authority"; else ok "missing helper makes a cache miss before creating a key"; fi
_EW_SEED_HELPER="$_saved_helper"
if /bin/bash -c 'python3() { return 91; }; . "$1"' fixture "$HERE/spm-seed-lock.sh"; then ok "fresh source performs no Python dependency or metadata probes"; else bad "source probes" "startup depended on physical helper"; fi

mkdir -p "$EW_SEED_ROOT/.mutations/stranded"
if ew_seed_lock_acquire stranded; then bad "stranded gate" "automatically reclaimed unknown gate"; else ok "unknown mutation gate stays busy without automatic reclamation"; fi
if ew_seed_lock_acquire .mutations; then bad "hidden key" "accepted reserved namespace"; else ok "hidden metadata cannot be a key even under dotglob"; fi

if /bin/bash -c 'set -e; . "$1"; trap "ew_seed_on_exit" EXIT; ew_seed_lock_acquire exitstatus; [ -f "$EW_SEED_ROOT/.locks/exitstatus/owner" ]; record="$(_ew_seed_find_lock exitstatus)"; [ "${_EW_SEED_R_PHASE[$record]}" = published ]; exit 7' fixture "$HERE/spm-seed-lock.sh"; then _exit_rc=0; else _exit_rc=$?; fi
if [ "$_exit_rc" = 7 ] && [ ! -e "$EW_SEED_ROOT/.locks/exitstatus" ]; then ok "set-e EXIT cleanup preserves original failure status"; else bad "EXIT status" "status=$_exit_rc or lock survived"; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 32 ]; then
  printf 'ERROR: expected at least 32 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
