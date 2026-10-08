#!/usr/bin/env python3
"""Self-test for scripts/lib/l10n-build-with-receipt.sh and its two callers (#3524 PR 3).

Runs the REAL wrapper, receipt helper and catalog script against owned git fixtures. The build is
a stub `xcodebuild` that only writes fixture `.stringsdata`; for build-dev-app.sh every external
boundary (security, the dev-app lock, pgrep, codesign, deploy and launch tools) is a stub on PATH
or in the fixture checkout, so no real app, lock, default or cache is touched.

Usage: python3 scripts/lib/l10n-build-with-receipt-test.py
"""
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

LIB = pathlib.Path(__file__).resolve().parent
SCRIPTS = LIB.parent
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_AUTHOR_NAME": "t",
           "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
TARGETS = re.findall(r'"(EnviousWispr[A-Za-z]*)"',
                     re.search(r"PRODUCTION_TARGETS = \[(.*?)\]", (LIB / "l10n-catalog-sync.sh").read_text(), re.S).group(1))
INPUTS = {
    "Project.swift": "let project = 1\n",
    "Package.swift": "let package = 1\n",
    "Sources/EnviousWispr/Resources/Info.plist": "<plist/>\n",
    "Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift": "let whatsNew = 1\n",
    "Sources/EnviousWisprCore/A.swift": "let a = 1\n",
}
# The stub build: records its argv and the receipt's presence, then behaves as STUB_* asks.
XCODEBUILD = r'''#!/usr/bin/env bash
# The receipt helper asks the real Xcode which build it is; only the build itself is stubbed.
if [ "$1" = "-version" ]; then exec /usr/bin/xcodebuild -version; fi
echo "argv:$*" >> "$TRACE"
echo "cwd:$(pwd -P)" >> "$TRACE"
if [ "$1" = "-resolvePackageDependencies" ]; then exit 0; fi
dd=""; prev=""
for a in "$@"; do [ "$prev" = "-derivedDataPath" ] && dd="$a"; prev="$a"; done
[ -e "$dd/ew-l10n-receipt.json" ] && echo "receipt-during-build:present" >> "$TRACE" || echo "receipt-during-build:absent" >> "$TRACE"
if [ -n "${STUB_SLEEP:-}" ]; then echo "$$" > "$TRACE.pid"; sleep "$STUB_SLEEP"; fi
if [ -z "${STUB_NO_EXTRACT:-}" ]; then
  for t in __TARGETS__; do
    d="$dd/Build/Intermediates.noindex/EnviousWispr.build/Dev/$t.build/Objects-normal/arm64"
    mkdir -p "$d"
    printf '{"source":"/f.swift","tables":{"Localizable":[{"key":"%s copy"}]},"version":1}' "$t" > "$d/File.stringsdata"
  done
  mkdir -p "$dd/Build/Products/Dev/EnviousWispr Local.app"
fi
[ -n "${STUB_EDIT_INPUT:-}" ] && echo "let a = edited during the build" > "$STUB_EDIT_INPUT"
[ -n "${STUB_LOCK_DIR:-}" ] && chmod 555 "$dd"
exit "${STUB_RC:-0}"
'''.replace("__TARGETS__", " ".join(TARGETS))

fails = cases = 0


def expect(label, got, want):
    global fails, cases
    cases += 1
    if got == want:
        print(f"ok   [{label}]")
    else:
        fails += 1
        print(f"FAIL [{label}] expected {want!r}, got {got!r}")


def git(repo, *args):
    env = {**{k: v for k, v in os.environ.items() if not k.startswith("GIT_")}, **GIT_ENV}
    return subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=repo, check=True,
                          capture_output=True, text=True, env=env).stdout.strip()


def make_repo(root):
    repo = root / "repo"
    (repo / "scripts/lib").mkdir(parents=True)
    for name in ("l10n-build-receipt.py", "l10n-catalog-sync.sh", "l10n-build-with-receipt.sh"):
        shutil.copy(LIB / name, repo / "scripts/lib" / name)
    for rel, text in INPUTS.items():
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / rel).write_text(text)
    (repo / ".gitignore").write_text(".derivedData/\nbin/\ntrace*\n")
    git(repo, "init", "-q", "-b", "main")
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "fixture")
    bin_dir = repo / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "xcodebuild"
    stub.write_text(XCODEBUILD)
    stub.chmod(0o755)
    return repo


