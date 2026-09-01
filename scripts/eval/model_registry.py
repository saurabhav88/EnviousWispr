#!/usr/bin/env python3
"""The authority for "which EG-1 model is this, and which one won".

Reads `model-registry.json`. Every EG-1 model we have trained has exactly one
immutable artifact ID here, `eg1-<release>-c<NNN>`, and every score we have on it
is attached with the corpus, rubric and judge that produced it.

WHY THE PROVENANCE FIELDS ARE NOT OPTIONAL. Across our history the receipts carry
nine different rubric identities and thirty-eight different corpora. Two numbers
from different rubrics are not two measurements of the same thing, they are two
different questions, and putting them in one column is exactly the confusion this
file exists to prevent. So nothing here ever ranks across a rubric or a corpus
boundary; it groups by them and refuses when asked to cross one.

CLI:
    model_registry.py list                 every artifact, newest release first
    model_registry.py list --release 1.2   one release
    model_registry.py validate             schema + convention + one-winner rules
    model_registry.py floor --corpus sealed_v1.jsonl --rubric <id> --judge <id>
"""
import argparse
import json
import re
import sys
from pathlib import Path

REGISTRY_PATH = Path(__file__).parent / "model-registry.json"
ID_RE = re.compile(r"^eg1-[0-9]+\.[0-9]+-c[0-9]{3}$")
STATUSES = ("candidate", "rejected", "selected", "shipped", "superseded")
# At most one of each per release: two winners is the ambiguity, not a tidiness rule.
EXCLUSIVE = ("selected", "shipped")


class RegistryError(Exception):
    """Anything that would make the registry answer confidently and wrongly."""


def load(path: Path = REGISTRY_PATH) -> dict:
    """Read and validate. Every failure raises; none returns a default.

    A registry that cannot be read must stop its caller, not hand back an empty
    one — an empty registry answers "no artifact has ever won", which is a
    confident wrong answer to the only question this file exists to answer.
    """
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise RegistryError(f"cannot read {path.name} ({exc})") from exc
    except ValueError as exc:
        raise RegistryError(f"{path.name} is not valid JSON ({exc})") from exc

    artifacts = doc.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise RegistryError(f"{path.name} carries no artifacts")

    seen = set()
    winners: dict[tuple[str, str], list[str]] = {}
    for a in artifacts:
        aid = a.get("artifactId")
        if not isinstance(aid, str) or not ID_RE.match(aid):
            raise RegistryError(f"bad artifact id {aid!r}: expected eg1-<release>-c<NNN>")
        if aid in seen:
            raise RegistryError(f"duplicate artifact id {aid}")
        seen.add(aid)
        if a.get("status") not in STATUSES:
            raise RegistryError(f"{aid}: status {a.get('status')!r} not in {STATUSES}")
        if not a.get("statusReason"):
            raise RegistryError(f"{aid}: status {a['status']} with no reason")
        if not aid.startswith(f"eg1-{a.get('release')}-"):
            raise RegistryError(f"{aid}: id does not match release {a.get('release')!r}")
        if a["status"] in EXCLUSIVE:
            # Keyed by RELEASE ALONE, not by (release, status). Both statuses set
            # the floor, so a release holding one `selected` and a different
            # `shipped` artifact has two winners and the floor would depend on
            # which. Grouping by status would have let that pass.
            winners.setdefault(a["release"], []).append(f"{aid} ({a['status']})")
        # The KEY must exist. `a.get("evaluations") or []` reads a typo'd or dropped
        # key as "this artifact was never scored", which is a claim, not an absence.
        # The three other reads of this field all run on a doc that came through here,
        # so guarding it once is enough.
        if not isinstance(a.get("evaluations"), list):
            raise RegistryError(f"{aid}: no evaluations list. Write [] for an artifact "
                                f"with no receipt; do not omit the key.")
        for e in a["evaluations"]:
            # `judgeIdentity` is REQUIRED, not optional: `comparable()` reads it, so a
            # row without it raises KeyError from inside `floor()` — a validator that
            # passed such a row would be certifying data that crashes its own reader.
            for field in ("corpus", "passRatePct", "s4Count", "casesScored",
                          "summaryPath", "judgeIdentity"):
                if e.get(field) is None:
                    raise RegistryError(
                        f"{aid}: an evaluation is missing {field}; a score with no "
                        f"provenance cannot be compared to anything")
            # `rubricIdentity` may be NULL and the key must still be present. A run
            # scored from borrowed verdicts genuinely has no rubric of its own —
            # 197 of our 329 historical receipts are that shape. Deleting them
            # would destroy real history; the honest record is the number WITH the
            # fact that nothing produced by us graded it. `floor()` requires an
            # exact rubric match, so a null can never set a bar.
            if "rubricIdentity" not in e:
                raise RegistryError(
                    f"{aid}: an evaluation omits the rubricIdentity key. Write null "
                    f"for a run scored from external verdicts; do not leave it out.")

    for release, ids in winners.items():
        if len(ids) > 1:
            raise RegistryError(
                f"release {release} has {len(ids)} winning artifacts: "
                f"{', '.join(ids)}. Exactly one may be selected or shipped.")
    return doc


def comparable(evaluation: dict, corpus: str, rubric: str, judge: str) -> bool:
    """All three, because the module docstring says all three and a predicate that
    checked two would have quietly contradicted it. An Azure deployment can be
    repointed in place, so the same corpus and rubric graded through a different
    deployment are two different graders wearing one name."""
    return (evaluation["corpus"] == corpus
            and evaluation["rubricIdentity"] == rubric
            and evaluation["judgeIdentity"] == judge)


