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
    model_registry.py floor --corpus sealed_v1.jsonl --cases 1462 --rubric <id> --judge <id> \
                            --adjudication 0.15:15 --production none [--system new] [--blind]

`floor` takes EVERY axis `comparable()` checks. `--adjudication` and `--production`
are required because their absence can never match a floor-setting evaluation, so
a query without them is not a looser question, it is a different one.
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


# THE REPLAY PROOF HAS A BLIND SPOT, AND THESE ARE ITS EDGES.
# `--verdicts` short-circuits: "no judge calls, nothing to adjudicate". So a replay
# runs the AGGREGATION path and never runs the reconciliation path — the adjudication
# selection, the second look, or the worse-of-two merge. A change confined to those
# functions replays IDENTICALLY and would be declared score-neutral on evidence that
# never touched it. Cloud review, PR #2576.
#
# Documenting that is not enough, because a documented limit is read as a limit that
# was checked. Hashing the un-exercised code makes the blind spot DETECTABLE: if these
# functions differ from what they were when an equivalence was proven, the proof does
# not cover the change and `check-live` says so.
UNREPLAYED_FUNCTIONS = ("select_adjudication_ids", "_worse_new_score")


def unreplayed_digest() -> str:
    """Hash the scorer code a `--verdicts` replay does NOT execute.

    Extracts each named function from its `def` to the next top-level `def`. A name
    that is absent is recorded as such rather than skipped: a function that has been
    RENAMED must not silently drop out of the digest and make the hash look stable.
    """
    try:
        src = JUDGE_PATH.read_text(encoding="utf-8")
    except OSError:
        return "unreadable"
    chunks = []
    for name in UNREPLAYED_FUNCTIONS:
        marker = f"\ndef {name}("
        i = src.find(marker)
        if i == -1:
            chunks.append(f"<<ABSENT:{name}>>")
            continue
        j = src.find("\ndef ", i + 1)
        chunks.append(src[i:j if j != -1 else len(src)])
    return hashlib.sha256("".join(chunks).encode("utf-8")).hexdigest()[:12]


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

        # EVERY GROUP must be CONNECTED TO REALITY: at least one of its identities
        # stamped an evaluation on record, or is the scorer this checkout runs now.
        #
        # DELIBERATELY NOT "every identity must be stamped or live", which was the
        # first version and which cloud review showed to be a time bomb. `live` is a
        # MOVING TARGET: the identity added by a refactor has stamped nothing yet, so
        # the next ordinary edit to behavior_judge.py made it neither stamped nor
        # live and `load()` rejected the WHOLE registry — every consumer down, and
        # `s4_floor()` reporting the registry unreadable, which now BLOCKS. Measured:
        # appending one comment line to the scorer produced exactly that.
        #
        # A condition that must hold FOREVER cannot be written against a value that
        # changes every time anyone edits a file. Stamped-ness does not change, so
        # this one holds. The liveness question is real but belongs at WRITE time,
        # where the answer is knowable — see `cmd_check_live`.
        stamped = {e.get("rubricIdentity")
                   for a in doc.get("artifacts") or []
                   for e in a.get("evaluations") or []}
        live = live_rubric_identity()
        for i, g in enumerate(groups):
            if not any(r in stamped or r == live for r in g["identities"]):
                raise RegistryError(
                    f"_rubricEquivalence[{i}] lists {', '.join(g['identities'])}, and NONE of "
                    f"them stamped an evaluation or is this checkout's scorer ({live}). A group "
                    f"with no connection to real history cannot be checked by anyone.")

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
                # THIRD instance in this PR of "a value that could not be determined
                # takes the permissive branch", so the fix is one gate at the DOOR
                # rather than a guard at each comparison: require `system` here and
                # `comparable()` can never see it absent. `judgeBlind` is checked
                # separately below because None is a LEGITIMATE value for it — a
                # receipt that never recorded blinding — and None must stay
                # distinguishable from False rather than be required away.
                "system": str,
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
            # `judgeBlind` joins the optional-but-present set rather than `required`:
            # null is REAL history (a receipt that never recorded blinding), and it must
            # stay distinguishable from False, because `comparable()` compares it
            # exactly and unknown blinding may not set a bar.
            for optional, want in (("rubricIdentity", str), ("runComplete", bool),
                                   ("judgeBlind", bool), ("adjudication", str),
                                   ("productionBaseline", str)):
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
               cases: int, doc: dict | None = None,
               system: str = "new", blind: bool = False,
               adjudication: str | None = None,
               production: str | None = None) -> bool:
    """Corpus AND its case count, rubric, judge, GRADING SYSTEM, BLINDING — and the
    artifact's OWN prompt.

    The axes were enumerated from the RECEIPT rather than from review findings: every
    non-metric field a summary carries was read and judged in or out. In:
    `corpus_files` (+ case count), `rubric_identity`, `judge_identity`, `system`,
    `judge_blind`, and the prompt variant. Out, each for a stated reason:
    `judge`/`judge_model_version` are folded into `judge_identity`; `reps` is
    old-system wobble and does not move S4; `candidates_file` names the ARTIFACT under
    test, not the exam; `production_file` feeds pairwise only; timestamps are not
    properties of the measurement.

    ARGUED EXCLUSION, stated so it can be challenged rather than discovered:
    RETRACTED, and the retraction is the point. This docstring previously argued that
    `adjudicate_pct`/`adjudicate_min` merely perturb a sample and could not move the
    scale, with a falsification condition attached. Cloud review met it: the
    reconciliation is DIRECTIONAL — `_worse_new_score()` keeps the MORE severe of the
    primary and adjudicated looks — so a run that skipped adjudication can only score
    BETTER than the same model adjudicated, and comparing it to an adjudicated floor
    is a free pass. Adjudication policy is now IN, as one string: `"<pct>:<min>"`,
    `"none"`, or null when the receipt cannot say.

    Every floor-setting evaluation on `sealed_v1.jsonl` was measured to have
    adjudication ENABLED, so this costs no history: the floor is still 31.

    An Azure deployment can be repointed in place, so the same corpus and rubric
    graded through a different deployment are two graders wearing one name. And a
    prompt PROBE attaches to the artifact it experimented on while describing a
    configuration that was never selected or shipped, so letting one set the floor
    would gate releases on a prompt we do not serve."""
    return (corpus_identity(evaluation) == (corpus, cases)
            and canonical_rubric(evaluation["rubricIdentity"], doc)
                == canonical_rubric(rubric, doc)
            and evaluation["judgeIdentity"] == judge
            and evaluation.get("system") == system
            # EXACT, never `bool(...)`: `bool(None) == bool(False)` made an
            # evaluation whose receipt never recorded blinding compare as SIGHTED.
            # Twelve of the 71 evaluations on record are exactly that, and twenty are
            # genuinely blind — so this is live data, not a hypothetical. Unknown
            # blinding is excluded from every floor, which is the only honest reading:
            # blind and sighted are measured non-comparable, so "we do not know which"
            # cannot set a bar.
            and evaluation.get("judgeBlind") == blind
            # Exact, and null never matches: a receipt that cannot say whether it
            # adjudicated sets no floor. My own ARGUED EXCLUSION said these settings
            # only perturb a sample and could not move the scale; that was wrong for
            # a reason I had not considered and cloud review supplied — the
            # reconciliation is DIRECTIONAL, so skipping adjudication can only lower
            # an S4 count. The falsification condition published with that exclusion
            # is what made the finding checkable.
            and evaluation.get("adjudication") == adjudication
            # The production baseline is a SCORING input, not just a pairwise one:
            # `select_adjudication_ids()` guarantees a second look at `critical_loss`
            # cases ONLY when production is present, and the second look can only
            # raise severity. So a run without a baseline gets fewer second looks and
            # can score better than the same model with one. Recorded as the
            # filename, or the string "none" — never null-for-absent, because absent
            # is a real and distinct setup.
            and evaluation.get("productionBaseline") == production
            and evaluation["promptVariant"] == "own")


