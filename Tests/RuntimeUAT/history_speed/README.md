# History speed instruments (#4586)

Drivers that measure History on a founder-free ~27k library against the #4586 budgets. Plan:
`docs/feature-requests/issue-4586-2026-11-17-wpa-instruments.md` (main checkout).

| Number | Driver | Budget | Meaning |
|---|---|---|---|
| Search | `m5-speed-ui-search.py run` | p95 ≤ 50 ms | Keyboard event posted (timestamp taken after the frontmost/identity checks) to the first captured frame showing the verified complete, correct page. |
| Open History | `m5-speed-open.py --mode missing\|existing` | p95 ≤ 300 ms | App spawn to the first captured frame showing the complete, correct first Dictations page. `missing` deletes only the derived catalog before each launch (not a reboot-cold launch). |
| Scroll hitch | `m5-speed-scroll.py` | ≤ 5 ms per moving second | Apple's `xctrace` Animation Hitches rows of the subject's process that overlap a moving span, divided by the moving seconds (frame recorder). Not the same metric as a per-step scroll duration. |
| Row stability | `m5-speed-scroll.py` | 0 rows | Rows whose AX height changed by > 1 pt after it was first sampled on screen (sampled about every 40 ms; zero samples is not proof of zero drawn changes). |
| Travel symmetry | `m5-speed-scroll.py` | ≤ 2% | The same gesture down then up; travel is the first row's screen y before and after each gesture. |
| Show edits, Play | `m5-speed-card.py` | none set | Press to the first frame showing the opened edits view / the playing card. Sound goes to BlackHole and is restored. |
| Resources | all drivers (`load_tools.ResourceSampler`) | none set | Subject CPU seconds and peak resident memory per phase (`ps` every 250 ms). |

Every report carries `budget_verdict` (`PASS` only when every sample was measured and inside budget;
`FAIL` when over budget or wrong; `UNPROVEN` when evidence is missing) and machine conditions (load
average, running `xcodebuild`/`swift-frontend`/`codex` counts). A number taken while peers build is
not a quiet-machine number; `--busy` runs one busy loop per performance core on purpose.

## Build the subject and recorder

```bash
Tests/RuntimeUAT/history_speed/build-release-subject.sh
```

```bash
mkdir -p build/history_speed && swiftc -O -o build/history_speed/frame_recorder Tests/Fixtures/history-speed/frame_recorder.swift
```

The first prints the Release app path and its executable sha256 (the pin every run checks).
`frame_recorder` needs the Screen Recording grant for the shell that runs it.

## Run

All live runs need the dev-app lock first (`python3 <main>/scripts/lib/dev-app-lock.py claim --label ...`,
in its own call; release it after). `containment_pilot.py` prepares the renamed subject
(`com.enviouswispr.app.historyspeed`), a fresh fixture home from the seed, launches inside
`fixture.ContainedSession`, waits for full catalog coverage, runs one driver and cleans up.

```bash
S=/Users/m4pro_sv/Developer/AgentArtifacts/enviouswispr/runs/2026/11/20261115-020456-4586-history-speed-pr0-fixture-54bb/seed
python3 -B Tests/RuntimeUAT/history_speed/containment_pilot.py <app> <sha256> "$S" <new run dir> --run Tests/RuntimeUAT/history_speed/search_cases.json 20
python3 -B Tests/RuntimeUAT/history_speed/containment_pilot.py <app> <sha256> "$S" <new run dir> --scroll --idle --repeats 3
python3 -B Tests/RuntimeUAT/history_speed/containment_pilot.py <app> <sha256> "$S" <new run dir> --card --repeats 10
python3 -B Tests/RuntimeUAT/history_speed/containment_pilot.py <app> <sha256> "$S" <new run dir> --open missing 20
```

Scroll options: `--start-pt 40000` (deep: more than ten loaded pages), `--tabs Meetings` (long cards),
`--busy`; `containment_pilot.py --scroll-early` starts the scroll before catalog coverage (scrolling
while background indexing runs). Search: `--only <series>`, `--busy`.

## Controls (each driver shown able to fail)

- Search: offline `search_test.py` (a prefix page is `incomplete`, containment is not a match, wrong
  day totals fail); live, a case whose answer is computed for another query never times.
- Open: `--control drop-row` (one expected row removed): no sample may confirm, verdict FAIL.
- Scroll: offline `scroll_analysis_test.py`; live `--control short-return` (up gesture half as long)
  must FAIL travel; the busy-Mac run shows the hitch number rising.

Offline tests (no app, no lock):

```bash
python3 -B -m unittest discover -s Tests/RuntimeUAT/history_speed -p '*_test.py' -v
```

## Fixture and isolation

`fixture.py` owns the seed (three source categories plus a SHA-256 manifest; current seed: run folder
`20261115-020456-4586-history-speed-pr0-fixture-54bb/seed`, 29,627 transcript files, 90,119 meeting
files, 99 recordings), fresh working homes, launches and stops. A launch sets `HOME` and
`CFFIXED_USER_HOME` to the working home and runs the renamed subject under `sandbox-exec` (denies the
real History folders, real EnviousWispr preference writes, containers, logs, credentials fallbacks and
all outbound network). Every launch route (drivers, runner and the `fixture.py launch` CLI) refuses an
app whose bundle identifier is not the renamed subject, so production can never be started.
The cleanup deletes only the renamed subject's own state in the real home: the
`com.enviouswispr.app.historyspeed` defaults domain, its `Library/Preferences/…historyspeed.plist`,
`Library/HTTPStorages/…historyspeed` and its cookies file, and nothing else. It runs only after
`refuse_existing_throwaway` proved none of that existed before the session (`ContainedSession`,
`m5-speed-open.py`). The production domain is compared before and after; a change is a finding,
never restored over.

## Known limits

- AX reads run on the app's main thread: the scroll hitch pass makes none while gestures run.
- Synthetic trackpad events carry no device momentum (no fling); the founder's hand test follows.
- Screen capture misses some drawn frames: every timed number is an upper bound on the first correct
  picture, and brief stale frames between captures cannot be seen.
- `xctrace` stops by its own time limit (a SIGINT stop hung and never saved, #4587); saving takes
  one to three minutes on a loaded Mac.
- Page queries during indexing (< 15 ms) are NOT MEASURED on current main: the page SQL uses the
  app's Swift `history_contains`. After package C lands, its `HistoryPage` signpost interval can be
  read from the same xctrace recording.
- The search oracle matches ASCII text with `casefold()` and everything else with Foundation's
  case-insensitive search pinned to the fixture app's locale (`pin_locale`).
