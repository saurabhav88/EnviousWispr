#!/usr/bin/env python3
"""scripts/lib/validation-receipt.py: the local validation receipt (#3729 PR-C).

A full, unfiltered, passing `scripts/xcode-test.sh` run proves one input tree.
This helper owns that proof's identity, schema and publication, so the producer
(xcode-test.sh) and the verifier (scripts/githooks/pre-push) read one contract.

Identity is the git INDEX tree (`git write-tree`), captured before generation and
checked again before publication. Staged changes are fine when the working files
match them; a tracked file that differs from the index, or an untracked file that
either input classifier calls an input, makes the run ineligible. The input
classifiers are the checkout's own scripts/ci/classify-changes.sh (build inputs)
and scripts/ci/needs-eval-packages.sh (eval-package inputs); this file keeps no
list of its own.

Known limit: the tree is checked at the start and the end, not continuously. An edit made during
the run and reverted before it ends is not detected; the lock stops a second run, not an editor.

Publication writes a complete temporary file in the receipt directory and
hard-links it to the final name, so a reader sees no file or a whole one, and an
existing final file is a failure, never an overwrite.

Usage:
  validation-receipt.py path       --root R
  validation-receipt.py invalidate --root R
  validation-receipt.py capture    --root R           identity JSON on stdout
  validation-receipt.py publish    --root R --start JSON --field KEY=VALUE ...
  validation-receipt.py validate   FILE [--tree T] [--toolchain B]
  validation-receipt.py --self-test

Exit codes: 0 ok; 3 ineligible (reason on stderr, no receipt); 1 error.
"""
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
RECEIPT_REL = ".derivedData/Test/ew-validation-receipt.json"
REQUIRED = {
    "schema": int, "tree": str, "head": str, "toolchain": str,
    "configuration": str, "scheme": str, "bundles": list, "executed_tests": int,
    "debug_verdict": str, "eval_verdict": str, "result_bundle": str, "utc": str,
}


# Source roots the full run compiles by glob: the app and test targets, and the three eval packages.
IGNORED_SWIFT_ROOTS = ("Sources", "Tests", "scripts/eval/apple_runner/Sources",
                       "scripts/eval/alias_runner/Sources", "scripts/eval/prompt_render/Sources")
# The full Debug run's required bundles: lane-verdict.sh's default list.
EXPECTED_BUNDLES = {"EnviousWisprTests", "EnviousWisprDesktopEffectsTests", "EnviousWisprASRTests"}


class Ineligible(Exception):
    pass


def receipt_path(root):
    return Path(root) / RECEIPT_REL


def git(root, *args, check=True):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr.decode(errors='replace').strip()}")
    return r


def toolchain():
    r = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"xcodebuild -version failed (exit {r.returncode})")
    for line in r.stdout.splitlines():
        if line.startswith("Build version "):
            build = line[len("Build version "):].strip()
            if build:
                return build
    raise RuntimeError("xcodebuild -version printed no 'Build version' line")


def classifier_says_input(root, script, key, files):
    """Run one input classifier on a newline file list; True when it calls any an input."""
    out = tempfile.NamedTemporaryFile(prefix="ew-receipt-classify.", delete=False)
    out.close()
    try:
        env = dict(os.environ, GITHUB_OUTPUT=out.name)
        r = subprocess.run(["bash", str(Path(root) / script), "--classify-only"],
                           input="\n".join(files) + "\n", text=True, env=env,
                           capture_output=True)
        if r.returncode != 0:
            raise RuntimeError(f"{script} --classify-only exited {r.returncode}")
        values = [ln.split("=", 1)[1].strip() for ln in Path(out.name).read_text().splitlines()
                  if ln.startswith(key + "=")]
        if len(values) != 1 or values[0] not in ("true", "false"):
            raise RuntimeError(f"{script} wrote no single {key}=true|false line")
        return values[0] == "true"
    finally:
        os.unlink(out.name)


