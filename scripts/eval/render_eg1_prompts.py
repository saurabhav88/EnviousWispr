#!/usr/bin/env python3
"""Render an EG-1 corpus through the exact shipped chat message shape."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", nargs="+", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--split", default="all")
    parser.add_argument("--ids", nargs="*", help="Optional exact case IDs to render")
    args = parser.parse_args()

    prompt_lines = [
        line
        for line in Path(args.prompt).read_text(encoding="utf-8").splitlines()
        if not line.startswith("#")
    ]
    system = "\n".join(prompt_lines).strip()
    selected_ids = set(args.ids or [])
    rendered: list[dict[str, str]] = []
    for corpus_path in args.corpus:
        for line in Path(corpus_path).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if args.split != "all" and row.get("split") != args.split:
                continue
            if selected_ids and row.get("id") not in selected_ids:
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

    rendered_ids = [row["id"] for row in rendered]
    if len(rendered_ids) != len(set(rendered_ids)):
        raise SystemExit("duplicate rendered ids across corpus inputs")

    if selected_ids:
        missing = sorted(selected_ids - set(rendered_ids))
        if missing:
            raise SystemExit(f"requested ids not found after split filter: {missing}")

    output = Path(args.out)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rendered),
        encoding="utf-8",
    )
    print(f"wrote {len(rendered)} prompts using exact EG-1 wrapper")


if __name__ == "__main__":
    main()
