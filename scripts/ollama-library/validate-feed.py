#!/usr/bin/env python3
"""Validate the Ollama library feed (#2778).

  validate-feed.py --offline --base <git-revision> --feed website/public/ollama-library.json
      Required CI. No network. Compares the candidate file against the PR base: add-only,
      at most 3 additions, no retained row changed, at most 40 rows, every row well formed,
      no duplicates, nothing that is shipped, measured or first party.
  validate-feed.py --registry --base <git-revision> --feed <path>
      Routine time, network. For each ADDED row: the registry manifest answers 200, the
      layer sizes sum to `sizeBytes`, the size is at most 16 GB, and the library page does
      not tag the model as an embedding model.
  validate-feed.py --self-test
      Passing and failing fixtures for the offline rules (also run in CI). No network.

Exit 0 only when every check passed. Any read, parse or network failure is an error, never
a pass.

`--base -` means "no base file": a seed. A seed must have schema 1 and an empty `models`.
When the base revision exists but has no feed file, that is also a seed.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import library  # noqa: E402


def load_json_text(text: str, label: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is not valid JSON: {error}") from error


def base_document(revision: str, feed: str):
    """The feed at `revision`, or None for a seed. Raises when git itself fails."""
    if revision == "-":
        return None
    exists = subprocess.run(
        ["git", "cat-file", "-e", f"{revision}:{feed}"],
        cwd=library.REPO_ROOT,
        capture_output=True,
    )
    if exists.returncode != 0:
        # Distinguish "no such file at that revision" from "no such revision".
        commit = subprocess.run(
            ["git", "cat-file", "-e", f"{revision}^{{commit}}"],
            cwd=library.REPO_ROOT,
            capture_output=True,
        )
        if commit.returncode != 0:
            raise RuntimeError(f"base revision {revision!r} does not exist in this checkout")
        return None
    shown = subprocess.run(
        ["git", "show", f"{revision}:{feed}"],
        cwd=library.REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    return load_json_text(shown.stdout, f"{feed} at {revision}")


def document_errors(document, label: str) -> list:
    if not isinstance(document, dict):
        return [f"{label}: top level is not an object"]
    errors = []
    schema = document.get("schema")
    if isinstance(schema, bool) or schema != library.SCHEMA:
        errors.append(f"{label}: schema must be {library.SCHEMA}, got {schema!r}")
    if not isinstance(document.get("models"), list):
        errors.append(f"{label}: models must be an array")
    return errors


def offline_errors(base, candidate, known: set) -> list:
    """All offline problems of `candidate` against `base` (None = seed)."""
    errors = document_errors(candidate, "candidate")
    if errors:
        return errors
    rows = candidate["models"]

    if base is None:
        if rows:
            errors.append("seed: with no base file the feed must start with an empty models array")
        base_rows = []
    else:
        base_errors = document_errors(base, "base")
        if base_errors:
            return base_errors
        base_rows = base["models"]

    if len(rows) > library.MAX_ROWS:
        errors.append(
            f"capacity: {len(rows)} rows exceeds {library.MAX_ROWS}; a person decides what to retire"
        )

    # A retained row may be RETIRED when it has since become a model the app already has a position on
    # (shipped, measured or first party): the Swift parser would drop it and the committed-feed test
    # would fail, so the same change that ships the model must be able to remove the stale row.
    # Every other removal, change or reorder is still refused, and a retired row may not stay.
    def retired(row) -> bool:
        return (
            isinstance(row, dict)
            and not library.row_shape_errors(row)
            and bool(library.known_errors(row, known))
        )

    retained_base = [r for r in base_rows if not retired(r)]
    if rows[: len(retained_base)] != retained_base:
        removed = [r for r in retained_base if r not in rows]
        errors.append(
            "append-only violated: a retained row was removed, changed or reordered"
            + (f" (missing: {[r.get('name') for r in removed if isinstance(r, dict)]})" if removed else "")
        )
    additions = rows[len(retained_base) :]
    if len(additions) > library.MAX_ADDITIONS_PER_RUN:
        errors.append(
            f"{len(additions)} additions exceeds the limit of {library.MAX_ADDITIONS_PER_RUN}"
        )

    seen = set()
    for index, row in enumerate(rows):
        label = f"row {index}" + (f" ({row.get('name')})" if isinstance(row, dict) else "")
        shape = library.row_shape_errors(row)
        errors.extend(f"{label}: {e}" for e in shape)
        if shape:
            continue
        canonical = library.canonical(row["name"])
        if canonical in seen:
            errors.append(f"{label}: duplicate of an earlier row")
        seen.add(canonical)
        errors.extend(f"{label}: {e}" for e in library.known_errors(row, known))
    return errors


def registry_errors(base, candidate) -> list:
    """Network checks for the rows added on top of `base`."""
    base_count = 0 if base is None else len(base["models"])
    additions = candidate["models"][base_count:]
    if not additions:
        return []
    errors = []
    try:
        cards = library.fetch_library_cards()
    except Exception as error:  # a failed fetch is an error, never a pass
        return [f"library page: {error}"]
    by_name = {card["name"]: card for card in cards}
    for row in additions:
        name = row["name"]
        repo = name.split(":", 1)[0]
        try:
            layer_sum = library.manifest_layer_bytes(name)
        except Exception as error:
            errors.append(f"{name}: {error}")
            continue
        if layer_sum != row["sizeBytes"]:
            errors.append(f"{name}: sizeBytes {row['sizeBytes']} != registry layer sum {layer_sum}")
        if row["sizeBytes"] > library.ROUTINE_MAX_SIZE_BYTES:
            errors.append(f"{name}: {row['sizeBytes']} bytes exceeds the 16 GB routine limit")
        card = by_name.get(repo)
        if card is None:
            errors.append(f"{name}: repository {repo!r} is not on the library page")
        elif "embedding" in card["capabilities"]:
            errors.append(f"{name}: tagged as an embedding model on the library page")
    return errors


# --- self test ----------------------------------------------------------------

_GOOD = {
    "name": "olmo2:7b",
    "displayName": "OLMo 2 (7B)",
    "parameterCount": "7B",
    "sizeBytes": 4_500_000_000,
    "reason": "fixture",
}


def _doc(*rows):
    return {"schema": 1, "updated": "2026-10-16", "models": list(rows)}


def _with(**changes):
    row = dict(_GOOD)
    row.update(changes)
    return row


def self_test() -> int:
    known = {"qwen2.5:3b", "llama3.2", "deepseek-r1:1.5b"}
    a, b, c, d = (_with(name=f"m{i}:7b") for i in range(4))
    cases = [
        # (label, base, candidate, expect_ok)
        ("unchanged", _doc(a), _doc(a), True),
        ("seed with empty models", None, _doc(), True),
        ("seed with rows", None, _doc(a), False),
        ("one addition", _doc(a), _doc(a, b), True),
        ("three additions", _doc(), _doc(a, b, c), True),
        ("four additions", _doc(), _doc(a, b, c, d), False),
        ("removal", _doc(a, b), _doc(a), False),
        ("changed retained row", _doc(a), _doc(_with(name=a["name"], displayName="Changed")), False),
        ("reordered", _doc(a, b), _doc(b, a), False),
        ("clearing a populated feed", _doc(a), _doc(), False),
        ("retire a row that became shipped", _doc(_with(name="qwen2.5:3b"), a), _doc(a), True),
        ("retire a row that became shipped and add one", _doc(_with(name="qwen2.5:3b"), a), _doc(a, b), True),
        ("keep a row that became shipped", _doc(_with(name="qwen2.5:3b"), a), _doc(_with(name="qwen2.5:3b"), a), False),
        ("remove a row that is NOT known", _doc(a, b), _doc(b), False),
        ("retire plus change a retained row", _doc(_with(name="qwen2.5:3b"), a), _doc(_with(name=a["name"], displayName="X")), False),
        ("updated field may change", _doc(a), dict(_doc(a), updated="2026-11-01"), True),
        ("wrong schema", _doc(a), dict(_doc(a), schema=2), False),
        ("bad name", _doc(), _doc(_with(name="Bad Name")), False),
        ("whitespace-only displayName", _doc(), _doc(_with(displayName="   ")), False),
        ("whitespace-only parameterCount", _doc(), _doc(_with(parameterCount=" ")), False),
        ("trailing newline in name", _doc(), _doc(_with(name="olmo2:7b\n")), False),
        ("uppercase LATEST", _doc(), _doc(_with(name="olmo2:LATEST")), False),
        ("cloud name", _doc(), _doc(_with(name="x-cloud:7b")), False),
        ("bidi in displayName", _doc(), _doc(_with(displayName="a‮b")), False),
        ("size below floor", _doc(), _doc(_with(sizeBytes=1)), False),
        ("size as boolean", _doc(), _doc(_with(sizeBytes=True)), False),
        ("size as string", _doc(), _doc(_with(sizeBytes="4500000000")), False),
        ("unknown key (a verdict)", _doc(), _doc(dict(_GOOD, verdict="recommended")), False),
        ("missing key", _doc(), _doc({k: v for k, v in _GOOD.items() if k != "name"}), False),
        ("shipped model", _doc(), _doc(_with(name="qwen2.5:3b")), False),
        ("shipped via latest", _doc(), _doc(_with(name="llama3.2:latest")), False),
        ("measured but unshipped", _doc(), _doc(_with(name="deepseek-r1:1.5b")), False),
        ("first party", _doc(), _doc(_with(name="eg-1:q4")), False),
        ("duplicate by latest alias", _doc(), _doc(_with(name="olmo2"), _with(name="olmo2:latest")), False),
        ("capacity overflow", _doc(*[_with(name=f"x{i}:7b") for i in range(40)]),
         _doc(*[_with(name=f"x{i}:7b") for i in range(40)], _with(name="y:7b")), False),
        ("capacity exactly full", _doc(*[_with(name=f"x{i}:7b") for i in range(39)]),
         _doc(*[_with(name=f"x{i}:7b") for i in range(40)]), True),
    ]
    failures = 0
    for label, base, candidate, expect_ok in cases:
        errors = offline_errors(base, candidate, known)
        ok = not errors
        if ok != expect_ok:
            failures += 1
            print(f"FAIL [{label}] expected {'pass' if expect_ok else 'fail'}, got {errors}")
        else:
            print(f"ok   [{label}]")
    # Shared name fixtures (also read by the Swift tests).
    fixtures = json.loads((Path(__file__).resolve().parent / "name-fixtures.json").read_text())
    for name in fixtures["valid"]:
        if library.row_shape_errors(_with(name=name)):
            failures += 1
            print(f"FAIL [fixture valid {name!r}] rejected")
    for name in fixtures["invalid"]:
        if not library.row_shape_errors(_with(name=name)):
            failures += 1
            print(f"FAIL [fixture invalid {name!r}] accepted")
    # The Swift-source readers must still find their blocks.
    try:
        shipped = library.shipped_names()
        measured = library.measured_names()
        print(f"ok   [swift sources: {len(shipped)} shipped, {len(measured)} measured names]")
    except Exception as error:
        failures += 1
        print(f"FAIL [swift sources] {error}")
    # Registry checks against fixture manifests (no network): the comparison logic must be able to FAIL.
    original_fetch = library.fetch
    original_cards = library.fetch_library_cards
    fixture = {}

    def fixture_fetch(url, accept=None, timeout=30):
        if fixture.get("transport_failure"):
            raise RuntimeError("fixture transport failure")
        body = json.dumps({"layers": [{"size": size} for size in fixture["layers"]]})
        return fixture.get("status", 200), body.encode("utf-8")

    try:
        library.fetch = fixture_fetch
        library.fetch_library_cards = lambda: [
            {"name": "olmo2", "capabilities": fixture.get("capabilities", [])}
        ]
        registry_cases = [
            ("layer sum matches", {"layers": [4_000_000_000, 500_000_000]}, _GOOD, True),
            ("wrong sum", {"layers": [4_000_000_000]}, _GOOD, False),
            ("embedding model", {"layers": [4_500_000_000], "capabilities": ["embedding"]}, _GOOD, False),
            ("registry 404", {"layers": [4_500_000_000], "status": 404}, _GOOD, False),
            ("transport failure", {"layers": [], "transport_failure": True}, _GOOD, False),
            (
                "routine size ceiling",
                {"layers": [17_000_000_000]},
                _with(sizeBytes=17_000_000_000),
                False,
            ),
            (
                "boolean layer size",
                {"layers": [4_500_000_000, True]},
                _with(sizeBytes=4_500_000_001),
                False,
            ),
        ]
        for label, state, row, expect_ok in registry_cases:
            fixture.clear()
            fixture.update(state)
            errors = registry_errors(_doc(), _doc(row))
            if (not errors) != expect_ok:
                failures += 1
                print(f"FAIL [registry {label}] got {errors}")
            else:
                print(f"ok   [registry {label}]")
    finally:
        library.fetch = original_fetch
        library.fetch_library_cards = original_cards
    print(f"== validate-feed self-test {'PASS' if failures == 0 else 'FAIL'} ==")
    return 0 if failures == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--offline", action="store_true")
    mode.add_argument("--registry", action="store_true")
    mode.add_argument("--self-test", action="store_true")
    parser.add_argument("--base", help="git revision holding the base feed, or '-' for none")
    parser.add_argument("--feed", default=library.FEED_PATH, help="candidate feed file")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.base:
        library.die("--base is required")

    try:
        candidate = load_json_text(Path(args.feed).read_text(encoding="utf-8"), args.feed)
        base = base_document(args.base, library.FEED_PATH)
        if args.offline:
            errors = offline_errors(base, candidate, library.known_names())
        else:
            errors = offline_errors(base, candidate, library.known_names()) or registry_errors(
                base, candidate
            )
    except Exception as error:
        library.die(str(error))

    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1
    mode_name = "offline" if args.offline else "registry"
    print(f"ok: {mode_name} checks passed for {args.feed} ({len(candidate['models'])} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
