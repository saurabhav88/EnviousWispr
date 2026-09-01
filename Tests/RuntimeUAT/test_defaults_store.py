#!/usr/bin/env python3
"""Control test for `defaults_store`, run against a THROWAWAY domain.

**Every row asserts the TYPE, not only the printed text.** A text-only assertion
passes against the exact defect this module was written for, because `defaults
read` prints a boolean `false` and a string `"0"` identically as `0`.

Two-way by construction: the string row and the boolean row would BOTH pass under
a correct implementation, and the string row is the one that fails under the old
fixed-flag restore.
"""

import subprocess
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import defaults_store as ds  # noqa: E402

DOMAIN = "com.enviouswispr.uat.defaults-store-control"
FAILURES = []


def ok(label, passed, detail=""):
    print(f"  {'PASS' if passed else 'FAIL'}  {label}" + (f"  :: {detail}" if detail else ""))
    if not passed:
        FAILURES.append(label)


def read_type(key):
    r = subprocess.run(["defaults", "read-type", DOMAIN, key], capture_output=True, text=True)
    return r.stdout.strip().rsplit(" ", 1)[-1] if r.returncode == 0 else None


def main():
    subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)
    try:
        print("a STRING preference survives a park-and-restore as a STRING")
        # Exactly what the previous phase5_geometry.py wrote, and the value whose
        # restore-as-boolean silently changes the app's effective setting.
        subprocess.run(["defaults", "write", DOMAIN, "k", "0"], check=True)
        ok("precondition: it really is a string", read_type("k") == "string", read_type("k"))
        snap = ds.snapshot(DOMAIN, ["k"])
        ok("the snapshot captured the type", snap["k"] == ("0", "-string"), str(snap["k"]))
        ds.write_typed(DOMAIN, "k", "true", "-bool")  # the harness drives its row
        ok("the row's own write landed as a boolean", read_type("k") == "boolean", read_type("k"))
        landed = ds.restore(DOMAIN, snap)
        ok("restore reports success", landed["k"] is True)
        ok("the TYPE came back", read_type("k") == "string", read_type("k"))
        ok("the TEXT came back", ds.read_typed(DOMAIN, "k") == ("0", "-string"))

        print("\na BOOLEAN preference survives as a BOOLEAN")
        subprocess.run(["defaults", "write", DOMAIN, "b", "-bool", "false"], check=True)
        snap = ds.snapshot(DOMAIN, ["b"])
        ds.write_typed(DOMAIN, "b", "true", "-bool")
        landed = ds.restore(DOMAIN, snap)
        ok("restore reports success", landed["b"] is True)
        ok("still a boolean", read_type("b") == "boolean", read_type("b"))
        ok("still false", ds.read_typed(DOMAIN, "b") == ("0", "-bool"))

        print("\nan ABSENT key is restored to ABSENT, not to a value")
        snap = ds.snapshot(DOMAIN, ["gone"])
        ok("snapshot says absent", snap["gone"] is None)
        ds.write_typed(DOMAIN, "gone", "true", "-bool")
        landed = ds.restore(DOMAIN, snap)
        ok("restore reports success", landed["gone"] is True)
        ok("the key is gone again", ds.read_typed(DOMAIN, "gone") is None)

        print("\nrestore REPORTS a failure it cannot fix, rather than claiming success")
        # The check must be able to fail, or it is not a check. Drive it by
        # snapshotting a value and then making the restore target unwritable is
        # not available here, so assert the weaker but real property: a restore
        # of a value the module cannot express REFUSES at snapshot time.
        subprocess.run(["defaults", "write", DOMAIN, "arr", "-array", "a", "b"], check=True)
        refused = False
        try:
            ds.snapshot(DOMAIN, ["arr"])
        except ds.UnsupportedType:
            refused = True
        ok("an array REFUSES rather than being guessed", refused)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)

    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} row(s): {', '.join(FAILURES)}")
        sys.exit(1)
    print("all rows passed")


if __name__ == "__main__":
    main()
