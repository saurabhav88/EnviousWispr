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


def normalise(entry: str) -> str:
    """Collapse the three spellings of the DerivedData root to one token."""
    e = entry.strip()
    while "${{" in e:
        start = e.index("${{")
        end = e.index("}}", start) + 2
        e = e[:start] + "<DD>" + e[end:]
    if e.startswith(DD_LITERAL):
        e = "<DD>" + e[len(DD_LITERAL):]
    return e


def cache_steps(path: str):
    """Yield (file, unit, step-name, raw path lines) for every cache step."""
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
            if "actions/cache/restore" in uses or "actions/cache/save" in uses:
                raw = (st.get("with", {}) or {}).get("path", "") or ""
                lines = [ln for ln in raw.strip().split("\n") if ln.strip()]
                yield path, unit, st.get("name", uses), lines


def check(files) -> int:
    found, bad = [], []
    for f in files:
        for src, unit, name, lines in cache_steps(f):
            commented = [ln.strip() for ln in lines if ln.strip().startswith("#")]
            norm = tuple(normalise(ln) for ln in lines)
            found.append((src, unit, name, norm, commented))

    if not found:
        print("::error title=cache-paths::no actions/cache steps found — this check is blind, not clean")
        return 1

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
                  path: |
                    .derivedData/CI/SourcePackages
                    .derivedData/CI/Build
        """)

    cases = [
        ("two spellings of one list agree", [good_a, good_b], 0),
        ("a comment inside path: is caught", [good_a, commented], 1),
        ("two different lists are caught", [good_a, divergent], 1),
        ("no cache steps at all is NOT clean", [fixture("jobs:\n  e:\n    steps: []\n")], 1),
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

    for p in [good_a, good_b, commented, divergent]:
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
