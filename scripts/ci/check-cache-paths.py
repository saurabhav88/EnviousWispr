#!/usr/bin/env python3
"""scripts/ci/check-cache-paths.py — the two Xcode cache path lists must agree.

WHY THIS EXISTS, measured 2026-09-02 on #2580. `actions/cache` derives a cache
VERSION from a hash of the path list. A restore only matches a save whose
version is identical, and the key is checked second. So two lists that differ in
ANY way describe two caches that can never see each other — and nothing reports
it. The lanes stay green and simply rebuild everything, forever.

The instance that cost a full CI run: eight lines of prose were written inside
a `path: |` block scalar. YAML block scalars have no comments, so
`actions/cache` read them as eight more paths. Both PR lanes then asked for an
eleven-path version while the writer saved a three-path one, and the log said
`Cache not found for input keys` for all four keys — including the broadest
fallback, which had matched on every previous run.

The existing warning in main-post-merge.yml already said the lists "MUST stay
identical … a save/restore pair that disagrees produces a permanently cold cache
with no error anywhere". It was right, it was read, and prose does not execute.

There were FOUR lists when this was written: the composite action's restore,
the post-merge save, and pr-check.yml's two inline restores. #2592 wired both
pr-check.yml lanes to the composite action, so there are now exactly two —
one restore (used by all four macOS lanes) and one save. Two is the floor:
`actions/cache/restore` and `actions/cache/save` are separate steps in
separate workflows, and each must spell the list itself.

WHAT IS CHECKED
  1. Every actions/cache step (restore, save, or the combined action) across
     every workflow and every local action manifest, at any depth under
     `.github/actions/`, is found by PARSING, never by grepping for a name.
  2. A step is in the Xcode FAMILY when its key carries one of
     XCODE_KEY_MARKERS. Every in-family `path` list is normalised — the known
     spellings of the DerivedData root collapse to <DD> — and must equal
     EXPECTED_PATHS. A cache step outside the family must be named in
     EXPECTED_OTHER, or it is an error: a family whose marker drifted looks
     exactly like a smaller clean family.
  3. No entry may begin with `#`. That is the specific trap above, and it is
     called out separately so the failure names its own cause.
  4. The <DD> token is only honest if every spelling really is the same
     directory, so the places that MINT the root are resolved and compared
     to EXPECTED_ROOT: `env.DERIVED_DATA_PATH` at workflow, job and step
     level, and the `derived-data-path` every caller hands a local action
     (a step, or a job calling a reusable workflow), with the env expression
     substituted by the value in force at that point. Anything this script
     cannot resolve — a reusable-workflow input, an env expression with no
     value in force — is a failure, not a match. The composite's own input
     default is a producer, and a caller that omits the argument resolves
     through it. `root_producers` states the scopes it does not cover; a
     `-derivedDataPath` typed into a `run:` line is a BUILD location, not a
     cache location, and is outside this script. (#2593 item 1, and the
     second-pass finding on #2592.)
  5. The set of cache steps, WITH their kind, equals EXPECTED_OWNERS as a
     multiset: a restore that turns into a save, a duplicate writer, or a
     writer that appears somewhere new all fail. (#2593 item 2; the
     writer contract is ci-pipeline.md RULE: cache-writer-is-post-merge-only.)

Usage:
  check-cache-paths.py [--self-test]
"""
import collections
import glob
import os
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - runner image variance
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet",
         "--disable-pip-version-check", "pyyaml"],
        check=True,
    )
    import yaml

DD_LITERAL = ".derivedData/CI"
ENV_EXPR = "${{ env.DERIVED_DATA_PATH }}"
INPUT_EXPR = "${{ inputs.derived-data-path }}"

# The THREE spellings of the DerivedData root that are known to mean the same
# directory, and nothing else.
#
# An earlier version collapsed ANY `${{ … }}` to <DD>, which is the proxy trap
# this repo keeps paying for: it compared a RENDERING when the question was
# identity, so `${{ runner.temp }}/SourcePackages` and
# `${{ env.DERIVED_DATA_PATH }}/SourcePackages` read as equal and the guard
# reported success on exactly the drift it exists to catch. Whitespace inside
# the expression is normalised because YAML authors vary it; the expression
# itself is not.
#
# "Known to mean the same directory" was itself an unchecked premise until
# #2593: the env expression means whatever `env:` says at that point, and the
# input expression means whatever the composite's caller passed. `root_producers`
# below resolves the env at every level and checks every caller, so the collapse
# is a checked fact rather than a hope.
DD_EXPRESSIONS = (
    ENV_EXPR,
    INPUT_EXPR,
    DD_LITERAL,
)