def floor(corpus: str, rubric: str, judge: str,
          doc: dict | None = None) -> tuple[int | None, str]:
    """The best S4 count on record for this corpus and rubric, and where it came from.

    Only `shipped` and `selected` artifacts set the floor. A `candidate` has not
    been accepted by anyone, and letting an unreviewed run move the bar would mean
    a single lucky grading could raise a wall nothing can clear afterwards.

    Where one artifact has SEVERAL runs on the same corpus and rubric — the shipped
    1.1 has three, reading 66, 65 and 63 — the LOWEST is taken. "The best we have
    on record" is what the founder asked for, and it is the reading that makes the
    bar hardest rather than easiest.

    Returns (count, description); count is None when nothing qualifies, and the
    description then says why.
    """
    doc = doc if doc is not None else load()
    best = None
    for a in doc["artifacts"]:
        if a["status"] not in EXCLUSIVE:
            continue
        for e in a.get("evaluations") or []:
            if (not comparable(e, corpus, rubric, judge)
                    or e.get("runComplete") is not True):
                continue
            if best is None or e["s4Count"] < best[0]:
                best = (e["s4Count"], a["artifactId"], e["summaryPath"])
    if best is None:
        return None, (f"no complete evaluation of a shipped or selected artifact on "
                      f"corpus {corpus} under rubric {rubric} judged by {judge}")
    return best[0], f"{best[1]} ({best[2]})"


def cmd_list(args) -> int:
    doc = load()
    rows = [a for a in doc["artifacts"]
            if args.release is None or a["release"] == args.release]
    # NUMERIC, not string: at 1.10 a string sort puts 1.9 above it and the CLI's
    # promise of "newest release first" would point a reader at an older winner.
    # Same axis as the pinned ids — an ordering derived from the wrong property.
    for release in sorted({a["release"] for a in rows},
                          key=lambda v: tuple(int(part) for part in v.split(".")),
                          reverse=True):
        print(f"\n=== EG-1 {release} " + "=" * 46)
        for a in [r for r in rows if r["release"] == release]:
            mark = {"shipped": "SHIPPED", "selected": "WON, not shipped",
                    "superseded": "superseded", "rejected": "", "candidate": "untested"}
            print(f"  {a['artifactId']:16s} {mark[a['status']]:17s} "
                  f"was: {a['legacyNames'][0]}")
            # COMPLETE runs only. An incomplete run's numbers are better than the
            # truth by exactly the cases nobody scored, so showing one as an
            # artifact's headline is how a loser comes to look like a winner.
            # Measured here: round 1 carried an incomplete run reading 92.1% / 28
            # serious beside its real 91.6% / 36, and the first version of this
            # display printed the incomplete one — which made round 1 look better
            # than the round that actually won.
            #
            # And ONE ROW PER PROVENANCE GROUP, never a best-of across them. Sorting
            # every sealed run together by pass rate silently crosses the rubric and
            # judge boundary this module refuses to cross everywhere else: it printed
            # 1.0's 89.7% from an older rubric, and 1.1's S4 65 when its comparable
            # floor is 63. Within a group the LOWEST s4Count is shown, matching what
            # `floor()` takes.
            sealed = [e for e in a.get("evaluations") or []
                      if e["corpus"] == "sealed_v1.jsonl"]
            complete = [e for e in sealed if e.get("runComplete") is True]
            groups: dict[tuple, dict] = {}
            for e in complete:
                key = (e["corpus"], e["rubricIdentity"], e["judgeIdentity"])
                if key not in groups or e["s4Count"] < groups[key]["s4Count"]:
                    groups[key] = e
            for (_c, rubric, judge), e in sorted(
                    groups.items(), key=lambda kv: -kv[1]["passRatePct"]):
                print(f"      {e['passRatePct']}% pass, {e['s4Count']} serious "
                      f"({e['casesScored']} cases, rubric "
                      f"{(rubric or 'external')[:8]}, judge {judge})")
            if not groups:
                why = (f"{len(sealed)} sealed_v1 run(s) on record, all INCOMPLETE"
                       if sealed else "no sealed_v1 score on record")
                print(f"      {why}")
            print(f"      {a['statusReason']}")
    return 0


def cmd_validate(_args) -> int:
    doc = load()
    n = sum(len(a.get("evaluations") or []) for a in doc["artifacts"])
    print(f"OK: {len(doc['artifacts'])} artifacts, {n} evaluations, "
          f"ids and one-winner-per-release rules hold")
    return 0


def cmd_floor(args) -> int:
    count, where = floor(args.corpus, args.rubric, args.judge)
    if count is None:
        print(f"NO FLOOR: {where}", file=sys.stderr)
        return 1
    print(f"{count} S4 — {where}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list"); p.add_argument("--release"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("validate"); p.set_defaults(fn=cmd_validate)
    p = sub.add_parser("floor")
    p.add_argument("--corpus", required=True); p.add_argument("--rubric", required=True)
    p.add_argument("--judge", required=True, help="judge identity, exactly as recorded")
    p.set_defaults(fn=cmd_floor)
    args = ap.parse_args()
    try:
        return args.fn(args)
    except RegistryError as exc:
        print(f"REGISTRY ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
