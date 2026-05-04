#!/usr/bin/env python3
"""Parse LID perf signposts and compare them against a checked baseline."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


SIGNPOST_RE = re.compile(r"\b([A-Za-z0-9_]+)=([^ \n]+)")
REQUIRED_EVENTS = {"t_release", "t_state_flip", "t_clipboard_write"}


def parse_signposts(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if "lid_perf_signpost" not in line:
                continue
            fields = dict(SIGNPOST_RE.findall(line))
            if "name" not in fields or "timestamp_s" not in fields or "session_id" not in fields:
                continue
            try:
                event: dict[str, Any] = {
                    "name": fields["name"],
                    "timestamp_s": float(fields["timestamp_s"]),
                    "session_id": fields["session_id"],
                }
            except ValueError:
                continue
            if "clip_kind" in fields:
                event["clip_kind"] = fields["clip_kind"]
            if "lid_window_count" in fields:
                try:
                    event["lid_window_count"] = int(fields["lid_window_count"])
                except ValueError:
                    pass
            if "voiced_duration_s" in fields:
                try:
                    event["voiced_duration_s"] = float(fields["voiced_duration_s"])
                except ValueError:
                    pass
            events.append(event)
    return events


def percentile(values: list[float], pct: float) -> float:
    if not values:
        raise ValueError("cannot compute percentile of empty values")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (len(ordered) - 1) * pct
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return ordered[int(rank)]
    lower_value = ordered[lower]
    upper_value = ordered[upper]
    return lower_value + (upper_value - lower_value) * (rank - lower)


def session_metrics(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[str, dict[str, dict[str, Any]]] = {}
    for event in events:
        grouped.setdefault(event["session_id"], {})[event["name"]] = event

    metrics: list[dict[str, Any]] = []
    for session_id, by_name in grouped.items():
        if not REQUIRED_EVENTS.issubset(by_name.keys()):
            continue
        release = by_name["t_release"]["timestamp_s"]
        state_flip = by_name["t_state_flip"]["timestamp_s"]
        clipboard = by_name["t_clipboard_write"]["timestamp_s"]
        kind = "unknown"
        for event in by_name.values():
            if event.get("clip_kind") in {"short", "normal"}:
                kind = event["clip_kind"]
                break
        if kind == "unknown":
            window_count = by_name.get("t_lid_settled", {}).get("lid_window_count")
            if window_count == 1:
                kind = "short"
            elif window_count == 4:
                kind = "normal"
        metrics.append(
            {
                "session_id": session_id,
                "clip_kind": kind,
                "state_flip_ms": (state_flip - release) * 1000.0,
                "clipboard_write_ms": (clipboard - release) * 1000.0,
            }
        )
    return metrics


def summarize(metrics: list[dict[str, Any]]) -> dict[str, Any]:
    short_clipboard = [
        metric["clipboard_write_ms"] for metric in metrics if metric["clip_kind"] == "short"
    ]
    normal_clipboard = [
        metric["clipboard_write_ms"] for metric in metrics if metric["clip_kind"] == "normal"
    ]
    state_flip = [metric["state_flip_ms"] for metric in metrics]
    if not short_clipboard:
        raise ValueError("no complete short-clip signpost groups found")
    if not normal_clipboard:
        raise ValueError("no complete normal-clip signpost groups found")
    if not state_flip:
        raise ValueError("no complete state-flip signpost groups found")
    return {
        "sample_count": len(metrics),
        "short_clip_p50_ms": percentile(short_clipboard, 0.50),
        "short_clip_p95_ms": percentile(short_clipboard, 0.95),
        "normal_clip_p50_ms": percentile(normal_clipboard, 0.50),
        "normal_clip_p95_ms": percentile(normal_clipboard, 0.95),
        "state_flip_p50_ms": percentile(state_flip, 0.50),
        "state_flip_p95_ms": percentile(state_flip, 0.95),
    }


def load_baseline(path: Path) -> dict[str, Any]:
    try:
        baseline = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"baseline file missing: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"baseline file is not valid JSON: {path}") from exc

    required = ["short_clip_p50_ms", "normal_clip_p50_ms", "state_flip_p50_ms"]
    missing = [key for key in required if baseline.get(key) is None]
    if missing:
        raise ValueError(f"baseline file has stub or missing values: {', '.join(missing)}")
    return baseline


def evaluate(summary: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if summary["state_flip_p50_ms"] >= 50.0:
        failures.append(
            f"state_flip_p50_ms {summary['state_flip_p50_ms']:.1f} is not below 50.0"
        )
    short_gain = baseline["short_clip_p50_ms"] - summary["short_clip_p50_ms"]
    if short_gain < 500.0:
        failures.append(f"short_clip_p50_ms improvement {short_gain:.1f} is below 500.0")
    normal_delta = abs(summary["normal_clip_p50_ms"] - baseline["normal_clip_p50_ms"])
    if normal_delta > 100.0:
        failures.append(f"normal_clip_p50_ms delta {normal_delta:.1f} exceeds 100.0")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path, help="raw signpost log file")
    parser.add_argument(
        "--baseline",
        default=Path(".validation/lid-perf-baseline.json"),
        type=Path,
        help="baseline JSON path",
    )
    parser.add_argument("--output-json", type=Path, help="write computed metrics to this path")
    args = parser.parse_args()

    try:
        events = parse_signposts(args.log)
        metrics = session_metrics(events)
        summary = summarize(metrics)
        baseline = load_baseline(args.baseline)
        failures = evaluate(summary, baseline)
    except ValueError as exc:
        print(f"lid-perf-bench: {exc}", file=sys.stderr)
        return 2

    result = {
        "summary": summary,
        "baseline": baseline,
        "sessions": metrics,
        "pass": not failures,
        "failures": failures,
    }
    if args.output_json:
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")

    print(json.dumps(result["summary"], indent=2, sort_keys=True))
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print("PASS: LID perf gates satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