def _canon(entry: str) -> str:
    """One spelling per expression: collapse whitespace, including inside `${{ … }}`."""
    e = " ".join(entry.strip().split())
    # `${{env.X}}` and `${{ env.X }}` are the same expression to Actions, so the
    # spacing inside is normalised. Rebuilt into a NEW string with a cursor,
    # never edited in place: the first version looped `while "${{" in e` and
    # re-inserted `${{` on every pass, so it never terminated. A guard that
    # hangs is a guard that times out the job it was added to protect.
    out, i = [], 0
    while True:
        start = e.find("${{", i)
        if start == -1:
            out.append(e[i:])
            break
        end = e.find("}}", start)
        if end == -1:
            out.append(e[i:])
            break
        out.append(e[i:start])
        out.append("${{ " + " ".join(e[start + 3:end].split()) + " }}")
        i = end + 2
    return "".join(out)


def normalise(entry: str) -> str:
    """Collapse the KNOWN DerivedData roots to one token, leaving all else intact."""
    e = _canon(entry)
    for expr in DD_EXPRESSIONS:
        if e.startswith(expr):
            return "<DD>" + e[len(expr):]
    return e


# What makes a cache step a member of THIS family. Selected from the step's own
# declared key rather than from a marker somebody has to remember to add: every
# Xcode cache key in this repo is built as `<os>-<arch>-<env>-xcode-…`.
#
# Without this, a legitimate unrelated cache added later — an npm one, say, and
# this repo already carries an npm cache from setup-node — would be compared
# against the Xcode list and red the required aggregator for no reason.
# A key is in the family if it spells the marker directly, OR if it reuses the
# composite action's exported key, which IS that key by another name.
#
# The direct marker alone was not enough and the miss was silent: the post-merge
# SAVE — the one step whose disagreement matters most, because it is the only
# writer — passes `${{ steps.setup.outputs.cache-primary-key }}` and carries no
# literal `-xcode-`. The first version of this filter dropped it and reported
# "3 steps, one identical list" while never looking at the writer at all.
XCODE_KEY_MARKERS = ("-xcode-", "cache-primary-key")

# WHAT THE ANSWER IS, stated independently of what the workflows happen to say.
#
# Two review rounds found the same root here and the second one is the reason
# this exists: the guard compared the (then four) lists TO EACH OTHER.
# Consistency is not correctness. Four sites agreeing on `Build/` passed, and so did a writer
# that fell out of the family because its key was reworded — a smaller clean set
# prints exactly like a complete one.
#
# So every half is a literal now. `validation-discipline.md`
# RULE: an-expectation-built-with-the-mechanism-under-test-cannot-fail: an
# expectation read out of the subject moves when the subject moves.
#
# Changing any constant is meant to be deliberate. `ci-pipeline.md`
# RULE: rolling-cache-key owns the path set and the root, and
# RULE: cache-writer-is-post-merge-only owns who may write; a new lane, a new
# cached path, a moved DerivedData root or a second writer is a change to those
# rules, not an incidental edit.
EXPECTED_PATHS = (
    "<DD>/SourcePackages",
    "<DD>/CompilationCache.noindex",
    "<DD>/*/SourcePackages",
)

EXPECTED_ROOT = DD_LITERAL

# (repository-relative file, unit, kind). A multiset, compared with counts, so a
# duplicate writer is an extra rather than a match. Paths are kept whole rather
# than collapsed to a basename: every local action manifest is called
# `action.yml`, so a basename cannot tell two of them apart (#2593 item 3).
EXPECTED_OWNERS = (
    (".github/actions/xcode-ci-setup/action.yml", "composite", "restore"),
    (".github/workflows/main-post-merge.yml", "release-validation", "save"),
)

# Cache steps that are NOT Xcode caches and are allowed to exist, (file, unit).
# Empty today: the npm cache comes from setup-node's own `cache:` input, not an
# actions/cache step. A cache step that is neither in the family nor listed here
# is an ERROR, never merely printed — an Xcode cache whose key lost its marker
# would otherwise land outside the family, and the family would still read
# clean and complete (second-pass finding on #2593).
EXPECTED_OTHER = ()


def in_family(key: str) -> bool:
    return any(m in key for m in XCODE_KEY_MARKERS)


def discover(root: str = ".") -> list:
    """Every CI definition file the check reads, repository-relative and sorted.

    GitHub accepts BOTH .yml and .yaml for workflows and for action manifests,
    and a local action may live at any depth under `.github/actions/` — the
    `**` is what makes `.github/actions/cache/xcode/action.yml` visible. An
    earlier glob matched one level only, so a valid action one directory down
    was invisible while the docstring still claimed a repository-wide scan.
    """
    patterns = (
        ".github/workflows/*.yml",
        ".github/workflows/*.yaml",
        ".github/actions/**/action.yml",
        ".github/actions/**/action.yaml",
    )
    found = set()
    for pat in patterns:
        for p in glob.glob(os.path.join(root, pat), recursive=True):
            found.add(os.path.relpath(p, root))
    return sorted(found)


def _load(path: str):
    doc = yaml.safe_load(open(path))
    return doc if isinstance(doc, dict) else None


