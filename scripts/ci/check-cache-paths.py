#!/usr/bin/env python3
"""scripts/ci/check-cache-paths.py — the four Xcode cache path lists must agree.

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

WHAT IS CHECKED
  1. Every actions/cache restore or save step across the workflows and the
     composite action is found by PARSING, never by grepping for a name.
  2. Its `path` list is normalised — any `${{ … }}` expression and the literal
     `.derivedData/CI` both collapse to <DD> — and every list must be equal.
  3. No entry may begin with `#`. That is the specific trap above, and it is
     called out separately so the failure names its own cause.

Usage:
  check-cache-paths.sh [--self-test]
"""
import glob
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
DD_EXPRESSIONS = (
    "${{ env.DERIVED_DATA_PATH }}",
    "${{ inputs.derived-data-path }}",
    DD_LITERAL,
)


def normalise(entry: str) -> str:
    """Collapse the KNOWN DerivedData roots to one token, leaving all else intact."""
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
    e = "".join(out)
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


def in_family(key: str) -> bool:
    return any(m in key for m in XCODE_KEY_MARKERS)


def cache_steps(path: str):
    """Yield (file, unit, name, path lines, in-family) for every cache step."""
    doc = yaml.safe_load(open(path))
    if not isinstance(doc, dict):
        return
    units = []
    if "jobs" in doc:
        units = [(n, (j or {}).get("steps") or []) for n, j in (doc["jobs"] or {}).items()]
    elif doc.get("runs", {}).get("using") == "composite":
        units = [("composite", doc["runs"]["steps"])]
    for unit, steps in units:
        for st in steps:
            uses = str(st.get("uses", ""))
            if "actions/cache/restore" not in uses and "actions/cache/save" not in uses:
                continue
            with_ = st.get("with", {}) or {}
            raw = with_.get("path", "") or ""
            lines = [ln for ln in raw.strip().split("\n") if ln.strip()]
            yield path, unit, st.get("name", uses), lines, in_family(str(with_.get("key", "")))


def check(files) -> int:
    found, other, bad = [], [], []
    for f in files:
        for src, unit, name, lines, family in cache_steps(f):
            commented = [ln.strip() for ln in lines if ln.strip().startswith("#")]
            norm = tuple(normalise(ln) for ln in lines)
            (found if family else other).append((src, unit, name, norm, commented))

    if not found:
        print("::error title=cache-paths::no Xcode cache steps found — this check is blind, not clean")
        return 1

    # Excluded steps are PRINTED, never merely skipped. A step that falls out of
    # the family because its key was reworded would otherwise vanish in silence,
    # and this check would keep reporting a clean, smaller set.
    if other:
        print("not in the Xcode cache family, excluded from the comparison:")
        for src, unit, name, _, _ in other:
            print(f"    {src.split('/')[-1]} :: {unit} :: {name}")
        print()

    print(f"{'unit':56s} entries")
    print("-" * 78)
    for src, unit, name, norm, commented in found:
        print(f"{src.split('/')[-1] + ' :: ' + unit:56s} {len(norm)}")
        for e in norm:
            print(f"    {e}")
        if commented:
            bad.append((src, unit, "comment lines inside `path:` — YAML block scalars have no comments, "
                                   "so these become cache paths and change the cache version: "
                                   + "; ".join(commented[:2])))

    lists = {n for _, _, _, n, _ in found}
    if len(lists) != 1:
        for i, l in enumerate(sorted(lists)):
            owners = [f"{s.split('/')[-1]}::{u}" for s, u, _, n, _ in found if n == l]
            bad.append(("", "", f"list {i + 1} ({', '.join(owners)}): {list(l)}"))
        bad.append(("", "", "the path lists disagree, so a restore can never match a save. "
                            "Cache version is a hash of this list."))

    if bad:
        print()
        for src, unit, msg in bad:
            where = f"{src} :: {unit}: " if src else ""
            print(f"::error title=cache-paths::{where}{msg}")
        return 1

    print(f"\n==> cache-paths OK: {len(found)} steps, one identical {len(next(iter(lists)))}-entry list")
    return 0


def self_test() -> int:
    """Two-way control. A checker only ever run on correct input has not been seen to fail."""
    import tempfile, os, textwrap
    fails = 0

    def fixture(body: str) -> str:
        fd, p = tempfile.mkstemp(suffix=".yml")
        os.write(fd, textwrap.dedent(body).encode())
        os.close(fd)
        return p

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
        """)
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

    cases = [
        ("two spellings of one list agree", [good_a, good_b], 0),
        ("a comment inside path: is caught", [good_a, commented], 1),
        ("two different lists are caught", [good_a, divergent], 1),
        ("no Xcode cache steps at all is NOT clean", [fixture("jobs:\n  e:\n    steps: []\n")], 1),
        ("a DIFFERENT root is a difference, not <DD>", [good_a, other_root], 1),
        ("an unrelated cache is ignored, not reded", [good_a, good_b, unrelated], 0),
        ("a save keyed by cache-primary-key IS in the family", [good_a, primary_keyed], 1),
        ("expression whitespace is not a difference", [good_a, spaced], 0),
    ]
    for label, files, want in cases:
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            got = check(files)
        if got == want:
            print(f"ok   [{label}] rc={got}")
        else:
            print(f"FAIL [{label}] wanted rc={want}, got {got}")
            fails += 1

    for p in [good_a, good_b, commented, divergent, other_root, unrelated, spaced, primary_keyed]:
        os.unlink(p)

    if fails:
        print("== check-cache-paths self-test FAIL ==")
        return 1
    print("== check-cache-paths self-test PASS ==")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sys.exit(self_test())
    sys.exit(check(sorted(glob.glob(".github/workflows/*.yml"))
                   + sorted(glob.glob(".github/actions/*/action.yml"))))
