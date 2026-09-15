#!/usr/bin/env python3
"""Cut one file_verdict fixture from this Mac's app.log and History.

    python3 cut_fixture.py <name> <terminal-stamp-prefix> [<row-id>]

`<terminal-stamp-prefix>` is the ISO stamp of the run's `[TurnStorage] outcome=` line
(e.g. 2026-09-13T18:51:35); `<row-id>` the History row it stored (omit for a stopped run).
Writes `<name>.log` (the slice from the run's `[SpeakerLabeler]` line to that terminal line,
plus the door lines of the same request, kept to the four categories the reader matches) and
`<name>.row.json` (the row stripped to the fields the reader uses, transcript text replaced by a
same-count placeholder) beside this script.
"""
import json
import os
import re
import sys

LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
ROWS = os.path.expanduser("~/Library/Application Support/EnviousWispr/transcripts")
HERE = os.path.dirname(os.path.abspath(__file__))
KEEP = re.compile(r"\] \[(FileImportCoordinator|DebugImportDoor|PipelineTiming|LLM)\] ")


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    name, stamp = argv[0], argv[1]
    row_id = argv[2] if len(argv) > 2 else None
    lines = open(LOG, encoding="utf-8", errors="replace").read().splitlines()
    end = max(i for i, l in enumerate(lines) if l.startswith(f"[{stamp}") and "[TurnStorage] outcome=" in l)
    start = max(i for i in range(end) if "[SpeakerLabeler] outcome=" in lines[i])
    body = lines[start:end + 1]
    door = []
    if row_id:
        fin = [i for i, l in enumerate(lines) if "[DebugImportDoor]" in l and f"history={row_id}" in l]
        if fin:
            req = re.search(r"request=([0-9a-f-]+)", lines[fin[-1]]).group(1)
            door = [l for l in lines[:fin[-1] + 1] if "[DebugImportDoor]" in l and f"request={req}" in l]
    else:
        acc = [i for i in range(start) if "[DebugImportDoor]" in lines[i] and "status=accepted" in lines[i]]
        if acc:
            req = re.search(r"request=([0-9a-f-]+)", lines[acc[-1]]).group(1)
            door = [l for l in lines[acc[-1]:] if "[DebugImportDoor]" in l and f"request={req}" in l][:2]
    pre = [l for l in door if "status=accepted" in l]
    post = [l for l in door if "status=accepted" not in l]
    kept = [l for l in pre + body + post if KEEP.search(l)]
    with open(os.path.join(HERE, name + ".log"), "w") as fh:
        fh.write("\n".join(kept) + "\n")
    if row_id:
        row = json.load(open(os.path.join(ROWS, row_id + ".json")))
        stripped = {
            "id": row["id"], "createdAt": row["createdAt"], "duration": row.get("duration"),
            "importedFileName": row.get("importedFileName"),
            "text": " ".join(["w"] * len((row.get("text") or "").split())),
            "polishedText": " ".join(["w"] * len((row.get("polishedText") or "").split())),
            "turns": [{}] * len(row.get("turns") or []),
            "speakerNames": row.get("speakerNames"),
        }
        with open(os.path.join(HERE, name + ".row.json"), "w") as fh:
            json.dump(stripped, fh, indent=1)
    print(name, "lines", len(kept), "door", [re.search(r"status=(\w+)", l).group(1) for l in door])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
