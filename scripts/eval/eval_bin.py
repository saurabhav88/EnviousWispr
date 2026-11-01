"""Where the eval runner binaries live: the ONE answer every gate and bench uses (#4293).

The three runners (AppleIntelligenceRunner, AliasRunner, PromptRender) are products
of the single package scripts/eval/Package.swift. SwiftPM owns the output layout, so
the location comes from `swift build --show-bin-path`, never a hand-written
`.build/...` path.

    from eval_bin import runner_bin, BUILD_HINT
    exe = runner_bin("AliasRunner")          # Path, or raises RunnerMissing

Shell callers: `python3 scripts/eval/eval_bin.py <Name>` prints the path (exit 1 with
the build hint when the binary is missing).
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

EVAL_DIR = Path(__file__).resolve().parent
RUNNERS = ("AppleIntelligenceRunner", "AliasRunner", "PromptRender")
BUILD_HINT = "Build it with: swift build -c release --package-path scripts/eval"


class RunnerMissing(RuntimeError):
    pass


def bin_dir() -> Path:
    r = subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", str(EVAL_DIR), "--show-bin-path"],
        capture_output=True, text=True)
    out = r.stdout.strip().splitlines()
    if r.returncode != 0 or not out:
        raise RunnerMissing(f"could not ask SwiftPM for the eval bin path: {r.stderr.strip()[-400:]}\n{BUILD_HINT}")
    return Path(out[-1])


def runner_bin(name: str) -> Path:
    if name not in RUNNERS:
        raise ValueError(f"unknown eval runner {name!r}; expected one of {RUNNERS}")
    exe = bin_dir() / name
    if not exe.is_file():
        raise RunnerMissing(f"{name} is not built at {exe}\n{BUILD_HINT}")
    return exe


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <{'|'.join(RUNNERS)}>", file=sys.stderr)
        sys.exit(2)
    try:
        print(runner_bin(sys.argv[1]))
    except (RunnerMissing, ValueError) as e:
        print(e, file=sys.stderr)
        sys.exit(1)