def capture(root):
    root = Path(root)
    tree = git(root, "write-tree").stdout.decode().strip()
    head = git(root, "rev-parse", "HEAD").stdout.decode().strip()
    # A tracked file flagged assume-unchanged or skip-worktree can differ from the index while
    # `git diff` reports clean, and the build still compiles the working copy.
    flags = [e for e in git(root, "ls-files", "-v", "-z").stdout.decode().split("\0") if e]
    if any(e[0].islower() or e[0] == "S" for e in flags):
        raise Ineligible("a tracked file is flagged assume-unchanged or skip-worktree (clear the flag)")
    if git(root, "diff", "--quiet", "--no-ext-diff", check=False).returncode != 0:
        raise Ineligible("a tracked file differs from the index (stage it, or restore it)")
    # The build globs Sources/ and Tests/, and each eval package compiles its own Sources/, so an
    # IGNORED Swift file there is compiled yet outside the index tree. (Other ignored Swift, such as
    # an eval package's .build/checkouts or an uncompiled runner, is not an input.)
    ignored = [p for p in git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z",
                              "--", *IGNORED_SWIFT_ROOTS).stdout.decode().split("\0") if p]
    if any(p.endswith(".swift") for p in ignored):
        raise Ineligible("an ignored Swift file under a compiled source root is outside the index tree")
    untracked = [p for p in git(root, "ls-files", "--others", "--exclude-standard", "-z")
                 .stdout.decode().split("\0") if p]
    if untracked:
        if classifier_says_input(root, "scripts/ci/classify-changes.sh", "needs_build", untracked):
            raise Ineligible("an untracked file is a build input (add it, or remove it)")
        if classifier_says_input(root, "scripts/ci/needs-eval-packages.sh", "needs_eval_packages", untracked):
            raise Ineligible("an untracked file is an eval-package input (add it, or remove it)")
    return {"tree": tree, "head": head, "toolchain": toolchain()}


def invalidate(root):
    p = receipt_path(root)
    try:
        p.unlink()
    except FileNotFoundError:
        pass
    if p.exists():
        raise RuntimeError(f"could not remove {p}")


def validate(data, tree=None, build=None, root=None):
    """Raise ValueError unless data is a complete schema-1 receipt (and matches tree/build)."""
    if not isinstance(data, dict):
        raise ValueError("receipt is not a JSON object")
    for key, kind in REQUIRED.items():
        if key not in data:
            raise ValueError(f"receipt lacks {key}")
        value = data[key]
        if kind is int and (isinstance(value, bool) or not isinstance(value, int)):
            raise ValueError(f"receipt {key} is not an integer")
        if not isinstance(value, kind):
            raise ValueError(f"receipt {key} is not a {kind.__name__}")
    for key, kind in REQUIRED.items():
        if kind is str and not data[key].strip():
            raise ValueError(f"receipt {key} is empty")
    bundles = data["bundles"]
    if (any(not isinstance(b, str) for b in bundles)
            or len(bundles) != len(EXPECTED_BUNDLES)
            or set(bundles) != EXPECTED_BUNDLES):
        raise ValueError("receipt does not record all three required Debug bundles")
    if data["scheme"] != "EnviousWispr":
        raise ValueError("receipt does not record the canonical Debug scheme")
    if data["schema"] != SCHEMA:
        raise ValueError(f"receipt schema {data['schema']} is not {SCHEMA}")
    if len(data["tree"]) != 40 or any(c not in "0123456789abcdef" for c in data["tree"]):
        raise ValueError("receipt tree is not a full object id")
    if data["configuration"] != "Debug" or data["debug_verdict"] != "PASS" or data["eval_verdict"] != "PASS":
        raise ValueError("receipt does not record a passing Debug and eval run")
    if data["executed_tests"] < 1 or not data["bundles"]:
        raise ValueError("receipt records no executed tests or bundles")
    if tree is not None and data["tree"] != tree:
        raise ValueError("receipt tree does not match")
    if build is not None and data["toolchain"] != build:
        raise ValueError(f"receipt toolchain {data['toolchain']} is not the selected {build}")
    if root is not None:
        if git(root, "cat-file", "-t", data["tree"], check=False).stdout.decode().strip() != "tree":
            raise ValueError("receipt tree is not a tree object in this repository")
    return data