def env_for(repo, **extra):
    env = {**{k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "STUB_"))}, **GIT_ENV,
           "PATH": f"{repo / 'bin'}{os.pathsep}{os.environ['PATH']}", "TRACE": str(repo / "trace")}
    env.update({k: str(v) for k, v in extra.items()})
    return env


def wrap(repo, derived, *build_args, direct=False, **extra):
    """Run the wrapper the way build-dev-app.sh does (sourced, set -euo pipefail, signal traps) or
    the way the build-only command does (run directly)."""
    cmd_args = ["xcodebuild", "build", "-scheme", "EnviousWispr-Dev", "-configuration", "Dev",
                "-derivedDataPath", str(derived), *build_args]
    if direct:
        argv = [str(repo / "scripts/lib/l10n-build-with-receipt.sh"), str(derived), "--", *cmd_args]
    else:
        script = ('set -euo pipefail; trap "exit 130" INT; trap "exit 143" TERM; '
                  f'. "{repo}/scripts/lib/l10n-build-with-receipt.sh"; '
                  f'ew_l10n_build_with_receipt "{repo}" "{derived}" "$@"; echo "after-wrapper-rc:0"')
        argv = ["bash", "-c", script, "wrap", *cmd_args]
    return subprocess.run(argv, cwd=repo, env=env_for(repo, **extra), capture_output=True, text=True)


def trace(repo):
    p = repo / "trace"
    return p.read_text().splitlines() if p.exists() else []


def extraction_oracle(derived):
    h = hashlib.sha256()
    rels = sorted(str(p.relative_to(derived)) for p in derived.rglob("File.stringsdata"))
    for rel in rels:
        h.update(rel.encode() + b"\0" + hashlib.sha256((derived / rel).read_bytes()).hexdigest().encode() + b"\n")
    return len(rels), h.hexdigest()


def helper_tree(repo, commit):
    out = subprocess.run([sys.executable, str(repo / "scripts/lib/l10n-build-receipt.py"), "input-digest", "--repo",
                          str(repo), "--commit", commit, "--configuration", "Dev"], capture_output=True, text=True,
                         check=True, env=env_for(repo)).stdout
    return json.loads(out)