def _units(doc):
    """(unit name, steps, job env) for every job in a workflow, or the composite body."""
    if "jobs" in doc:
        for n, j in (doc["jobs"] or {}).items():
            j = j or {}
            yield n, j.get("steps") or [], j.get("env") or {}
    elif (doc.get("runs") or {}).get("using") == "composite":
        yield "composite", doc["runs"].get("steps") or [], {}


def _kind(uses: str):
    # The combined `actions/cache@…` both restores AND saves, which makes it a
    # writer. It was invisible to the first version, which matched only the
    # split actions — so a lane switching to the combined form would have
    # become a second writer with nothing red.
    u = uses.split("@", 1)[0].rstrip("/")
    return {
        "actions/cache/restore": "restore",
        "actions/cache/save": "save",
        "actions/cache": "restore+save",
    }.get(u)


def cache_steps(path: str):
    """Yield (file, unit, name, path lines, in-family, kind) for every cache step."""
    doc = _load(path)
    if doc is None:
        return
    for unit, steps, _ in _units(doc):
        for st in steps:
            kind = _kind(str(st.get("uses", "")))
            if kind is None:
                continue
            with_ = st.get("with", {}) or {}
            raw = with_.get("path", "") or ""
            lines = [ln for ln in raw.strip().split("\n") if ln.strip()]
            yield path, unit, st.get("name", st.get("uses")), lines, in_family(str(with_.get("key", ""))), kind


def _is_local_action(uses: str) -> bool:
    return uses.startswith("./")


def _resolve_root(raw, effective, in_composite: bool):
    """(resolved value or None, reason) for a `derived-data-path` a caller passes.

    Only the ENV expression has a producer this script can read (the value in
    force for that step). The INPUTS expression means two different things and
    neither is the env: inside a composite manifest it FORWARDS the manifest's
    own input to a nested action, which is fine exactly when it is the whole
    value, because the outer callers are checked instead; inside a workflow it
    names a reusable-workflow or dispatch input, which nothing here can resolve,
    so it is reported rather than trusted. An earlier version collapsed both
    expressions to <DD> and then resolved the input spelling through the env,
    which would have let a reusable-workflow caller read as the CI root.
    """
    text = str(raw)
    if text != text.strip():
        # `".derivedData/CI "` keeps its space through YAML and through Actions,
        # and `.derivedData/CI /SourcePackages` is a different directory. The
        # path-list side strips because block-scalar lines are trimmed by
        # actions/cache; a `with:` value is not.
        return None, "whitespace"
    c = _canon(text)
    if c.startswith(ENV_EXPR):
        return (None if effective is None else effective + c[len(ENV_EXPR):]), "env"
    if c.startswith(INPUT_EXPR):
        if in_composite and c == INPUT_EXPR:
            return "<forwarded>", "forward"
        return None, "inputs"
    return c, "literal"


def _manifest_input_default(uses: str, root: str):
    """(declared, default) for `derived-data-path` on the local action `uses` points at.

    `declared` is False when the manifest cannot be read or has no such input.
    A caller that omits the argument gets the default, so the default is a
    producer too — and a required input with no default, omitted, is what
    GitHub refuses at run time, which this reports rather than trusts.
    """
    for name in ("action.yml", "action.yaml"):
        p = os.path.normpath(os.path.join(root, uses[2:], name))
        if os.path.isfile(p):
            doc = _load(p)
            inp = ((doc or {}).get("inputs") or {}).get("derived-data-path")
            if inp is None:
                return False, None
            return True, (None if not isinstance(inp, dict) or "default" not in inp else str(inp["default"]))
    return False, None


