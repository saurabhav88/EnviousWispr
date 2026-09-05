"""Snapshot and restore a developer's real preferences, TYPE INCLUDED.

**Why this exists as one module rather than three copies.** Every phase5 harness
parks the founder's own settings, drives its rows, and puts them back. Three of
them restored with a FIXED type flag chosen by the harness instead of the type
the value actually had, and the failure is silent in both directions: `defaults
read` prints only the TEXT, so a restore that changed `"0"` (string) into `false`
(boolean) still compares equal and reports a clean restore.

**That is not cosmetic, because the app reads the two differently.**
`SettingsManager` resolves these keys with `object(forKey:) as? Bool`. A boolean
`false` is accepted and applied. A STRING `"0"` yields nil and the shipped
default applies instead. So restoring a string as a boolean silently flips the
developer's effective setting, on their own machine, with every check green.

Found by cloud review on PR #2578 against `phase5_geometry.py`. The same shape was
in `phase5_geometry_relaunch.py` and `phase5_warning_morph.py`, which is why the
rule lives here and the harnesses call it.

**The rule is not new here: `escape_recovery_uat.py` already captured `(value,
flag)` and compared the whole tuple**, with a comment naming this exact failure
after it bit the founder's own `escapeRecoveryEnabled` on 2026-08-19. That
harness is the prior art and this module is its generalisation, so the three that
lacked it were the outliers rather than the norm.

**Two paths, chosen by what the value IS, and the typed path is unchanged.**

The typed path above (`snapshot` / `restore`) covers the four scalar types that
have a single-token `defaults write` form. It REFUSES anything else
(`UnsupportedType`) rather than guessing, because a value that has no such form
cannot be put back through `defaults write` at all -- and that is exactly what
`phase5_language_hover.py` used to do (#2579). It parked
`languageChipSuppressedLanguages` and `languageChipDismissalCounts` from
`defaults read`'s printed text and handed that text back to `defaults write` as
one positional argument, which stores a STRING (or an old-style-plist dictionary)
where the original value was. The restore check compared the same printed text
on both sides, so it could not see the difference.

Those two keys are JSON-encoded `Data` on disk (`LanguageSuggestionPresenter
.persistState` writes `JSONEncoder` output with `defaults.set(data, forKey:)`),
so `defaults read` prints `{length = N, bytes = 0x...}` and `read-type` says
`data`; logically they hold a list and a dictionary. Either way the value never
survives a trip through printed text.

The plist path (`snapshot_plist` / `restore_plist`) never goes through text.
It reads the whole domain with `defaults export <domain> -` (XML plist on
stdout), parses it with `plistlib`, and keeps the Python VALUE -- `bytes`,
`list`, `dict`, nested or not. Restore writes a plist holding ONLY the parked
keys and hands it to `defaults import <domain> <file>`, then re-exports and
compares the parsed values with `==`. So the check is structural: a string
`"(\n a\n)"` is not equal to the list `["a"]`, and a mangled restore reads as
dirty instead of clean.

**Assumption, stated because the man page does not:** `defaults import` MERGES
the plist's keys into the domain and leaves every other key alone. That is the
documented shape of `CFPreferencesSetMultiple`, which is what `import` wraps, and
the control test asserts it directly with a bystander key rather than trusting
this paragraph. Importing only the parked keys, rather than the whole exported
domain, is deliberate: a live instance may write unrelated keys between the
snapshot and the restore, and this module must not revert them.

Control test: `test_defaults_store.py`, which round-trips every type on a
throwaway domain and asserts the type SURVIVES, not merely the printed text.
"""

import os
import plistlib
import subprocess
import tempfile

# `defaults read-type` wording -> the flag `defaults write` needs for it.
_TYPE_FLAG = {
    "boolean": "-bool",
    "integer": "-int",
    "float": "-float",
    "string": "-string",
}


class UnsupportedType(Exception):
    """A stored value this module cannot faithfully put back.

    Raised rather than guessed. A dictionary, array, date or data value has no
    single-token `defaults write` form, and writing SOMETHING would be worse than
    refusing: the caller would park a real preference and restore a different one
    while every check passed.
    """


def read_typed(domain, key):
    """`(text, flag)` for a stored value, or `None` when the key is absent.

    Both halves come from the store rather than from the caller's expectation,
    which is the whole point: a harness must not decide what type a developer's
    preference is.
    """
    got = subprocess.run(
        ["defaults", "read", domain, key], capture_output=True, text=True)
    if got.returncode != 0:
        return None
    kind = subprocess.run(
        ["defaults", "read-type", domain, key], capture_output=True, text=True)
    if kind.returncode != 0:
        return None
    # "Type is boolean" -> "boolean"
    word = kind.stdout.strip().rsplit(" ", 1)[-1]
    flag = _TYPE_FLAG.get(word)
    if flag is None:
        raise UnsupportedType(f"{domain}.{key} is {word!r}, which cannot be restored by this module")
    return got.stdout.strip(), flag


