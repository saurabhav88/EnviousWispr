# Issue #478 — RotatingFileSink: handle short writes from `write(2)` — 2026-04-30

GitHub issue: `#478`. Parent / epic: none (Codex follow-up to #476 Phase R4). Tier: SMALL. Status: DRAFT.

## Preface — Lane + Live UAT declaration

**Lane:** Code (`Sources/EnviousWisprAudio/RotatingFileSink.swift`, `Tests/EnviousWisprTests/Core/RotatingFileSinkTests.swift`).

**Live UAT:** N — internal log-sink infrastructure with no app/UI surface. Correctness is unit-testable via the `writeAllBytes` testable seam. Smoke + logic tests cover the production path; no human-observable behavior changes for the user.

## Preface — User Rubric

User Rubric: N/A — internal log-infrastructure follow-up to Phase R4 (#319 Bible). No user-visible surface; users never read `bt-route.log`.

## Preface — Council/Codex routing

`council-skip: codex-grounded-review settled the only structural fork, no user surface, no design ambiguity remaining` (per `.claude/rules/workflow-process.md §1` "Codex grounded review settles the only fork" exception).

Disqualifier check (all clear):
- No workflow gate / template / lane / hook / memory rule change.
- No numerical target with ambiguous measurement.
- No fitness gate.
- No CI workflow change.

Codex already prescribed the exact fix in the issue body; this plan executes it.

## 0. TL;DR

`RotatingFileSink.atomicAppendWithRotation` issues a single `write(2)` and discards the return value. POSIX `write(2)` may legally return fewer bytes than requested (or `-1` with `errno == EINTR`) even on regular files under signal/IO-pressure. Today, that silently truncates a log line and proceeds into the size/rotation check, breaking the sink's "no torn lines" invariant. Fix: extract a `writeAllBytes` loop that retries on `EINTR` and advances on short writes until all bytes are committed or a hard error fires. Tests use a closure-injected variant to simulate short writes / EINTR / hard errors deterministically.

## 1. Problem

The current append path:

```swift
_ = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Int in
  guard let base = buf.baseAddress else { return 0 }
  return write(logFd, base, buf.count)
}
```

ignores the return value. Three failure modes:

1. **Short write.** `write(2)` returns `n < buf.count` — tail of the message is silently dropped. Concurrent in-process tests claim "no torn lines"; a real short write breaks that.
2. **EINTR.** `write(2)` returns `-1` with `errno == EINTR` — the entire write is silently lost.
3. **Hard error.** `write(2)` returns `-1` with `errno != EINTR` — silently dropped, but at least the line vanishes cleanly.

Cases 1 and 2 are the real defect — partial / no data lands but rotation still fires.

## 2. Goals & non-goals

**Goals.**
- Preserve the "no torn lines" invariant under short writes and EINTR.
- Keep the public API and call shape identical (single-line `sink.append(message)`).
- Keep the lock model identical (in-process unfair lock + cross-process flock on stable companion).
- Add a testable seam so the loop's correctness is verified deterministically, not by chance.

**Non-goals.**
- Surfacing write failures to callers. The sink is best-effort logging; silent degrade is the documented contract.
- Changing rotation behavior on partial-write-followed-by-rotation. Already correct: the `fstat` size check sees only what landed, so a partially-written line never triggers premature rotation in a way that breaks today's semantics. Post-fix, full lines always land before the size check, so rotation logic is unchanged.
- Surfacing failures to a metrics counter. Out of scope; reserve for a follow-up if real-world sinks start dropping.

## 3. Design

Extract a private static helper:

```swift
/// Writes `count` bytes from `base` to the file descriptor via `write(2)`,
/// looping on short writes and retrying on EINTR. Returns true if all bytes
/// were written; false on a hard error (errno != EINTR) or zero-byte write
/// (which would otherwise spin forever on a regular file).
private static func writeAllBytes(
  _ fd: Int32,
  _ base: UnsafeRawPointer,
  _ count: Int
) -> Bool {
  writeAllBytes(base, count) { ptr, n in
    write(fd, ptr, n)
  }
}

/// Test seam — same loop logic, but the syscall is injected. EINTR signaled
/// by returning `-1` and setting `errno = EINTR` BEFORE returning.
internal static func writeAllBytes(
  _ base: UnsafeRawPointer,
  _ count: Int,
  using writeFn: (UnsafeRawPointer, Int) -> Int
) -> Bool {
  var remaining = count
  var cursor = base
  while remaining > 0 {
    let n = writeFn(cursor, remaining)
    if n > 0 {
      cursor = cursor.advanced(by: n)
      remaining -= n
      continue
    }
    if n < 0 && errno == EINTR { continue }
    return false
  }
  return true
}
```

Replace the existing `_ = data.withUnsafeBytes ...` block with:

```swift
_ = data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Bool in
  guard let base = buf.baseAddress else { return false }
  return Self.writeAllBytes(logFd, base, buf.count)
}
```

The `_ =` discard is intentional: the sink is best-effort. We do not propagate failures.

Errors (hard error or zero-write) cause the loop to bail. The active fd is still closed in the existing `defer`-equivalent line (note: today's code uses `close(logFd)` explicitly before rotation, not a defer; the fix preserves that ordering — close before rotate stays).

## 3b. Ownership justification

The helper lives as a `private static` inside `RotatingFileSink` because:
- It is only called from `atomicAppendWithRotation`.
- No other module needs a generic `writeAll` helper (POSIX wrappers are not part of the public Audio API surface).
- A free function in `EnviousWisprCore` would be wrong — Core has no other POSIX-syscall code today and adding one tempts future drift.

If a second caller emerges, promote to a module-level free function in `EnviousWisprAudio` or `EnviousWisprCore`. Until then, encapsulating it inside the only consumer keeps the surface area honest.

## 3a. Metric Definition + Earliest Failure Point

Not architecture-affecting — single-function fix inside an existing well-bounded class.

## 4. Contract deltas

- `RotatingFileSink.append(_:)` — public contract unchanged. Best-effort, silent on failure. The "no torn lines" invariant becomes load-bearing rather than aspirational.
- New private symbol `writeAllBytes(_:_:_:)` (production overload) and `writeAllBytes(_:_:_:using:)` (test seam, `internal` access). Test seam is reachable from `EnviousWisprTests` via `@testable import EnviousWisprAudio`, matching the existing pattern.

No public surface change. No call-site change other than the one inside `atomicAppendWithRotation`.

## 5. E2E state & lifecycle audit

- **Pre-fix:** lock held → write may short → fstat sees partial size → may or may not trigger rotation depending on accumulated truncation → rotate → close → unlock. Correctness hole: log line lost.
- **Post-fix:** lock held → writeAllBytes loops until full or hard-error → fstat sees real post-write size → rotation fires deterministically → close → unlock.

State transitions otherwise identical.

## 6. Downstream consumer matrix

Single caller: `Sources/EnviousWisprAudio/AudioCaptureManager.swift:533` (`btRouteSink`). No other production callers (verified via `grep -rn "RotatingFileSink" Sources/`). Test consumer: `Tests/EnviousWisprTests/Core/RotatingFileSinkTests.swift`. Both unaffected by the change — call shape preserved.

## 7. Failure-mode × caller table

| Caller | Failure mode | Today | Post-fix |
|---|---|---|---|
| `btRouteSink.append(line)` from `AudioCaptureManager` | full success | line written | line written |
| same | short write (n < count) | line truncated, no error | line written via loop |
| same | EINTR | line dropped silently | line written after retry |
| same | hard error (EIO/ENOSPC) | line dropped silently | line dropped silently (best-effort contract preserved) |
| same | zero-byte write (rare on regular files) | infinite loop possible if loop existed naively | loop bails to avoid spin |

## 8. Caller-visible signals audit

`append` returns `Void`. No signal change. Call sites in `AudioCaptureManager` (`btRouteSink.append("...\n")`) are unchanged.

## 9. Fallback source-of-truth audit

The fallback for "log line could not be written" is documented silent-drop. That stays. The fix removes a silent-drop case (short write); the remaining silent-drop case (hard error) is the only one that should still happen.

## 10. File-by-file changes

- `Sources/EnviousWisprAudio/RotatingFileSink.swift` — extract `writeAllBytes` (production + test-seam overloads), replace single-call write block with the loop helper, update doc comment in the `## Concurrency model` block to mention "writes loop on short / EINTR".
- `Tests/EnviousWisprTests/Core/RotatingFileSinkTests.swift` — add a sub-suite for `writeAllBytes` with five tests (full, short, EINTR retry, hard error, zero-byte). Add one large-buffer integration test that drives `RotatingFileSink.append` with a ≥256 KB payload to exercise the production path.

LOC budget: ~60 LOC source change, ~80 LOC test additions.

## 11. Testing

**Unit tests for `writeAllBytes` (test-seam variant):**

1. `writeAllBytes_fullWriteSucceeds` — single call returns full count → returns true, all bytes consumed.
2. `writeAllBytes_shortWritesAdvanceCursor` — closure returns 100, then 100, then 56 for a 256-byte buffer → returns true, cursor advanced correctly across calls.
3. `writeAllBytes_retriesOnEINTR` — closure returns `-1` with `errno = EINTR` once, then full success → returns true.
4. `writeAllBytes_failsOnHardError` — closure returns `-1` with `errno = EIO` → returns false, no further calls.
5. `writeAllBytes_failsOnZeroWrite` — closure returns 0 → returns false (avoid infinite loop).

**Integration test (production path):**

6. `largeBufferAppendIsIntact` — append a 256 KB message, read file back, verify byte-for-byte equality. Even if no short write occurs in practice, this exercises the loop helper through the production overload.

**Existing tests** must continue to pass:
- `appendOrderPreserved`
- `rotationCapsRetention`
- `concurrentInProcessWritersAreAtomic`
- (cross-process smoke test below line 131)

Run: `scripts/swift-test.sh` exits 0; `swift build -c release` exits 0.

No Live UAT — internal log infrastructure with no user surface (per Preface).

## 12. Blast radius & rollback

- One file, one helper, one call site change in production.
- Single git revert restores prior behavior.
- No data migration, no on-disk format change, no flag.

## 13. Ship criteria

1. `swift build -c release` exits 0.
2. `scripts/swift-test.sh` exits 0 (existing + new tests).
3. Codex code-diff review (`codex review --uncommitted`) reports clean.
4. PR body declares `council-skip: codex-grounded-review settled the only structural fork, no user surface, no design ambiguity remaining`.
5. CI `build-check` green.
6. `gh issue close 478` after merge.

## 14. Open questions

None.

## 15. Related

- Issue #476 (PR that introduced RotatingFileSink — Phase R4 of #319 Bible).
- Issue #362 (BT route log rotation — design context).
- `.claude/rules/architecture-rules.md` Audio/ASR Danger Zones — RotatingFileSink callers must NOT be invoked under RT lock; unchanged by this fix.