def root_producers(path: str, root: str = "."):
    """Yield (file, unit, what, resolved value) for every place a DerivedData root is minted.

    Producers, resolved rather than normalised:
      - a workflow's top-level `env.DERIVED_DATA_PATH`;
      - a job-level `env.DERIVED_DATA_PATH`, which overrides the top-level one
        for every step in that job;
      - a step-level `env.DERIVED_DATA_PATH` on the calling step, which
        overrides both for that step;
      - the `derived-data-path` a job hands a local action — a `uses:` step,
        or a job that IS a `uses:` of a reusable workflow — after substituting
        the env expression with the value in force at that point. An expression
        with nothing to substitute resolves to None and is a failure: `${{ env.X }}`
        with no `X` renders as an empty string on the runner, and an empty root
        is a cache of `/SourcePackages`;
      - inside a composite manifest, a nested local-action call: forwarding
        `${{ inputs.derived-data-path }}` whole is accepted (the outer callers are
        the producers); anything else is resolved as above with no env in force;
      - an in-family cache step in a WORKFLOW whose path spells the root as
        `${{ inputs.derived-data-path }}` — a reusable-workflow input this script
        cannot resolve, reported rather than collapsed to <DD>.

    NOT covered, stated so nobody reads silence as coverage: a `matrix` value or
    any other expression is a literal here and fails red because it is not the
    expected root; a reusable workflow's own `inputs:` defaults are not read.
    Neither shape exists in this repository today.
    """
    doc = _load(path)
    if doc is None:
        return
    if (doc.get("runs") or {}).get("using") == "composite":
        # The manifest's own default is a producer: a caller that omits the
        # argument builds and caches wherever this says.
        inp = (doc.get("inputs") or {}).get("derived-data-path")
        if isinstance(inp, dict) and "default" in inp:
            yield path, "composite", "inputs.derived-data-path.default", str(inp["default"])
    if "jobs" in doc:
        top = (doc.get("env") or {}).get("DERIVED_DATA_PATH")
        if top is not None:
            top = str(top)
            yield path, "(workflow)", "env.DERIVED_DATA_PATH", top
        units = []
        for unit, job in (doc.get("jobs") or {}).items():
            job = job or {}
            calls = list(job.get("steps") or [])
            if "uses" in job:  # a job that calls a reusable workflow carries its own `with:`
                calls.append(job)
            units.append((unit, calls, job.get("env") or {}, False))
    elif (doc.get("runs") or {}).get("using") == "composite":
        top = None
        units = [("composite", doc["runs"].get("steps") or [], {}, True)]
    else:
        return

    for unit, steps, job_env, in_composite in units:
        effective = top
        if "DERIVED_DATA_PATH" in job_env:
            effective = str(job_env["DERIVED_DATA_PATH"])
            yield path, unit, "jobs.<job>.env.DERIVED_DATA_PATH", effective
        for st in steps:
            uses = str(st.get("uses", ""))
            with_ = st.get("with", {}) or {}
            step_effective = effective
            step_env = st.get("env") or {}
            if "DERIVED_DATA_PATH" in step_env:
                step_effective = str(step_env["DERIVED_DATA_PATH"])
                yield path, unit, "steps[*].env.DERIVED_DATA_PATH", step_effective
            if _is_local_action(uses):
                if "derived-data-path" in with_:
                    value, reason = _resolve_root(with_["derived-data-path"], step_effective, in_composite)
                    if reason == "forward":
                        continue
                    what = f"with.derived-data-path -> {uses}"
                    if reason == "inputs":
                        what += " (a reusable-workflow input this check cannot resolve)"
                    elif reason == "whitespace":
                        what += " (leading or trailing whitespace is part of the value)"
                    elif value is None:
                        what += " (env expression with no DERIVED_DATA_PATH in force)"
                    yield path, unit, what, value
                else:
                    declared, default = _manifest_input_default(uses, root)
                    if declared:
                        what = f"omitted derived-data-path -> {uses}"
                        if default is None:
                            what += " (required input not passed and no default)"
                        else:
                            what += " (manifest default)"
                        yield path, unit, what, default
            if not in_composite and _kind(uses) and in_family(str(with_.get("key", ""))):
                for line in str(with_.get("path", "") or "").splitlines():
                    if _canon(line).startswith(INPUT_EXPR):
                        yield path, unit, f"path entry {line.strip()!r} spells the root as a reusable-workflow input this check cannot resolve", None


