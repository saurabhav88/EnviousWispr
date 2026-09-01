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
    model_registry.py floor --corpus sealed_v1.jsonl --cases 1462 --rubric <id> --judge <id>
"""
import argparse
import hashlib
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


# A rubric identity is the first 12 hex chars of a sha256.
RUBRIC_RE = re.compile(r"^[0-9a-f]{12}$")

# The scorer whose bytes ARE the rubric. Hashed here rather than imported,
# because behavior_judge imports release_gate which imports this module.
JUDGE_PATH = Path(__file__).parent / "behavior_judge.py"


def live_rubric_identity() -> str:
    """What `behavior_judge._rubric_identity()` returns for THIS checkout.

    Deliberately a re-implementation of one line rather than an import: the
    import is circular. Kept honest by `test_live_rubric_identity_matches_the_scorer`,
    which asserts the two agree.
    """
    try:
        return hashlib.sha256(JUDGE_PATH.read_bytes()).hexdigest()[:12]
    except OSError:
        return "unreadable"


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

    # The equivalence map can MERGE two rubrics, so it is validated before anything
    # reads it. Every failure below is a refusal, never a skip: a malformed group
    # that is quietly ignored takes the floor away with nothing said.
    groups = doc.get("_rubricEquivalence")
    if groups is not None:
        if not isinstance(groups, list):
            raise RegistryError("_rubricEquivalence must be a list")
        seen_ids: dict[str, int] = {}
        for i, g in enumerate(groups):
            if not isinstance(g, dict):
                raise RegistryError(f"_rubricEquivalence[{i}] is not an object")
            ids = g.get("identities")
            if not isinstance(ids, list) or len(ids) < 2:
                raise RegistryError(f"_rubricEquivalence[{i}] needs 2+ identities")
            if len(set(ids)) != len(ids):
                raise RegistryError(f"_rubricEquivalence[{i}] repeats an identity")
            for r in ids:
                if not isinstance(r, str) or not RUBRIC_RE.match(r):
                    raise RegistryError(
                        f"_rubricEquivalence[{i}]: {r!r} is not a 12-hex rubric identity")
                # Two groups sharing an identity make the canonical form depend on
                # list order, which is the same positional defect the pinned ids
                # exist to prevent.
                if r in seen_ids:
                    raise RegistryError(
                        f"rubric {r} appears in groups {seen_ids[r]} and {i}")
                seen_ids[r] = i
            for field in ("reason", "provenBy", "provenOn"):
                if not isinstance(g.get(field), str) or not g[field].strip():
                    raise RegistryError(f"_rubricEquivalence[{i}] has no {field}")

        # EVERY listed identity must be REAL: either it stamped an evaluation on
        # record, or it is the identity this checkout's scorer emits right now.
        # A hand-typed hash belongs to neither, and cloud review caught exactly
        # that on PR #2576 — `cc91f15de09f` was read from the scorer, one further
        # edit was made to it, and the stale value was recorded. The consequence
        # is silent and total: a real run stamps the true hash, no group contains
        # it, the floor resolves to None and the ratchet reports N/A forever.
        # A remembered identifier is not a measurement (validation-discipline.md
        # RULE: measure-with-the-real-tool-never-a-simulation); this makes the
        # registry check it instead of trusting it.
        stamped = {e.get("rubricIdentity")
                   for a in doc.get("artifacts") or []
                   for e in a.get("evaluations") or []}
        live = live_rubric_identity()
        for i, g in enumerate(groups):
            unknown = [r for r in g["identities"] if r not in stamped and r != live]
            if unknown:
                raise RegistryError(
                    f"_rubricEquivalence[{i}] lists {', '.join(unknown)}, which stamped no "
                    f"evaluation and is not this checkout's scorer identity "
                    f"({live}). A rubric identity is MEASURED, never typed: read it from "
                    f"the scorer after your last edit to it.")

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
            # TYPE, not just presence. `floor()` compares with `is not True` and with
            # `==`, so a value of the right NAME and the wrong type — `run_complete:
            # "true"`, or a case count as a string — passes validation and then makes
            # `floor()` silently skip a winning row. Checking every field's type here
            # closes that axis rather than the one field a reviewer happened to name.
            # `bool` is excluded from the numeric checks deliberately: in Python
            # `isinstance(True, int)` is True, so a boolean would sneak through as a
            # count.
            required = {
                "corpus": str, "summaryPath": str, "judgeIdentity": str,
                "promptVariant": str, "s4Count": int, "casesScored": int,
                "passRatePct": (int, float),
            }
            for field, want in required.items():
                value = e.get(field)
                if value is None:
                    raise RegistryError(
                        f"{aid}: an evaluation is missing {field}; a score with no "
                        f"provenance cannot be compared to anything")
                if isinstance(value, bool) or not isinstance(value, want):
                    raise RegistryError(
                        f"{aid}: {field} is {type(value).__name__} {value!r}, expected "
                        f"{want if isinstance(want, type) else 'a number'}. A value of "
                        f"the right name and the wrong type passes every comparison "
                        f"floor() makes, by failing all of them.")

            # RANGE, after type. A number can be well-typed and impossible, and an
            # impossible one is not caught by any comparison either: a negative
            # s4Count would set a floor nothing can ever beat, and a count larger
            # than the corpus describes an exam that did not happen.
            n, s4, pct = e["casesScored"], e["s4Count"], e["passRatePct"]
            if n <= 0:
                raise RegistryError(f"{aid}: casesScored {n} — an exam with no cases")
            if not 0 <= s4 <= n:
                raise RegistryError(
                    f"{aid}: s4Count {s4} outside 0..{n}. A negative floor can never "
                    f"be beaten; one above the corpus size describes a different exam.")
            if not 0 <= pct <= 100:
                raise RegistryError(f"{aid}: passRatePct {pct} outside 0..100")
            # `rubricIdentity` may be NULL and the key must still be present. A run
            # scored from borrowed verdicts genuinely has no rubric of its own —
            # 197 of our 329 historical receipts are that shape. Deleting them
            # would destroy real history; the honest record is the number WITH the
            # fact that nothing produced by us graded it. `floor()` requires an
            # exact rubric match, so a null can never set a bar.
            # These two may be NULL and the key must still be PRESENT. A receipt can
            # genuinely lack them — a run scored from borrowed verdicts has no rubric
            # of its own, and an older summary may not record completeness — so null
            # is real history. What must not happen is the key going MISSING, because
            # `floor()` reads both and a dropped key would silently skip the row while
            # `validate` reported success.
            for optional, want in (("rubricIdentity", str), ("runComplete", bool)):
                if optional not in e:
                    raise RegistryError(
                        f"{aid}: an evaluation omits the {optional} key. Write null "
                        f"when the receipt does not record it; do not leave it out.")
                value = e[optional]
                if value is not None and not isinstance(value, want):
                    raise RegistryError(
                        f"{aid}: {optional} is {type(value).__name__} {value!r}; "
                        f"expected {want.__name__} or null.")

    for release, ids in winners.items():
        if len(ids) > 1:
            raise RegistryError(
                f"release {release} has {len(ids)} winning artifacts: "
                f"{', '.join(ids)}. Exactly one may be selected or shipped.")
    return doc


def corpus_identity(evaluation: dict) -> tuple[str, int]:
    """A corpus NAME is a proxy, and in our own receipts it is a WRONG one.

    Measured in the checked-in registry: `tail_corpus.jsonl` names four different
    case sets (117, 132, 139, 249 cases), `speechpath_1861.jsonl` three, and
    `speechpath_1861_v3.jsonl` two — files edited in place while keeping the name.
    Comparing by name alone therefore merges genuinely different exams.

    The case COUNT is the strongest identity recoverable from a receipt, since the
    receipts never recorded a content digest. It is still a proxy — two edits that
    keep the size would collide — so a future harness should record a digest and
    this should use it. Stated rather than left implied.
    """
    return (evaluation["corpus"], evaluation["casesScored"])


def canonical_rubric(rubric: str | None, doc: dict | None = None) -> str | None:
    """Map a rubric identity onto its equivalence group's FIRST member.

    `_rubric_identity()` hashes behavior_judge.py IN ITS ENTIRETY, so a change that
    provably moves no score — moving the release gate into its own module, say —
    still mints a new identity and orphans every stored evaluation from it. Without
    this map the ratchet has no floor on its first run after any such refactor, and
    a gate with no floor is the defect that got the first ratchet reverted.

    This is the ONLY mechanism that can merge two rubrics, so it is also the only
    one that could rank two genuinely different rubrics together. `load()` refuses a
    group that does not carry its evidence; the registry's
    `_rubricEquivalenceContract` states what that evidence has to be.
    """
    if rubric is None:
        return None
    doc = doc if doc is not None else load()
    for group in doc.get("_rubricEquivalence") or []:
        if rubric in group["identities"]:
            return group["identities"][0]
    return rubric


def comparable(evaluation: dict, corpus: str, rubric: str, judge: str,
               cases: int, doc: dict | None = None) -> bool:
    """Corpus AND its case count, rubric, judge — and the artifact's OWN prompt.

    An Azure deployment can be repointed in place, so the same corpus and rubric
    graded through a different deployment are two graders wearing one name. And a
    prompt PROBE attaches to the artifact it experimented on while describing a
    configuration that was never selected or shipped, so letting one set the floor
    would gate releases on a prompt we do not serve."""
    return (corpus_identity(evaluation) == (corpus, cases)
            and canonical_rubric(evaluation["rubricIdentity"], doc)
                == canonical_rubric(rubric, doc)
            and evaluation["judgeIdentity"] == judge
            and evaluation["promptVariant"] == "own")


def floor(corpus: str, rubric: str, judge: str, cases: int,
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
            if (not comparable(e, corpus, rubric, judge, cases, doc)
                    or e.get("runComplete") is not True):
                continue
            if best is None or e["s4Count"] < best[0]:
                best = (e["s4Count"], a["artifactId"], e["summaryPath"])
    if best is None:
        return None, (f"no complete evaluation of a shipped or selected artifact on "
                      f"corpus {corpus} ({cases} cases) under rubric {rubric} "
                      f"judged by {judge}")
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
                key = (corpus_identity(e), e["rubricIdentity"], e["judgeIdentity"],
                       e["promptVariant"])
                if key not in groups or e["s4Count"] < groups[key]["s4Count"]:
                    groups[key] = e
            for (_cid, rubric, judge, variant), e in sorted(
                    groups.items(), key=lambda kv: -kv[1]["passRatePct"]):
                tag = "" if variant == "own" else f", PROMPT PROBE: {variant}"
                print(f"      {e['passRatePct']}% pass, {e['s4Count']} serious "
                      f"({e['casesScored']} cases, rubric "
                      f"{(rubric or 'external')[:8]}, judge {judge}{tag})")
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
    count, where = floor(args.corpus, args.rubric, args.judge, args.cases)
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
    p.add_argument("--cases", required=True, type=int,
                   help="cases scored; a corpus FILENAME is reused for different sets")
    p.set_defaults(fn=cmd_floor)
    args = ap.parse_args()
    try:
        return args.fn(args)
    except RegistryError as exc:
        print(f"REGISTRY ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