def publish(root, start, fields):
    end = capture(root)  # Ineligible propagates: nothing is published
    if end["tree"] != start["tree"]:
        raise Ineligible("the index tree changed during the run")
    if end["toolchain"] != start["toolchain"]:
        raise Ineligible("the selected Xcode changed during the run")
    data = {"schema": SCHEMA, "tree": start["tree"], "head": start["head"],
            "toolchain": start["toolchain"],
            "utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    for item in fields:
        key, sep, value = item.partition("=")
        if not sep:
            raise RuntimeError(f"field {item!r} is not KEY=VALUE")
        if key == "executed_tests":
            value = int(value)
        elif key == "bundles":
            value = value.split()
        data[key] = value
    validate(data, root=root)
    final = receipt_path(root)
    final.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".ew-validation-receipt.", dir=str(final.parent))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.link(tmp, final)  # FileExistsError: never overwrite another receipt
    finally:
        os.unlink(tmp)
    return final


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if not argv:
        print(__doc__, file=sys.stderr)
        return 1
    cmd, rest = argv[0], argv[1:]
    opts, fields, positional = {}, [], []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--root", "--start", "--tree", "--toolchain") and i + 1 < len(rest):
            opts[a[2:]] = rest[i + 1]; i += 2
        elif a == "--field" and i + 1 < len(rest):
            fields.append(rest[i + 1]); i += 2
        else:
            positional.append(a); i += 1
    try:
        if cmd == "path":
            print(receipt_path(opts["root"]))
        elif cmd == "invalidate":
            invalidate(opts["root"])
        elif cmd == "capture":
            print(json.dumps(capture(opts["root"])))
        elif cmd == "publish":
            print(publish(opts["root"], json.loads(opts["start"]), fields))
        elif cmd == "validate":
            data = json.loads(Path(positional[0]).read_text())
            validate(data, tree=opts.get("tree"), build=opts.get("toolchain"), root=opts.get("root"))
            print("valid")
        else:
            print(f"unknown command {cmd}", file=sys.stderr)
            return 1
    except Ineligible as e:
        print(f"no validation receipt: {e}", file=sys.stderr)
        return 3
    except (KeyError, IndexError):
        print(f"{cmd}: missing argument (see --help in the file header)", file=sys.stderr)
        return 1
    except (RuntimeError, ValueError, OSError, json.JSONDecodeError) as e:
        print(f"validation receipt error: {e}", file=sys.stderr)
        return 1
    return 0