def floor(corpus: str, rubric: str, judge: str, cases: int,
          doc: dict | None = None,
          system: str = "new", blind: bool = False,
          adjudication: str | None = None,
          production: str | None = None) -> tuple[int | None, str]:
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
            if (not comparable(e, corpus, rubric, judge, cases, doc,
                               system=system, blind=blind,
                               adjudication=adjudication, production=production)
                    or e.get("runComplete") is not True):
                continue
            if best is None or e["s4Count"] < best[0]:
                best = (e["s4Count"], a["artifactId"], e["summaryPath"])
    if best is None:
        return None, (f"no complete evaluation of a shipped or selected artifact on "
                      f"corpus {corpus} ({cases} cases) under rubric {rubric} "
                      f"judged by {judge}, system={system}, "
                      f"blind={'yes' if blind else 'no'}, "
                      f"adjudication={adjudication}, production={production}")
    return best[0], f"{best[1]} ({best[2]})"


def cmd_check_live(args) -> int:
    """Refuse unless the LIVE scorer identity is stamped or listed in a group.

    This is the check that catches a TYPED rubric hash, and it is a WRITE-time
    question by nature: "is this identity the one the scorer emits" is only
    meaningful at the moment you record it. Run it after adding an equivalence
    group and after any edit to `behavior_judge.py` that you believe score-neutral.

    A live identity that is neither stamped nor listed is NOT an error in itself —
    that is the ordinary state of a genuinely new rubric, and the ratchet correctly
    reports N/A. It IS an error when you meant to record an equivalence and recorded
    a stale value, which is the case this command exists to make visible.
    """
    doc = load()
    live = live_rubric_identity()
    stamped = {e.get("rubricIdentity")
               for a in doc["artifacts"] for e in a.get("evaluations") or []}
    listed = {r for g in doc.get("_rubricEquivalence") or [] for r in g["identities"]}
    def blind_spot_note(g):
        """Whether the un-replayed reconciliation code has moved since the proof."""
        was = g.get("unreplayedDigest")
        now = unreplayed_digest()
        if was is None:
            return (f"  NOTE: this group predates the blind-spot digest, so whether "
                    f"{', '.join(UNREPLAYED_FUNCTIONS)} changed since it was proven "
                    f"is unknown.")
        if was != now:
            return (f"  WARNING: {', '.join(UNREPLAYED_FUNCTIONS)} changed since this "
                    f"equivalence was proven ({was} -> {now}). A --verdicts replay does "
                    f"NOT execute them, so the score-neutral proof does not cover that "
                    f"change. Re-prove by another means or narrow the claim.")
        return f"  blind-spot digest unchanged ({now})"

    if live in stamped:
        print(f"OK: live scorer identity {live} has stamped evaluations on record")
        return 0
    if live in listed:
        print(f"OK: live scorer identity {live} is recorded in an equivalence group")
        for g in doc.get("_rubricEquivalence") or []:
            if live in g["identities"]:
                print(blind_spot_note(g))
        return 0
    print(f"UNRECORDED: the scorer emits {live}, which has stamped no evaluation and is in no "
          f"equivalence group.\n"
          f"  If you intended a score-neutral refactor, prove it and record the pair:\n"
          f"    python3 scripts/eval/replay_receipts.py before.json  # at the old revision\n"
          f"    python3 scripts/eval/replay_receipts.py after.json\n"
          f"    python3 scripts/eval/diff_replays.py before.json after.json\n"
          f"  If this is a genuinely NEW rubric, nothing is wrong: the ratchet reports N/A "
          f"until a shipped or selected artifact is evaluated under it.")
    return 1