def write_typed(domain, key, text, flag):
    """Write one value in the spelling `defaults` accepts for that flag.

    `defaults write <dom> <key> -bool 1` EXITS 255: the tool takes only
    true/false/yes/no for `-bool`, while `defaults read` PRINTS a boolean as
    `1`/`0`. So the read shape and the write shape differ for exactly the type
    this module exists to preserve, and normalising here covers every caller.
    """
    if flag == "-bool":
        text = "true" if str(text).strip().lower() in ("1", "true", "yes", "y", "on") else "false"
    subprocess.run(["defaults", "write", domain, key, flag, str(text)], check=True)


def snapshot(domain, keys):
    """What the machine holds now: `{key: (text, flag) or None}`."""
    return {k: read_typed(domain, k) for k in keys}


def restore(domain, snap):
    """Put every key back exactly as it was, and SAY whether each one landed.

    Returns `{key: bool}`. Verified against BOTH text and type — a text-only
    comparison is blind to the defect this module was written for, and a restore
    check that cannot fail is not a check.
    """
    landed = {}
    for key, want in snap.items():
        if want is None:
            subprocess.run(["defaults", "delete", domain, key], capture_output=True)
            landed[key] = read_typed(domain, key) is None
            continue
        text, flag = want
        write_typed(domain, key, text, flag)
        landed[key] = read_typed(domain, key) == want
    return landed


def snapshot_multi(domain_of, keys):
    """Like `snapshot`, for keys that live in DIFFERENT domains.

    `phase5_warning_morph` pins debug flags in the dev domain and real user
    preferences in the shared suite, so the domain is a property of the KEY. It
    is passed as a map rather than inferred, because guessing which domain a key
    is read from is the mistake that made a whole run write where nothing reads.
    """
    return {k: read_typed(domain_of[k], k) for k in keys}


def restore_multi(domain_of, snap):
    """Like `restore`, for keys that live in DIFFERENT domains."""
    landed = {}
    for key, want in snap.items():
        domain = domain_of[key]
        if want is None:
            subprocess.run(["defaults", "delete", domain, key], capture_output=True)
            landed[key] = read_typed(domain, key) is None
            continue
        text, flag = want
        write_typed(domain, key, text, flag)
        landed[key] = read_typed(domain, key) == want
    return landed


# ---------------------------------------------------------------------------
# The plist path: values that have no `defaults write` form (#2579).
# ---------------------------------------------------------------------------

def export_domain(domain):
    """Every key in the domain as parsed plist values, `{}` when it has none.

    `defaults export <domain> -` writes an XML plist to stdout. A domain that
    does not exist yet is reported the same way `read_typed` reports an absent
    key: as nothing there, so a first run on a fresh install parks `None` and
    restores by deleting.
    """
    got = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    if got.returncode != 0 or not got.stdout.strip():
        return {}
    return plistlib.loads(got.stdout)


def read_plist(domain, key):
    """The stored value of one key as a Python object, or `None` when absent.

    A `data` value comes back as `bytes`, an array as `list`, a dictionary as
    `dict`, nested as stored. Nothing here is text, so nothing here can be
    compared as text.
    """
    return export_domain(domain).get(key)


def snapshot_plist(domain, keys):
    """What the machine holds now: `{key: value or None}`, structurally."""
    values = export_domain(domain)
    return {k: values.get(k) for k in keys}


def check_plist(domain, snap):
    """`{key: bool}`: does each key hold EXACTLY the snapshotted value now?

    Parsed-value equality, so an array restored as the string `defaults read`
    printed for it is reported as NOT landed. Exposed on its own so a harness,
    or the control test, can ask the question without performing a restore.
    """
    values = export_domain(domain)
    return {k: values.get(k) == want for k, want in snap.items()}


def restore_plist(domain, snap):
    """Put every key back exactly as it was, and SAY whether each one landed.

    Absent keys are DELETED, not written as an empty container -- an empty
    `Data` is a decodable JSON failure to the presenter, not the fresh-install
    state it had. Present keys go back through ONE `defaults import` of a plist
    holding only those keys (merge semantics; see the module docstring).
    """
    present = {k: v for k, v in snap.items() if v is not None}
    for key in snap:
        if key not in present:
            subprocess.run(["defaults", "delete", domain, key], capture_output=True)
    if present:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "restore.plist")
            with open(path, "wb") as fh:
                plistlib.dump(present, fh)
            subprocess.run(["defaults", "import", domain, path], check=True)
    return check_plist(domain, snap)