def self_test():
    import shutil
    import stat
    import threading
    here = Path(__file__).resolve()
    results = []

    def case(name, ok, detail=""):
        results.append(ok)
        print(f"{'ok  ' if ok else 'FAIL'} [{name}]{' ' + detail if detail and not ok else ''}")

    tmp = Path(tempfile.mkdtemp(prefix="ew-receipt-selftest-"))
    try:
        root = tmp / "repo"
        (root / "scripts/ci").mkdir(parents=True)
        (root / "scripts/lib").mkdir(parents=True)
        (root / "Sources").mkdir()
        shutil.copyfile(here, root / "scripts/lib/validation-receipt.py")
        # Owned classifier stand-ins with the real output contract: a path under
        # Sources/ is a build input, a path under scripts/eval/ an eval input.
        for name, key, prefix in (("classify-changes.sh", "needs_build", "Sources/"),
                                  ("needs-eval-packages.sh", "needs_eval_packages", "scripts/eval/")):
            (root / "scripts/ci" / name).write_text(
                "#!/usr/bin/env bash\n"
                f"if grep -q '^{prefix}'; then v=true; else v=false; fi\n"
                f"printf '{key}=%s\\n' \"$v\" >>\"$GITHUB_OUTPUT\"\n")
        bindir = tmp / "bin"
        bindir.mkdir()
        xb = bindir / "xcodebuild"
        xb.write_text("#!/usr/bin/env bash\necho 'Xcode 27.0'\necho \"Build version ${FAKE_XCODE_BUILD:-27A266a}\"\n")
        xb.chmod(xb.stat().st_mode | stat.S_IEXEC)
        os.environ["PATH"] = f"{bindir}{os.pathsep}{os.environ['PATH']}"
        os.environ.pop("FAKE_XCODE_BUILD", None)
        run = lambda *a: subprocess.run(["git", "-C", str(root), *a], capture_output=True, check=True)
        run("init", "-q")
        run("config", "user.email", "t@t"); run("config", "user.name", "t")
        (root / "Sources/A.swift").write_text("let a = 1\n")
        run("add", "-A"); run("commit", "-qm", "base")
        fields = ["configuration=Debug", "scheme=EnviousWispr", "bundles=EnviousWisprTests EnviousWisprDesktopEffectsTests EnviousWisprASRTests", "executed_tests=5",
                  "debug_verdict=PASS", "eval_verdict=PASS", "result_bundle=/x.xcresult"]

        start = capture(root)
        p = publish(root, start, fields)
        data = json.loads(p.read_text())
        case("a clean tree publishes a valid receipt", data["tree"] == start["tree"] and data["executed_tests"] == 5)
        case("publication leaves no temporary file",
             [x.name for x in p.parent.iterdir()] == [p.name])
        try:
            publish(root, start, fields); case("an existing receipt is never overwritten", False)
        except FileExistsError:
            case("an existing receipt is never overwritten", True)
        invalidate(root)
        case("invalidate removes the receipt", not p.exists())

        (root / "Sources/A.swift").write_text("let a = 2\n")
        run("add", "Sources/A.swift")
        s2 = capture(root)
        case("staged matching changes are eligible, bound to the index tree",
             s2["tree"] != start["tree"] and s2["head"] == start["head"])
        (root / "Sources/A.swift").write_text("let a = 3\n")
        try:
            capture(root); case("an unstaged tracked change is ineligible", False)
        except Ineligible:
            case("an unstaged tracked change is ineligible", True)
        run("checkout", "--", "Sources/A.swift")
        (root / "Sources/New.swift").write_text("x\n")
        try:
            capture(root); case("an untracked build input is ineligible", False)
        except Ineligible as e:
            case("an untracked build input is ineligible", "build input" in str(e))
        (root / "Sources/New.swift").unlink()
        (root / "scripts/eval").mkdir()
        (root / "scripts/eval/x.swift").write_text("x\n")
        try:
            capture(root); case("an untracked eval input is ineligible", False)
        except Ineligible as e:
            case("an untracked eval input is ineligible", "eval-package input" in str(e))
        shutil.rmtree(root / "scripts/eval")
        run("update-index", "--assume-unchanged", "Sources/A.swift")
        try:
            capture(root); case("an assume-unchanged tracked file is ineligible", False)
        except Ineligible as e:
            case("an assume-unchanged tracked file is ineligible", "assume-unchanged" in str(e))
        run("update-index", "--no-assume-unchanged", "Sources/A.swift")
        run("update-index", "--skip-worktree", "Sources/A.swift")
        try:
            capture(root); case("a skip-worktree tracked file is ineligible", False)
        except Ineligible as e:
            case("a skip-worktree tracked file is ineligible", "skip-worktree" in str(e))
        run("update-index", "--no-skip-worktree", "Sources/A.swift")
        exclude = root / ".git/info/exclude"
        exclude.write_text("Sources/Hidden.swift\nscripts/eval/x/.build/\n")
        (root / "Sources/Hidden.swift").write_text("let hidden = 1\n")
        try:
            capture(root); case("an ignored Swift file under Sources/ is ineligible", False)
        except Ineligible as e:
            case("an ignored Swift file under Sources/ is ineligible", "ignored Swift" in str(e))
        (root / "Sources/Hidden.swift").unlink()
        (root / "scripts/eval/x/.build").mkdir(parents=True)
        (root / "scripts/eval/x/.build/Dep.swift").write_text("let dep = 1\n")
        try:
            capture(root); case("an ignored Swift file in a package build dir is not an input", True)
        except Ineligible as e:
            case("an ignored Swift file in a package build dir is not an input", False, str(e))
        shutil.rmtree(root / "scripts/eval")
        exclude.write_text("")
        (root / "notes.txt").write_text("scratch\n")
        try:
            capture(root); case("an unrelated untracked file is eligible", True)
        except Ineligible:
            case("an unrelated untracked file is eligible", False)
        (root / "notes.txt").unlink()

        s3 = capture(root)
        (root / "Sources/A.swift").write_text("let a = 4\n")
        run("add", "Sources/A.swift")
        try:
            publish(root, s3, fields); case("an index change during the run publishes nothing", False)
        except Ineligible:
            case("an index change during the run publishes nothing", not receipt_path(root).exists())
        s4 = capture(root)
        os.environ["FAKE_XCODE_BUILD"] = "28A1"
        try:
            publish(root, s4, fields); case("a toolchain change during the run publishes nothing", False)
        except Ineligible:
            case("a toolchain change during the run publishes nothing", not receipt_path(root).exists())
        os.environ.pop("FAKE_XCODE_BUILD")
        try:
            publish(root, s4, [f for f in fields if not f.startswith("debug_verdict")] + ["debug_verdict=FAIL"])
            case("a failed verdict cannot be published", False)
        except ValueError:
            case("a failed verdict cannot be published", not receipt_path(root).exists())
        try:
            publish(root, s4, [f for f in fields if not f.startswith("executed")] + ["executed_tests=0"])
            case("zero executed tests cannot be published", False)
        except ValueError:
            case("zero executed tests cannot be published", not receipt_path(root).exists())

        good = json.loads(publish(root, s4, fields).read_text())
        def rejects(name, mutate, **kw):
            d = json.loads(json.dumps(good)); mutate(d)
            try:
                validate(d, **kw); case(name, False)
            except ValueError:
                case(name, True)
        rejects("validate rejects a missing field", lambda d: d.pop("toolchain"))
        rejects("validate rejects a wrong schema", lambda d: d.update(schema=2))
        rejects("validate rejects a boolean count", lambda d: d.update(executed_tests=True))
        rejects("validate rejects a short tree", lambda d: d.update(tree="abc"))
        rejects("validate rejects an unknown tree object", lambda d: d.update(tree="0" * 40), root=root)
        rejects("validate rejects another toolchain", lambda d: None, build="99Z9")
        rejects("validate rejects another tree", lambda d: None, tree="f" * 40)
        rejects("validate rejects a missing bundle", lambda d: d.update(bundles=d["bundles"][:2]))
        rejects("validate rejects a duplicate bundle",
                lambda d: d.update(bundles=[d["bundles"][0]] * 2 + d["bundles"][1:2]))
        rejects("validate rejects a non-string bundle", lambda d: d.update(bundles=d["bundles"][:2] + [None]))
        rejects("validate rejects an unexpected bundle", lambda d: d.update(bundles=d["bundles"][:2] + ["Other"]))
        rejects("validate rejects another scheme", lambda d: d.update(scheme="EnviousWispr-Release"))
        rejects("validate rejects an empty toolchain", lambda d: d.update(toolchain="  "))
        rejects("validate rejects an empty result bundle path", lambda d: d.update(result_bundle=""))
        try:
            validate(good, tree=s4["tree"], build="27A266a", root=root); case("validate accepts the published receipt", True)
        except ValueError as e:
            case("validate accepts the published receipt", False, str(e))
        bad = tmp / "bad.json"
        bad.write_text("{not json")
        r = subprocess.run([sys.executable, str(root / "scripts/lib/validation-receipt.py"), "validate", str(bad)],
                           capture_output=True, text=True)
        case("malformed JSON exits 1 with a named error", r.returncode == 1 and "receipt error" in r.stderr)

        # Racing reader: a reader polling during repeated publications sees no
        # file or one complete valid receipt, never a partial one.
        invalidate(root)
        seen, stop = [], threading.Event()
        def reader():
            path = receipt_path(root)
            while not stop.is_set():
                try:
                    text = path.read_text()
                except FileNotFoundError:
                    seen.append("absent"); continue
                try:
                    validate(json.loads(text)); seen.append("valid")
                except (ValueError, json.JSONDecodeError):
                    seen.append("PARTIAL")
        t = threading.Thread(target=reader); t.start()
        for _ in range(40):
            publish(root, s4, fields); invalidate(root)
        stop.set(); t.join()
        case("a racing reader never sees a partial receipt",
             "PARTIAL" not in seen and "valid" in seen and "absent" in seen,
             f"seen={sorted(set(seen))}")

        r = subprocess.run([sys.executable, str(root / "scripts/lib/validation-receipt.py"), "capture",
                            "--root", str(root)], capture_output=True, text=True)
        (root / "Sources/A.swift").write_text("dirty\n")
        r2 = subprocess.run([sys.executable, str(root / "scripts/lib/validation-receipt.py"), "capture",
                             "--root", str(root)], capture_output=True, text=True)
        case("the CLI exits 0 when eligible and 3 when not", r.returncode == 0 and r2.returncode == 3,
             f"{r.returncode}/{r2.returncode}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    failed = results.count(False)
    print(f"validation-receipt self-test: executed={len(results)} passed={len(results) - failed} failed={failed}")
    return 0 if results and failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