def cmd_record_live(args) -> int:
    """Replace a group's non-historical identity with the one the scorer emits NOW.

    Exists because hand-recording the identity was invalidated THREE times in one
    change: every edit to `behavior_judge.py` moves it, including the edit that fixes
    the review finding you are recording it for. A value that must be measured after
    the LAST edit is a value nobody should type — so this reads it, and re-running it
    is one command rather than a habit anyone can forget.

    Refuses when the live identity is already correct (nothing to do) and when the
    group would lose its last stamped member, which is the anchor `load()` requires.
    """
    doc = load()
    live = live_rubric_identity()
    groups = doc.get("_rubricEquivalence") or []
    if not groups:
        print("REFUSE: no _rubricEquivalence group to record into")
        return 2
    stamped = {e.get("rubricIdentity")
               for a in doc["artifacts"] for e in a.get("evaluations") or []}
    g = groups[args.group]
    # NOT "nothing to do". Recording is the author ASSERTING a fresh proof, and the
    # blind-spot digest is part of that assertion — an identity can be unchanged while
    # the un-replayed reconciliation code has moved, which is exactly the case the
    # digest exists to catch. Returning early here left the digest unwritten and
    # `check-live` reporting "predates the digest" forever.
    identity_already_there = live in g["identities"]
    keep = [r for r in g["identities"] if r in stamped]
    if not keep and not identity_already_there:
        print(f"REFUSE: group {args.group} has no stamped identity to anchor it; "
              f"replacing its members would leave a group nothing can check")
        return 2
    old_ids = list(g["identities"])
    if not identity_already_there:
        g["identities"] = keep + [live]
    # Stamped WITH the proof, so a later change to the un-replayed reconciliation code
    # is detectable rather than merely documented.
    g["unreplayedDigest"] = unreplayed_digest()
    with REGISTRY_PATH.open("w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    load()  # fail loudly rather than leave an invalid registry on disk
    if identity_already_there:
        print(f"identity {live} was already recorded; stamped the blind-spot digest "
              f"{g['unreplayedDigest']}.\n"
              f"  This asserts you have just re-proven score neutrality for THIS "
              f"scorer. If you have not, revert the registry and re-run the replay.")
    else:
        print(f"recorded {live}\n  was: {old_ids}\n  now: {g['identities']}\n"
              f"  blind-spot digest: {g['unreplayedDigest']}")
    return 0


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
    # EVERY axis `comparable()` checks is forwarded. The first version forwarded
    # four of them and let `adjudication` and `production` fall to their None
    # defaults, which no floor-setting evaluation on record carries — so the
    # documented CLI answered NO FLOOR for a history whose floor is 63 (#2582).
    count, where = floor(args.corpus, args.rubric, args.judge, args.cases,
                         system=args.system, blind=args.blind,
                         adjudication=args.adjudication,
                         production=args.production)
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
    p = sub.add_parser("check-live"); p.set_defaults(fn=cmd_check_live)
    p = sub.add_parser("record-live")
    p.add_argument("--group", type=int, default=0)
    p.set_defaults(fn=cmd_record_live)
    p = sub.add_parser("floor")
    p.add_argument("--corpus", required=True); p.add_argument("--rubric", required=True)
    p.add_argument("--judge", required=True, help="judge identity, exactly as recorded")
    p.add_argument("--cases", required=True, type=int,
                   help="cases scored; a corpus FILENAME is reused for different sets")
    # REQUIRED, not defaulted to None. `comparable()` matches these exactly, so a
    # None default would match only an evaluation whose receipt recorded null —
    # the one kind of row the module says may never set a bar — and would answer
    # NO FLOOR for every real sealed history. `release_gate.s4_floor()` refuses to
    # ask without them for the same reason; the CLI asks the same question.
    p.add_argument("--adjudication", required=True,
                   help='adjudication policy exactly as recorded: "<pct>:<min>" '
                        '(e.g. 0.15:15) or "none"')
    p.add_argument("--production", required=True,
                   help='production baseline exactly as recorded: its filename '
                        '(e.g. sealed_shipped.jsonl) or "none"')
    p.add_argument("--system", default="new",
                   help='grading system as recorded (default: "new")')
    p.add_argument("--blind", action="store_true",
                   help="the judge was blinded (default: sighted)")
    p.set_defaults(fn=cmd_floor)
    args = ap.parse_args()
    try:
        return args.fn(args)
    except RegistryError as exc:
        print(f"REGISTRY ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