def check(files, expected_paths, expected_owners, expected_root, expected_other=(), root=".") -> int:
    found, other, bad = [], [], []
    # Every file must PARSE before anything is compared. A traceback is red
    # too, but it names no file in the annotation the aggregator shows.
    for f in files:
        try:
            _load(f)
        except (yaml.YAMLError, OSError) as e:
            print(f"::error title=cache-paths::{f}: cannot be read as YAML — {str(e).splitlines()[0]}")
            return 1
    for f in files:
        for src, unit, name, lines, family, kind in cache_steps(f):
            commented = [ln.strip() for ln in lines if ln.strip().startswith("#")]
            norm = tuple(normalise(ln) for ln in lines)
            (found if family else other).append((src, unit, name, norm, commented, kind))

    if not found:
        print("::error title=cache-paths::no Xcode cache steps found — this check is blind, not clean")
        return 1

    # Steps outside the family are PRINTED and, unless allowlisted, REJECTED.
    # A step that falls out of the family because its key was reworded would
    # otherwise vanish in silence, and this check would keep reporting a clean,
    # smaller set.
    if other:
        print("not in the Xcode cache family:")
        allowed = {tuple(o) for o in expected_other}
        for src, unit, name, _, _, kind in other:
            ok = (src, unit) in allowed
            print(f"    {src} :: {unit} :: {name} [{kind}] {'(allowlisted)' if ok else '(NOT allowlisted)'}")
            if not ok:
                bad.append((src, unit, f"a cache {kind} step whose key matches none of {XCODE_KEY_MARKERS} and "
                                       "which is not in EXPECTED_OTHER. Either it is an Xcode cache whose key "
                                       "lost its marker, or it is a new unrelated cache — add it to "
                                       "EXPECTED_OTHER after confirming which."))
        print()

    print(f"{'unit':64s} kind     entries")
    print("-" * 86)
    for src, unit, name, norm, commented, kind in found:
        print(f"{src + ' :: ' + unit:64s} {kind:8s} {len(norm)}")
        for e in norm:
            print(f"    {e}")
        if commented:
            bad.append((src, unit, "comment lines inside `path:` — YAML block scalars have no comments, "
                                   "so these become cache paths and change the cache version: "
                                   + "; ".join(commented[:2])))

    lists = {n for _, _, _, n, _, _ in found}
    if len(lists) != 1:
        for i, l in enumerate(sorted(lists)):
            owners = [f"{s}::{u}" for s, u, _, n, _, _ in found if n == l]
            bad.append(("", "", f"list {i + 1} ({', '.join(owners)}): {list(l)}"))
        bad.append(("", "", "the path lists disagree, so a restore can never match a save. "
                            "Cache version is a hash of this list."))

    # Agreeing is not enough — they must agree on the RIGHT list.
    for src, unit, _, norm, _, _ in found:
        if norm != tuple(expected_paths):
            bad.append((src, unit, f"path list is {list(norm)}, expected {list(expected_paths)}. "
                                   "Changing the cached set is a change to ci-pipeline.md "
                                   "RULE: rolling-cache-key, so update that rule and this constant together."))

    # The <DD> token stands for ONE directory only if every producer of the root
    # says the same thing. Resolve them; never trust the spelling.
    producers = [p for f in files for p in root_producers(f, root)]
    print()
    print("DerivedData root producers:")
    for src, unit, what, value in producers:
        print(f"    {src} :: {unit} :: {what} = {value!r}")
        if value is None:
            bad.append((src, unit, f"{what}: the root cannot be resolved here, so it is not known to be "
                                   f"{expected_root!r}. An unresolved env expression renders empty on the "
                                   "runner and caches `/SourcePackages`; pass the literal or the env expression "
                                   "with DERIVED_DATA_PATH in force."))
        elif value != expected_root:
            bad.append((src, unit, f"{what} resolves to {value!r}, expected {expected_root!r}. Every cache "
                                   "step spells the root as <DD>, so a producer that disagrees builds in "
                                   "one place and caches another. The root is owned by ci-pipeline.md "
                                   "RULE: rolling-cache-key."))

    # And the SET of owners, with kinds and counts, must be exactly the expected
    # one. A writer whose key stops matching lands in `other`, where a
    # set-equality check on the survivors would still read clean; a restore
    # that becomes a save keeps its (file, unit) and only the kind moves; a
    # second save is a second writer, which the writer contract forbids.
    seen = collections.Counter((src, unit, kind) for src, unit, _, _, _, kind in found)
    expected = collections.Counter(tuple(o) for o in expected_owners)
    for (src, unit, kind), n in sorted((expected - seen).items()):
        bad.append(("", "", f"{src} :: {unit} is expected to hold {n} Xcode cache {kind} step(s) and "
                            "that was not found in the family — check its key still matches "
                            f"one of {XCODE_KEY_MARKERS} and that it is still a {kind}."))
    for (src, unit, kind), n in sorted((seen - expected).items()):
        bad.append(("", "", f"{src} :: {unit} holds {n} Xcode cache {kind} step(s) that this check "
                            "does not expect. If that is intended, add it to EXPECTED_OWNERS after "
                            "confirming its path list — and if it is a save, it is a second writer, "
                            "which ci-pipeline.md RULE: cache-writer-is-post-merge-only forbids."))

    if bad:
        print()
        for src, unit, msg in bad:
            where = f"{src} :: {unit}: " if src else ""
            print(f"::error title=cache-paths::{where}{msg}")
        return 1

    print(f"\n==> cache-paths OK: {len(found)} steps, one identical {len(next(iter(lists)))}-entry list, "
          f"{len(producers)} root producers all {expected_root!r}")
    return 0


