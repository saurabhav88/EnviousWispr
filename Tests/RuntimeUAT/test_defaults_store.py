#!/usr/bin/env python3
"""Control test for `defaults_store`, run against a THROWAWAY domain.

**Every row asserts the TYPE, not only the printed text.** A text-only assertion
passes against the exact defect this module was written for, because `defaults
read` prints a boolean `false` and a string `"0"` identically as `0`.

Two-way by construction: the string row and the boolean row would BOTH pass under
a correct implementation, and the string row is the one that fails under the old
fixed-flag restore.

The plist-path rows (#2579) assert STRUCTURE: a `data`, an array and a dictionary
must come back as the same parsed value, an absent key must come back absent, a
bystander key written AFTER the snapshot must survive the `defaults import`
whether it merges or replaces the domain, and the restore of a value from
its PRINTED text -- what `phase5_language_hover.py` used to do -- must be reported
as NOT clean rather than compared equal.

Run: `python3 Tests/RuntimeUAT/test_defaults_store.py` on a Mac. It needs the real
`defaults` binary; there is no fake.
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

        print("\nthe plist path round-trips DATA, an ARRAY and a DICTIONARY structurally (#2579)")
        # The real shape of the two language-chip keys: JSON bytes stored as
        # `data`. This is `["es"]` as hex, which is what `-data` takes.
        subprocess.run(["defaults", "write", DOMAIN, "d", "-data", "5b226573225d"], check=True)
        subprocess.run(["defaults", "write", DOMAIN, "arr", "-array", "a", "b"], check=True)
        subprocess.run(["defaults", "write", DOMAIN, "dct", "-dict", "k1", "v1", "k2", "v2"], check=True)
        want = {"d": b'["es"]', "arr": ["a", "b"], "dct": {"k1": "v1", "k2": "v2"}}
        snap = ds.snapshot_plist(DOMAIN, ["d", "arr", "dct"])
        ok("the snapshot holds parsed VALUES, not printed text", snap == want, repr(snap))
        # A bystander the restore must NOT touch, written AFTER the snapshot the
        # way a live instance writes between park and restore. It must survive
        # whether `defaults import` merges or replaces the domain: the restore
        # overlays the parked keys on a fresh export, and this is the row that
        # would catch a return to importing only the parked keys (#2674 review).
        subprocess.run(["defaults", "write", DOMAIN, "keep", "-int", "7"], check=True)
        for k in ("d", "arr", "dct"):  # the harness clears its rows, as language_hover does
            subprocess.run(["defaults", "delete", DOMAIN, k], capture_output=True)
        ok("precondition: the rows really are gone",
           ds.snapshot_plist(DOMAIN, ["d", "arr", "dct"]) == {"d": None, "arr": None, "dct": None})
        landed = ds.restore_plist(DOMAIN, snap)
        ok("restore reports success for every key", all(landed.values()), repr(landed))
        ok("the DATA came back as data", read_type("d") == "data", read_type("d"))
        ok("the ARRAY came back as an array", read_type("arr") == "array", read_type("arr"))
        ok("the DICTIONARY came back as a dictionary", read_type("dct") == "dictionary", read_type("dct"))
        ok("the values are structurally identical", ds.snapshot_plist(DOMAIN, ["d", "arr", "dct"]) == want)
        ok("a bystander written after the snapshot survived the import",
           ds.read_plist(DOMAIN, "keep") == 7, repr(ds.read_plist(DOMAIN, "keep")))
        ok("the bystander is still an integer", read_type("keep") == "integer", read_type("keep"))

        print("\na restore from PRINTED text is reported as NOT clean")
        # Exactly what phase5_language_hover.py did before #2579: `defaults read`,
        # then the printed blob back through `defaults write` as one argument.
        for k in ("arr", "d"):
            blob = subprocess.run(["defaults", "read", DOMAIN, k],
                                  capture_output=True, text=True).stdout.strip()
            subprocess.run(["defaults", "write", DOMAIN, k, blob], check=True)
        checked = ds.check_plist(DOMAIN, snap)
        ok("the mangled array is caught", checked["arr"] is False, repr(ds.read_plist(DOMAIN, "arr")))
        ok("the mangled data is caught", checked["d"] is False, repr(ds.read_plist(DOMAIN, "d")))
        ok("the untouched dictionary still reads clean", checked["dct"] is True)
        landed = ds.restore_plist(DOMAIN, snap)
        ok("a real restore repairs the mangling", all(landed.values()), repr(landed))

        print("\na domain that does not exist exports as EMPTY, and is not mistaken for a failure")
        # `defaults export` on a missing domain exits 0 with an empty <dict/>. That is the
        # only way `{}` may come back: a non-zero exit RAISES, because returning `{}` there
        # would park None for keys that are really present and then delete them on restore.
        subprocess.run(["defaults", "delete", DOMAIN + ".never"], capture_output=True)
        ok("a missing domain reads as no keys", ds.export_domain(DOMAIN + ".never") == {})
        ok("a missing domain snapshots as absent",
           ds.snapshot_plist(DOMAIN + ".never", ["x"]) == {"x": None})

        print("\nan ABSENT key on the plist path is restored to ABSENT, not to an empty container")
        snap = ds.snapshot_plist(DOMAIN, ["never"])
        ok("snapshot says absent", snap["never"] is None)
        subprocess.run(["defaults", "write", DOMAIN, "never", "-array", "x"], check=True)
        landed = ds.restore_plist(DOMAIN, snap)
        ok("restore reports success", landed["never"] is True)
        ok("the key is gone again", ds.read_plist(DOMAIN, "never") is None)
        ok("the bystander is still there", ds.read_plist(DOMAIN, "keep") == 7)
    finally:
        subprocess.run(["defaults", "delete", DOMAIN], capture_output=True)

    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)} row(s): {', '.join(FAILURES)}")
        sys.exit(1)
    print("all rows passed")


if __name__ == "__main__":
    main()
