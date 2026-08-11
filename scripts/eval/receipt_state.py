#!/usr/bin/env python3
"""Why a judge receipt cannot be trusted — ONE classifier, two consumers.

`report_ollama_bench.py` (ranking) and `judge_ollama_bench.sh` (caching) both have
to explain a refused receipt, and they must give the SAME explanation for the same
file or an operator cannot tell which to believe.

They were two copies of the same logic in two languages, and copies diverge: in
one PR the shell fell behind twice, first on verdict classification and then on
malformed metadata, each time announcing "predates the `cacheable` field" about a
file the report correctly called hand-edited or corrupt. Both were caught by
review rather than by anything structural, because a comment asking for parity
cannot enforce it. So this module is the single authority and the shell shells out
to it rather than reimplementing it.

A REFUSAL MUST NEVER RAISE AND MUST NEVER GUESS. Every field read here goes
through an accessor that cannot raise on any JSON value, and a field that is
present with the wrong type is reported as malformed rather than coerced —
coercing `"skipped": "not a list"` to `[]` manufactures the claim "records no
gaps", which is a false statement about a receipt that records nothing usable.

CLI contract, used by the shell: exit code IS the state, stdout carries the
malformed field names (empty otherwise).
"""
from __future__ import annotations

import json
import sys

# Verdicts this gate can actually emit. Anything else means the receipt was not
# produced by `evaluate_new_gate` — hand-edited, or from another tool.
ALLOWED_VERDICTS = ("CLEAR", "BLOCK", "INCOMPLETE")

# States, ordered by precedence rather than severity. Verdict is classified before
# metadata is read, for two independent reasons: an unsupported verdict is the
# stronger signal and carries different advice than "this file is merely old", and
# it marks a hand-edited file, which is exactly where malformed metadata lives —
# so the fragile reads never run for the receipts most likely to break them.
NOT_CACHEABLE = 0      # object carrying `cacheable`, so the field says false
LEGACY = 1             # object without it, valid verdict (written before #2007)
UNREADABLE = 2         # missing, undecodable, malformed JSON, or not an object
UNSUPPORTED_VERDICT = 3  # a verdict this gate cannot emit
MALFORMED_METADATA = 4   # valid verdict, but gap fields whose types prove nothing


def _as_dict(v):
    return v if isinstance(v, dict) else {}


def _as_list(v):
    return v if isinstance(v, list) else []


def _is_int(v) -> bool:
    # `bool` is an `int` subclass, and `True` must not read as 1 in a count.
    return isinstance(v, int) and not isinstance(v, bool)


def _as_int(v) -> int:
    return v if _is_int(v) else 0


def malformed_metadata_fields(receipt: dict) -> list[str]:
    """Gap fields that are PRESENT with an unusable type, sorted.

    Absent is not malformed: it means nothing was recorded, which a pre-#2007
    receipt does legitimately. Only a present-but-wrong-typed field is a lie
    waiting to be told.
    """
    names = []
    for key, coerce in (("skipped", _as_list), ("missing_scores", _as_list),
                        ("adjudication", _as_dict), ("wobble", _as_dict)):
        if key in receipt and coerce(receipt[key]) is not receipt[key]:
            names.append(key)

    adj = receipt.get("adjudication")
    if isinstance(adj, dict):
        names += [f"adjudication.{k}" for k in
                  ("adjudication_missing_n", "adjudicated_n")
                  if k in adj and not _is_int(adj[k])]

    wobble = receipt.get("wobble")
    if isinstance(wobble, dict) and "rep_coverage" in wobble:
        rc = wobble["rep_coverage"]
        if not isinstance(rc, list) or not all(_is_int(x) for x in rc):
            names.append("wobble.rep_coverage")

    return sorted(names)


def classify(path) -> tuple[int, list[str]]:
    """Returns (state, malformed field names). Never raises."""
    try:
        with open(path) as f:
            receipt = json.load(f)
    # ValueError, not JSONDecodeError: invalid UTF-8 raises UnicodeDecodeError,
    # which a JSONDecodeError-only tuple misses. Both are ValueError subclasses,
    # so catching the base is the enumeration rather than a list of names that can
    # miss the next member.
    except (OSError, ValueError):
        return UNREADABLE, []
    if not isinstance(receipt, dict):
        return UNREADABLE, []

    verdict = _as_dict(receipt.get("release_gate")).get("verdict")
    if verdict not in ALLOWED_VERDICTS:
        return UNSUPPORTED_VERDICT, []

    malformed = malformed_metadata_fields(receipt)
    if malformed:
        return MALFORMED_METADATA, malformed

    return (NOT_CACHEABLE if "cacheable" in receipt else LEGACY), []


def adjudication_dropped(receipt: dict) -> int:
    """How many adjudication scores this receipt records as dropped.

    A pre-#2007 receipt has no explicit `adjudication_missing_n` but DOES carry
    the evidence, so defaulting to zero would claim "no adjudication gap" from a
    receipt that proves one. `behavior_judge` sets `rep_scores =
    [primary_premerge, adjudication]`, so `wobble.rep_coverage[1]` is how many
    judged ids the adjudication pass returned while `adjudicated_n` is how many
    were selected; the difference is the drop. Only meaningful when a pass ran —
    with none, `rep_coverage` has a single entry and there is nothing to compare.

    Callers must reject malformed metadata first; this assumes usable types.
    """
    adj = _as_dict(receipt.get("adjudication"))
    explicit = adj.get("adjudication_missing_n")
    if _is_int(explicit):
        return explicit
    rep_coverage = _as_list(_as_dict(receipt.get("wobble")).get("rep_coverage"))
    if len(rep_coverage) > 1:
        return max(0, _as_int(adj.get("adjudicated_n")) - _as_int(rep_coverage[1]))
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: receipt_state.py <summary.json>", file=sys.stderr)
        return 64
    state, malformed = classify(sys.argv[1])
    if malformed:
        print(", ".join(malformed))
    return state


if __name__ == "__main__":
    sys.exit(main())