def self_test() -> int:
    """Two-way control. A checker only ever run on correct input has not been seen to fail."""
    import contextlib
    import io
    import tempfile
    import textwrap
    fails = 0

    last = {"out": ""}

    def run(files, exp_paths, exp_owners, exp_root=DD_LITERAL, exp_other=(), root=".") -> int:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = check(files, exp_paths, exp_owners, exp_root, exp_other, root)
        last["out"] = buf.getvalue()
        return rc

    def expect(label, got, want, saying=None):
        """rc must match; `saying` pins the diagnostic, so a case whose fixture
        also trips a NEIGHBOURING assertion still proves ITS assertion fired."""
        nonlocal fails
        if got == want and (saying is None or saying in last["out"]):
            print(f"ok   [{label}] rc={got}")
        elif got != want:
            print(f"FAIL [{label}] wanted rc={want}, got {got}")
            fails += 1
        else:
            print(f"FAIL [{label}] rc={got} but the diagnostic {saying!r} was not printed")
            fails += 1

    # One directory for every fixture, removed on exit whatever happens. An
    # earlier version created anonymous temp files and forgot one in cleanup.
    with tempfile.TemporaryDirectory() as tmp:
        counter = [0]

        def fixture(body: str, name: str = None, env: str = DD_LITERAL) -> str:
            """Write one fixture. `env` is the workflow-level DERIVED_DATA_PATH, or None for no env block."""
            counter[0] += 1
            p = os.path.join(tmp, name or f"f{counter[0]}.yml")
            os.makedirs(os.path.dirname(p), exist_ok=True)
            text = textwrap.dedent(body)
            if env is not None:
                text = f"env:\n  DERIVED_DATA_PATH: {env}\n" + text
            with open(p, "w") as fh:
                fh.write(text)
            return p

        def owners(*files):
            """Owners derived from the fixtures themselves — for PATH cases only."""
            return [(f, u, k) for f in files for _, u, _, _, fam, k in cache_steps(f) if fam]


        good_a = fixture("""
            jobs:
              a:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/CompilationCache.noindex
            """)
        good_b = fixture("""
            jobs:
              b:
                steps:
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{ env.DERIVED_DATA_PATH }}/SourcePackages
                        ${{ env.DERIVED_DATA_PATH }}/CompilationCache.noindex
            """)
        commented = fixture("""
            jobs:
              c:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        # a note that is really a path
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/CompilationCache.noindex
            """)
        divergent = fixture("""
            jobs:
              d:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/Build
            """)
        empty = fixture("jobs:\n  e:\n    steps: []\n", env=None)
        # Regression for the review finding that ANY `${{ … }}` collapsed to <DD>:
        # a different root must now read as a difference, not as agreement.
        other_root = fixture("""
            jobs:
              f:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{ runner.temp }}/SourcePackages
                        ${{ runner.temp }}/CompilationCache.noindex
            """)
        # Regression for the review finding that every cache was one family: an
        # unrelated cache must be ignored rather than reded.
        unrelated = fixture("""
            jobs:
              g:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: node-cache-Linux-x64-npm-abc
                      path: |
                        website/node_modules
            """, env=None)
        # And whitespace inside an expression is not a real difference.
        spaced = fixture("""
            jobs:
              h:
                steps:
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{env.DERIVED_DATA_PATH}}/SourcePackages
                        ${{  env.DERIVED_DATA_PATH  }}/CompilationCache.noindex
            """)
        # Regression for the silently-dropped writer: this step carries no literal
        # `-xcode-`, exactly like main-post-merge.yml's save, and its list differs —
        # so it must be COMPARED and rejected, not filtered out and ignored.
        primary_keyed = fixture("""
            jobs:
              i:
                steps:
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ steps.setup.outputs.cache-primary-key }}
                      path: |
                        ${{ env.DERIVED_DATA_PATH }}/SourcePackages
                        ${{ env.DERIVED_DATA_PATH }}/Build
            """)
        shared_wrong = fixture("""
            jobs:
              j:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/Build
            """)

        # Fixtures are throwaway files, so each case states the answer it should be
        # measured against. The production entrypoint passes the module constants;
        # there is no default, so a caller cannot omit the expectation by accident.
        F = ("<DD>/SourcePackages", "<DD>/CompilationCache.noindex")

        # --- path agreement. The owner assertion is derived from the fixtures
        # here, which is circular and therefore worthless as an owner check; the
        # owner cases below state their expectation independently.
        for label, files, want, saying in [
            ("two spellings of one list agree", [good_a, good_b], 0, None),
            ("a comment inside path: is caught", [good_a, commented], 1, "comment lines inside `path:`"),
            ("two different lists are caught", [good_a, divergent], 1, "the path lists disagree"),
            ("no Xcode cache steps at all is NOT clean", [empty], 1, "blind, not clean"),
            ("a DIFFERENT root is a difference, not <DD>", [good_a, other_root], 1, "the path lists disagree"),
            ("a save keyed by cache-primary-key IS in the family", [good_a, primary_keyed], 1, "the path lists disagree"),
            ("expression whitespace is not a difference", [good_a, spaced], 0, None),
        ]:
            expect(label, run(files, F, owners(*files)), want, saying)
        expect("an allowlisted unrelated cache is ignored, not reded",
               run([good_a, good_b, unrelated], F, owners(good_a, good_b), DD_LITERAL, [(unrelated, "g")]), 0)
        expect("an unrelated cache NOT in EXPECTED_OTHER is an error (a drifted marker looks the same)",
               run([good_a, good_b, unrelated], F, owners(good_a, good_b)), 1, "not in EXPECTED_OTHER")
        broken = fixture("jobs:\n  x:\n    steps:\n      - [unterminated\n", env=None)
        expect("a file that does not parse is an annotation naming it, not a traceback",
               run([good_a, broken], F, owners(good_a)), 1, "cannot be read as YAML")

        # --- the expectation itself: wrong-but-consistent, missing, extra.
        expect("a list everyone agrees on but is WRONG is caught",
               run([shared_wrong], F, [(shared_wrong, "j", "restore")]), 1)
        expect("an expected writer missing from the family is caught",
               run([good_a], F, [(good_a, "a", "restore"), ("main-post-merge.yml", "release-validation", "save")]), 1)
        # The branch #2592 relies on — a restore that reappears somewhere the
        # expectation does not name — pinned so it cannot be deleted quietly.
        expect("an owner the check does not expect is caught",
               run([good_a], F, []), 1)

        # --- #2593 item 2: the KIND is part of the identity.
        expect("a restore that became a save is caught (same file, same unit)",
               run([good_b], F, [(good_b, "b", "restore")]), 1)
        two_saves = fixture("""
            jobs:
              k:
                steps:
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/CompilationCache.noindex
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/CompilationCache.noindex
            """)
        expect("a duplicate writer is an extra, not a match",
               run([two_saves], F, [(two_saves, "k", "save")]), 1)
        expect("(control) two writers expected twice pass",
               run([two_saves], F, [(two_saves, "k", "save"), (two_saves, "k", "save")]), 0)
        combined = fixture("""
            jobs:
              l:
                steps:
                  - uses: actions/cache@v4
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        .derivedData/CI/SourcePackages
                        .derivedData/CI/CompilationCache.noindex
            """)
        expect("the combined actions/cache action is a writer, not invisible",
               run([combined], F, [(combined, "l", "restore")]), 1)
        expect("(control) the combined action passes when expected as restore+save",
               run([combined], F, [(combined, "l", "restore+save")]), 0)

        # --- #2593 item 1: the root is RESOLVED at every producer.
        env_other = fixture("""
            jobs:
              m:
                steps:
                  - uses: actions/cache/save@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{ env.DERIVED_DATA_PATH }}/SourcePackages
                        ${{ env.DERIVED_DATA_PATH }}/CompilationCache.noindex
            """, env=".derivedData/OTHER")
        expect("a workflow whose env moves the root is caught although its list normalises clean",
               run([good_a, env_other], F, owners(good_a, env_other)), 1)
        job_override = fixture("""
            jobs:
              n:
                env:
                  DERIVED_DATA_PATH: .derivedData/OTHER
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{ env.DERIVED_DATA_PATH }}/SourcePackages
                        ${{ env.DERIVED_DATA_PATH }}/CompilationCache.noindex
            """)
        expect("a job-level env override of the root is caught",
               run([good_a, job_override], F, owners(good_a, job_override)), 1)
        caller_other = fixture("""
            jobs:
              o:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: .derivedData/OTHER
            """)
        expect("a composite caller passing a different literal root is caught",
               run([good_a, caller_other], F, owners(good_a)), 1)
        caller_env = fixture("""
            jobs:
              p:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: ${{ env.DERIVED_DATA_PATH }}
            """)
        expect("(control) a composite caller passing the env expression resolves to the root",
               run([good_a, caller_env], F, owners(good_a)), 0)
        caller_no_env = fixture("""
            jobs:
              q:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: ${{ env.DERIVED_DATA_PATH }}
            """, env=None)
        expect("a composite caller using the env expression with NO env in force is caught",
               run([good_a, caller_no_env], F, owners(good_a)), 1)
        caller_other_expr = fixture("""
            jobs:
              r:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: ${{ runner.temp }}/dd
            """)
        expect("a composite caller passing an unrelated expression is caught",
               run([good_a, caller_other_expr], F, owners(good_a)), 1)
        expect("the module constants agree with themselves on the root",
               run([good_a, good_b], F, owners(good_a, good_b), EXPECTED_ROOT), 0)
        step_override = fixture("""
            jobs:
              s:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    env:
                      DERIVED_DATA_PATH: .derivedData/OTHER
                    with:
                      derived-data-path: ${{ env.DERIVED_DATA_PATH }}
            """)
        expect("a step-level env override on the calling step is caught",
               run([good_a, step_override], F, owners(good_a)), 1)
        reusable_input = fixture("""
            jobs:
              t:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: ${{ inputs.derived-data-path }}
            """)
        expect("a workflow caller passing the INPUTS expression is not resolved through the env",
               run([good_a, reusable_input], F, owners(good_a)), 1)
        reusable_job = fixture("""
            jobs:
              u:
                uses: ./.github/workflows/build.yml
                with:
                  derived-data-path: .derivedData/OTHER
            """)
        expect("a job that calls a reusable workflow with another root is caught",
               run([good_a, reusable_job], F, owners(good_a)), 1)
        nested_forward = fixture("""
            name: outer
            runs:
              using: composite
              steps:
                - uses: ./.github/actions/xcode-ci-setup
                  with:
                    derived-data-path: ${{ inputs.derived-data-path }}
            """, env=None)
        expect("(control) a composite forwarding its own input whole is accepted",
               run([good_a, nested_forward], F, owners(good_a)), 0)
        nested_literal = fixture("""
            name: outer
            runs:
              using: composite
              steps:
                - uses: ./.github/actions/xcode-ci-setup
                  with:
                    derived-data-path: .derivedData/OTHER
            """, env=None)
        expect("a composite passing a different literal root to a nested action is caught",
               run([good_a, nested_literal], F, owners(good_a)), 1)
        nested_env = fixture("""
            name: outer
            runs:
              using: composite
              steps:
                - uses: ./.github/actions/xcode-ci-setup
                  with:
                    derived-data-path: ${{ env.DERIVED_DATA_PATH }}
            """, env=None)
        expect("a composite passing the env expression, which a manifest cannot resolve, is caught",
               run([good_a, nested_env], F, owners(good_a)), 1)
        spaced_root = fixture("""
            jobs:
              w:
                steps:
                  - uses: ./.github/actions/xcode-ci-setup
                    with:
                      derived-data-path: ".derivedData/CI "
            """)
        expect("a quoted root with trailing whitespace is not the root",
               run([good_a, spaced_root], F, owners(good_a)), 1, "whitespace is part of the value")
        # A manifest with a default, and callers that omit the argument: the
        # default is the producer. Laid out under a fake repo root so the caller's
        # `./.github/actions/<name>` resolves to the manifest.
        mroot = os.path.join(tmp, "mrepo")
        fixture("""
            name: m
            inputs:
              derived-data-path:
                required: false
                default: .derivedData/OTHER
            runs:
              using: composite
              steps: []
            """, os.path.join("mrepo", ".github/actions/setup/action.yml"), env=None)
        omitting = fixture("""
            jobs:
              y:
                steps:
                  - uses: ./.github/actions/setup
            """, os.path.join("mrepo", ".github/workflows/y.yml"))
        expect("a manifest default other than the root is caught even with no caller passing it",
               run([good_a, os.path.join(mroot, ".github/actions/setup/action.yml")], F, owners(good_a), DD_LITERAL, (), mroot), 1,
               "inputs.derived-data-path.default")
        expect("a caller omitting the argument resolves through the manifest default",
               run([good_a, omitting], F, owners(good_a), DD_LITERAL, (), mroot), 1, "manifest default")
        fixture("""
            name: m2
            inputs:
              derived-data-path:
                required: true
            runs:
              using: composite
              steps: []
            """, os.path.join("mrepo", ".github/actions/strict/action.yml"), env=None)
        omitting_required = fixture("""
            jobs:
              z:
                steps:
                  - uses: ./.github/actions/strict
            """, os.path.join("mrepo", ".github/workflows/z.yml"))
        expect("a caller omitting a required input with no default is caught",
               run([good_a, omitting_required], F, owners(good_a), DD_LITERAL, (), mroot), 1, "required input not passed")
        input_path = fixture("""
            jobs:
              v:
                steps:
                  - uses: actions/cache/restore@v5
                    with:
                      key: ${{ runner.os }}-${{ runner.arch }}-x-xcode-abc
                      path: |
                        ${{ inputs.derived-data-path }}/SourcePackages
                        ${{ inputs.derived-data-path }}/CompilationCache.noindex
            """)
        expect("a workflow cache step spelling the root as the INPUTS expression is caught although it normalises clean",
               run([good_a, input_path], F, owners(good_a, input_path)), 1)

        # --- #2593 item 3: discovery reaches nested manifests and .yaml.
        repo = os.path.join(tmp, "repo")
        for rel in (".github/workflows/a.yml", ".github/workflows/b.yaml",
                    ".github/actions/top/action.yml", ".github/actions/cache/xcode/action.yaml"):
            fixture("{}\n", os.path.join("repo", rel), env=None)
        for rel in (".github/actions/top/README.yml", ".github/workflows/nested/c.yml", "action.yml"):
            fixture("{}\n", os.path.join("repo", rel), env=None)  # decoys: not manifests, or outside the scanned roots
        got = discover(repo)
        want = sorted([".github/workflows/a.yml", ".github/workflows/b.yaml",
                       ".github/actions/top/action.yml", ".github/actions/cache/xcode/action.yaml"])
        if got == want:
            print("ok   [discover finds nested action manifests and .yaml, and nothing else]")
        else:
            print(f"FAIL [discover] got {got}, wanted {want}")
            fails += 1

    if fails:
        print("== check-cache-paths self-test FAIL ==")
        return 1
    print("== check-cache-paths self-test PASS ==")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    sys.exit(check(discover("."), EXPECTED_PATHS, EXPECTED_OWNERS, EXPECTED_ROOT, EXPECTED_OTHER, "."))