def main():
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout.split()[-1]
    with tempfile.TemporaryDirectory(prefix="l10n-wrap-test-") as tmp:
        root = pathlib.Path(tmp).resolve()

        # 1-4. Success: the old receipt is gone before the build, the build gets its exact arguments,
        # and the receipt names the pre-build inputs and the extraction the build left.
        repo = make_repo(root / "ok")
        dd = repo / ".derivedData/Dev"
        dd.mkdir(parents=True)
        (dd / "ew-l10n-receipt.json").write_text('{"stale": true}')
        r = wrap(repo, dd, "ARCHS=arm64", "-destination", "generic/platform=macOS")
        expect("1 the old receipt is removed BEFORE the build runs", "receipt-during-build:absent" in trace(repo), True)
        expect("2 the build receives exactly the arguments given, in the wrapper's checkout",
               [l for l in trace(repo) if l.startswith(("argv:", "cwd:"))][:1] + [l for l in trace(repo) if l.startswith("cwd:")][:1],
               [f"argv:build -scheme EnviousWispr-Dev -configuration Dev -derivedDataPath {dd} ARCHS=arm64 "
                "-destination generic/platform=macOS", f"cwd:{repo}"])
        receipt = json.loads((dd / "ew-l10n-receipt.json").read_text()) if (dd / "ew-l10n-receipt.json").exists() else None
        want = helper_tree(repo, git(repo, "rev-parse", "HEAD"))
        count, digest = extraction_oracle(dd)
        expect("3 a successful build publishes a complete receipt for the pre-build inputs",
               (r.returncode, receipt),
               (0, {**want, "xcode_build": xcode, "extraction_count": count, "extraction_digest": digest}))
        expect("4 the wrapper returns to its caller with status 0", "after-wrapper-rc:0" in r.stdout, True)

        # 5. A failing build keeps its status and leaves no receipt.
        repo = make_repo(root / "fail")
        dd = repo / ".derivedData/Dev"
        r = wrap(repo, dd, STUB_RC=65)
        expect("5 a failed build keeps its exit status (65) and leaves no receipt",
               (r.returncode, (dd / "ew-l10n-receipt.json").exists(), "after-wrapper-rc" in r.stdout), (65, False, False))

        # 6. Inputs that moved during the build: success stays success, no receipt, a separate report.
        repo = make_repo(root / "moved")
        dd = repo / ".derivedData/Dev"
        r = wrap(repo, dd, STUB_EDIT_INPUT=repo / "Sources/EnviousWisprCore/A.swift")
        expect("6 inputs changed during a successful build: status 0, no receipt, reported as unavailable",
               (r.returncode, (dd / "ew-l10n-receipt.json").exists(), "catalog receipt unavailable: the build succeeded" in r.stderr,
                "changed while the build ran" in r.stderr), (0, False, True, True))

        # 7. A successful build that left no extraction: no receipt, reported.
        repo = make_repo(root / "noextract")
        dd = repo / ".derivedData/Dev"
        r = wrap(repo, dd, STUB_NO_EXTRACT=1)
        expect("7 no extraction: status 0, no receipt, reported", (r.returncode, (dd / "ew-l10n-receipt.json").exists(),
               "catalog receipt unavailable" in r.stderr), (0, False, True))

        # 8. Interrupted mid-build: the caller's trap status, and no receipt (the old one was removed first).
        repo = make_repo(root / "interrupt")
        dd = repo / ".derivedData/Dev"
        dd.mkdir(parents=True)
        (dd / "ew-l10n-receipt.json").write_text('{"stale": true}')
        cmd = ["bash", "-c", ('set -euo pipefail; trap "exit 130" INT; '
                              f'. "{repo}/scripts/lib/l10n-build-with-receipt.sh"; '
                              f'ew_l10n_build_with_receipt "{repo}" "{dd}" xcodebuild build -derivedDataPath "{dd}"')]
        proc = subprocess.Popen(cmd, cwd=repo, env=env_for(repo, STUB_SLEEP=20), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)
        pidfile = pathlib.Path(str(repo / "trace") + ".pid")
        for _ in range(100):
            if pidfile.exists():
                break
            time.sleep(0.1)
        os.killpg(proc.pid, signal.SIGINT)
        proc.communicate(timeout=30)
        expect("8 an interrupted build exits with the caller's trap status and leaves no receipt",
               (pidfile.exists(), proc.returncode, (dd / "ew-l10n-receipt.json").exists()), (True, 130, False))

        # 9. The old receipt cannot be removed: reported, the build still runs and keeps its status,
        # and nothing is published over it.
        repo = make_repo(root / "stuck")
        dd = repo / ".derivedData/Dev"
        (dd / "ew-l10n-receipt.json").mkdir(parents=True)
        r = wrap(repo, dd)
        expect("9 an old receipt that cannot be removed: reported, build runs, status 0, nothing published",
               (r.returncode, "could not remove" in r.stderr, any(l.startswith("argv:") for l in trace(repo)),
                (dd / "ew-l10n-receipt.json").is_dir()), (0, True, True, True))

        # 10. Publication fails (the derived-data directory is read-only after the build).
        repo = make_repo(root / "readonly")
        dd = repo / ".derivedData/Dev"
        r = wrap(repo, dd, STUB_LOCK_DIR=1)
        dd.chmod(0o755)
        expect("10 a receipt that cannot be written: status 0, no receipt, reported",
               (r.returncode, (dd / "ew-l10n-receipt.json").exists(), "catalog receipt unavailable: the build succeeded" in r.stderr),
               (0, False, True))

        # 11. The build-only command: run directly, same order and outcome.
        repo = make_repo(root / "direct")
        dd = repo / ".derivedData/Dev"
        r = wrap(repo, dd, direct=True)
        expect("11 build-only (run directly): status 0 and a receipt that verifies for HEAD",
               (r.returncode, subprocess.run([sys.executable, str(repo / "scripts/lib/l10n-build-receipt.py"), "verify",
                                              "--receipt", str(dd / "ew-l10n-receipt.json"), "--repo", str(repo),
                                              "--commit", git(repo, "rev-parse", "HEAD"), "--derived-data", str(dd),
                                              "--configuration", "Dev"], env=env_for(repo), capture_output=True).returncode),
               (0, 0))
        r = wrap(repo, dd, direct=True, STUB_RC=70)
        expect("11b build-only keeps a failing build's status", r.returncode, 70)
        bad = subprocess.run([str(repo / "scripts/lib/l10n-build-with-receipt.sh"), str(dd), "xcodebuild"],
                             cwd=repo, env=env_for(repo), capture_output=True, text=True)
        expect("11c build-only refuses a call without --", (bad.returncode, "usage:" in bad.stderr), (2, True))

        # 11d. Called from ANOTHER checkout with a relative derived-data path: the fingerprint, the
        # build and the receipt all belong to the wrapper's checkout; the caller's directory is untouched.
        a = make_repo(root / "cross-a")
        b = make_repo(root / "cross-b")
        r = subprocess.run([str(a / "scripts/lib/l10n-build-with-receipt.sh"), ".derivedData/Dev", "--",
                            "xcodebuild", "build", "-derivedDataPath", ".derivedData/Dev"],
                           cwd=b, env=env_for(a), capture_output=True, text=True)
        expect("11d a cross-checkout call builds in the wrapper's checkout and writes only its receipt",
               (r.returncode, [l for l in trace(a) if l.startswith("cwd:")], (a / ".derivedData/Dev/ew-l10n-receipt.json").exists(),
                (b / ".derivedData").exists()), (0, [f"cwd:{a}"], True, False))
        r = subprocess.run(["bash", "-c", f'set -euo pipefail; cd "{b}"; . "{a}/scripts/lib/l10n-build-with-receipt.sh"; '
                            f'ew_l10n_build_with_receipt "{a}" ".derivedData/Dev" xcodebuild build -derivedDataPath .derivedData/Dev; pwd -P'],
                           env=env_for(a), capture_output=True, text=True)
        expect("11e sourced: the caller's working directory is unchanged afterwards", r.stdout.strip().splitlines()[-1:], [str(b)])

        # 11f-11i. The old receipt cannot be removed (derived data read-only): no NEW receipt is
        # published, the build keeps its status, and the retained one is only as good as verification.
        repo = make_repo(root / "retained")
        dd = repo / ".derivedData/Dev"
        assert wrap(repo, dd).returncode == 0 and (dd / "ew-l10n-receipt.json").exists()
        inode = (dd / "ew-l10n-receipt.json").stat().st_ino
        dd.chmod(0o555)
        try:
            r = wrap(repo, dd)
        finally:
            dd.chmod(0o755)
        expect("11f invalidation denied: status 0, reported, the old receipt is not replaced (same inode)",
               (r.returncode, "could not remove" in r.stderr, (dd / "ew-l10n-receipt.json").stat().st_ino == inode),
               (0, True, True))

        def verify(commit):
            return subprocess.run([sys.executable, str(repo / "scripts/lib/l10n-build-receipt.py"), "verify", "--receipt",
                                   str(dd / "ew-l10n-receipt.json"), "--repo", str(repo), "--commit", commit,
                                   "--derived-data", str(dd), "--configuration", "Dev"], env=env_for(repo),
                                  capture_output=True, text=True)
        head = git(repo, "rev-parse", "HEAD")
        expect("11g the retained receipt still verifies only because code and extraction are unchanged", verify(head).returncode, 0)
        (repo / "Sources/EnviousWisprCore/A.swift").write_text("let a = 2\n")
        git(repo, "commit", "-q", "-am", "pushed change")
        moved = verify(git(repo, "rev-parse", "HEAD"))
        expect("11h ... and is unavailable for changed code", (moved.returncode, "not of the pushed code" in moved.stderr), (2, True))
        next(dd.rglob("File.stringsdata")).write_text('{"rebuilt": true}')
        rebuilt = verify(head)
        expect("11i ... and unavailable once the extraction changes", (rebuilt.returncode, "extraction changed" in rebuilt.stderr),
               (2, True))

        # 12-13. The real build-dev-app.sh, every external boundary stubbed: the receipt is written
        # after the compile; a later step failing (codesign) keeps the script's failure and the
        # receipt, whose claim is the compile's extraction only. Nothing is quit or launched.
        repo = make_repo(root / "entry")
        shutil.copy(SCRIPTS / "build-dev-app.sh", repo / "scripts/build-dev-app.sh")
        lib = repo / "scripts/lib"
        (lib / "ensure-generated.sh").write_text('ew_ensure_generated() { echo generate >> "$TRACE"; }\n')
        (lib / "launch-check.sh").write_text('ew_wait_for_launch() { echo launch-check >> "$TRACE"; return 1; }\n')
        (lib / "spm-seed.sh").write_text('ew_seed_release_all() { :; }\new_seed_consume() { :; }\n'
                                         'ew_seed_resolve_or_unseed() { shift; "$@"; }\new_seed_publish() { :; }\n')
        (lib / "dev-app-lock.py").write_text('import os, sys\nopen(os.environ["TRACE"], "a").write("lock:" + " ".join(sys.argv[1:2]) + "\\n")\n')
        bins = {"security": 'echo "  1) ABC \\"EnviousWispr Dev\\""', "pgrep": 'echo "pgrep:$*" >> "$TRACE"; exit 1',
                "codesign": 'echo "codesign:$*" >> "$TRACE"; exit "${STUB_CODESIGN_RC:-0}"',
                "open": 'echo "OPEN:$*" >> "$TRACE"', "ditto": 'echo "ditto" >> "$TRACE"', "xattr": ':',
                "plutil": 'echo "plutil" >> "$TRACE"; exit 1', "ps": 'echo "ps:$*" >> "$TRACE"'}
        for name, body in bins.items():
            (repo / "bin" / name).write_text(f"#!/usr/bin/env bash\n{body}\n")
            (repo / "bin" / name).chmod(0o755)
        r = subprocess.run(["bash", str(repo / "scripts/build-dev-app.sh")], cwd=repo,
                           env=env_for(repo, STUB_CODESIGN_RC=1, EW_DEV_APP_LABEL="test"), capture_output=True, text=True,
                           timeout=120)
        dd = repo / ".derivedData/Dev"
        t = trace(repo)
        expect("12 build-dev-app.sh: the compile ran inside the wrapper with its full argument list",
               [l for l in t if l.startswith("argv:build")][:1],
               [f"argv:build -project EnviousWispr.xcodeproj -scheme EnviousWispr-Dev -configuration Dev -derivedDataPath {dd} "
                "-destination generic/platform=macOS -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=YES "
                "VALID_ARCHS=arm64"])
        expect("13 a later failure (codesign) keeps exit 1; the compile's receipt stays; nothing was opened",
               (r.returncode, (dd / "ew-l10n-receipt.json").exists(), any(l.startswith("OPEN:") for l in t),
                "lock:claim" in t), (1, True, False, True))
        expect("13c the process probe was the stub (no real app could be found or signalled)",
               any(l.startswith("pgrep:") for l in t), True)
        r = subprocess.run(["bash", str(repo / "scripts/build-dev-app.sh")], cwd=repo,
                           env=env_for(repo, STUB_RC=65, EW_DEV_APP_LABEL="test"), capture_output=True, text=True, timeout=120)
        expect("13b build-dev-app.sh: a failed compile exits 65 and leaves no receipt",
               (r.returncode, (dd / "ew-l10n-receipt.json").exists()), (65, False))

    print(f"self-test: {cases} cases, {fails} failure(s)")
    return 1 if fails or not cases else 0


if __name__ == "__main__":
    sys.exit(main())
