# file_verdict fixtures

Five Transcribe a File runs from 2026-09-13 (Parakeet + EG-1, dev builds at `4eff13f7`..`05f78cae`),
read by `file_verdict.py --self-test` with the `EXPECT` tuples there.

- `<name>.log`: the `app.log` slice from the run's `[SpeakerLabeler]` line to its
  `[TurnStorage] outcome=` line, plus the door lines of the same request, kept to the four categories
  the reader matches (`FileImportCoordinator`, `DebugImportDoor`, `PipelineTiming`, `LLM`). The
  `CorrectionDebug` and `Pipeline` lines, which carry transcript text, are dropped.
- `<name>.row.json`: the History row stripped to the fields the reader uses (`id`, `createdAt`,
  `duration`, `importedFileName`, `text`, `polishedText`, `turns`, `speakerNames`); `text` and
  `polishedText` are same-count placeholders, `turns` is a list of empty objects of the right length.

| name | file | run | door |
|---|---|---|---|
| elon | `4-elon-musk-jre-1470.m4a` (120 min) | 16:52, 338 turns | finished |
| interview | `2-ariana-grande-zach-sang-2018.mp4` (48 min) | 17:04, 209 turns | finished |
| ariana | same file, hand-picked on screen | 20:24, 200 turns | none (`expect_door=False`) |
| short | `clip-ariana-4min.m4a` (4 min) | 18:51, 17 turns | finished |
| stopped | `clip-ariana-4min.m4a`, Stop pressed mid-cleanup | 17:19, `outcome=stopped` | superseded |

Cut with `cut_fixture.py <name> <terminal-stamp> [<row-id>]` beside this file; a new fixture is the same cut from a new run.
