#!/usr/bin/env python3
"""Render an EG-1 corpus through the exact shipped chat message shape."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--split", default="all")
    args = parser.parse_args()

    prompt_lines = [
        line
        for line in Path(args.prompt).read_text(encoding="utf-8").splitlines()
        if not line.startswith("#")
    ]
    system = "\n".join(prompt_lines).strip()
    rendered: list[dict[str, str]] = []
    for line in Path(args.corpus).read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if args.split != "all" and row.get("split") != args.split:
            continue
        transcript = row.get("input", row.get("asr_input"))
        if not isinstance(transcript, str):
            raise SystemExit(f"{row.get('id')}: missing input/asr_input")
        rendered.append(
            {
                "id": row["id"],
                "system": system,
                "user": f"<TRANSCRIPT>\n{transcript}\n</TRANSCRIPT>",
            }
        )

    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rendered),
        encoding="utf-8",
    )
    print(f"wrote {len(rendered)} prompts using exact EG-1 wrapper")


if __name__ == "__main__":
    main()
