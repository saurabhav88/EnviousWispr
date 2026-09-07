# Live UAT — Parakeet migration (#2697)

Founder ship criteria, 2026-09-07, and his correction the same day: **"synthetic tests don't pass the benchmark here - you need REAL product testing, run the migration live on the laptop."**

So this is not a fixture suite. Every row runs the real Release-configuration app against the founder's REAL `~/Library/Application Support`, his REAL FluidAudio donor folder, and his REAL model bytes. No temporary directory, no redirected root, no injected filesystem. The whole point of the change is what happens to a directory a person already has, and a fixture cannot be wrong in the way that matters.

## Before anything runs

**Clone the donor to a backup first.** `clonefile` makes it instant and nearly free, and it means no scenario on this list can cost the founder his model. Removed at the end, after the final donor listing matches.

**Capture the donor listing** — `size inode path`, every file. Re-captured after EVERY row, not once at the end. Identical is the pass. Anything else is a failure regardless of what else worked, because that listing is the entire promise of #2483.

## The upgrade is a real upgrade

Install the shipped 2.4.7 build. Dictate with it, so the model is genuinely in use and genuinely loaded. Then replace it with the candidate and dictate again. A fresh install dressed as an upgrade proves nothing about the population this change exists for.

---

## Q1 — dictation DURING the migration

Real hotkey, real microphone, real paste into a real app.

| # | Scenario | Pass |
|---|---|---|
| 1.1 | Start a take while the clone is in flight | Correct text lands in the target app. No wedge notice. The take is not lost. |
| 1.2 | Start a take while the hash is in flight | As above, and the wait is visible rather than silent. |
| 1.3 | **Take started in the first second after launch, before migration begins** | As above. The ordering case no design sentence closes. |
| 1.4 | Two warm-ups racing one migration | One migration runs. Neither caller sees a partial directory. |

## Q2 — quitting mid-move

Real quit and real force-kill of the real app, not a cancelled task.

| # | Kill point | Pass on relaunch |
|---|---|---|
| 2.1 | Cmd-Q during the clone | Completes with no user action. |
| 2.2 | `kill -9` during the clone | Completes with no user action. |
| 2.3 | `kill -9` during the hash | Completes. No partial file reaches the install directory. |
| 2.4 | **`kill -9` between the atomic rename and the durable record write** | Completes. The record is not `completed`, the published component is re-verified rather than trusted, nothing valid is re-downloaded. |

2.4 is reachable only by instrumenting it: a `force_migration_stall:<point>` command added to the existing `DebugFaultEndpoint.swift`, alongside `force_xpc_kill` and `force_cancel`. A lifecycle pause, not a guard bypass, logged when it fires, DEBUG-only. The kill itself is real.

## Q3 — repair when the move breaks

Real files on the real disk, really damaged.

| # | Injected fault | Pass |
|---|---|---|
| 3.1 | Corrupt a published file, relaunch | Recovered with no user action. |
| 3.2 | Delete a published file, relaunch | Recovered with no user action. |
| 3.3 | Donor file truncated to a MATCHING size but wrong bytes | Rejected by hash. Costs one clone. Never admitted. |
| 3.4 | Donor made unreadable mid-migration | Migration abandons, world untouched, delivery downloads. |
| 3.5 | Disk exhausted mid-migration | Abandons cleanly. No partial file, no stranded candidate. |
| 3.6 | Donor absent entirely | Normal first install, no new path taken. |

**3.5 does not fill the founder's boot disk.** A real APFS volume with a small size quota is created, the install directory is pointed at it for that row, and it is destroyed afterwards. Real ENOSPC from a real filesystem, no risk to his machine.

**3.3 is the row that matters most.** My design leaned on "wrong bytes always fail to load", which was an assumption about FluidAudio that nobody had verified. This row replaces the assumption with a measurement.

## The one thing a machine cannot do here

Every row above drives the real product end to end, including the real microphone path. What it cannot produce is a human voice. Where the founder wants a take in his own voice — 1.1, 1.3 and the post-upgrade dictation are the ones worth it — he does that take himself and I read the result. I will ask at the moment rather than substitute and call it equivalent.

## Non-negotiable on every row

- Donor `size inode path` listing identical before and after.
- Nothing under `FluidAudio/` created, modified, moved or deleted. Proven by listing, not by reading the code.
- No password prompt, no ownership or permission change anywhere (founder ruling, 2026-09-07).

---

## Two oracles that look right and are not

Both cost a false FAIL during the real run, and both are the same shape: a field
that is PRESENT either way read as if it meant one way.

**`final_source` does NOT mean a download happened.** It appears on every
fetch-path admission, including one where every file was already staged and
skipped. Judging "did the repair go to the network" on its presence reports a
failure on a repair that never touched the network.
**The oracle is the BYTES bucket in the same line**: `bytes=200mb_600mb` is a real
483 MB download, `bytes=under_50mb` is not. Measured both ways on the same
machine, before and after the fix.

**The durable record is written AFTER the files land.** A wait that returns as
soon as 23 files exist and then reads the record sees `None`, because the run is
still hashing to confirm the whole installed set before recording. Gate on the
record itself, never on the file count and then the record.
