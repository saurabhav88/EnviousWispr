"""Resolve the app's push-to-talk binding, or refuse — never guess (#1997).

Why this module exists
----------------------
On 2026-08-10 a UAT run reported that the product ignored the hotkey. It had
not. `wispr_eyes._resolve_ptt_key` read `toggleKeyCode` from the retired
`com.enviouswispr.app.dev` domain while the app reads the shared
`com.enviouswispr.app` (`SettingsDefaults.store` redirects the dev build), and
its private 4-entry keycode->name map could not name Globe (63) even from the
right domain, so it fell through to a hardcoded `rcmd`. The harness held a key
nothing was listening for and returned an ordinary boolean FAIL — on a branch
that had just changed hotkey delivery, which is the single context in which a
hotkey FAIL is most likely to be believed.

The defect class is not "wrong domain". It is **an instrument failure reported
as a product verdict**. If the binding cannot be established, raise
`PTTBindingError`; never return a guessed key, and never let a caller convert
that into a PASS/FAIL about the product.

Design notes that are load-bearing
----------------------------------
* ONE `defaults export` OF THE WHOLE DOMAIN, not a read per key. `defaults read
  <domain> <key>` reports a missing key and an operational failure with the same
  exit status and the same English sentence, so absence could only be guessed at
  from locale-sensitive text. `export` sidesteps that entirely: it succeeds even
  for a domain that does not exist (emitting an empty plist), so **key presence
  is a dict membership test** and any nonzero exit is unambiguously an instrument
  failure. It is also one subprocess instead of three — measured 8 ms rather than
  24 ms mean, which matters because `faultInjection` taps inside a 100 ms fuzz
  window and a 500 ms double-tap window.
* AN ABSENT KEY IS NOT A GUESS. `SettingsManager` resolves an unset preference
  through `SettingsDefaultValues` and deliberately does NOT persist it
  (`SettingsManager.swift:691`, `:639`; #923 forbids an onboarding write, which
  would make default users look customized). On a fresh or reset profile the app
  really is running Right Option in push-to-talk with nothing on disk, so
  refusing there would reject a valid configuration. Absent resolves through the
  same canonical source the app reads; a PRESENT-but-malformed value still
  refuses, because that tells us nothing about what the app is using.

  This is not the deleted `rcmd` fallback under a new name. That pressed 54,
  matching neither the configured key nor any default — something nothing was
  listening for. The test is "does the harness press what the app listens for",
  and `--self-test` asserts these constants against `SettingsDefaultValues.swift`
  so they cannot decay into remembered values.
* NOTHING MAY ESCAPE AS A NON-`PTTBindingError`. A caller's generic handler would
  record it as a failed product scenario, which is this defect arriving by a side
  door. Both known escapes — a non-`FileNotFoundError` `OSError` from the
  subprocess launch, and an `ImportError` from the lazy `simulate_input` import
  on a box without PyObjC — are classified, and a self-test case fails if either
  escapes again.
* DRIVABILITY BELONGS TO THE CONSUMER. `wispr_eyes` can hold ordinary keys and
  modifiers; `faultInjection` posts only modifier events. This module owns
  CONFIGURATION.
* No top-level `simulate_input` import: it imports Quartz at module scope, so
  importing it would make this module and its self-test unimportable in CI.
"""
import argparse
import ast
import plistlib
import re
import subprocess
import sys
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

# The one domain both builds read. The dev build redirects here via
# SettingsDefaults.store (Sources/EnviousWisprServices/SettingsDefaults.swift),
# so `com.enviouswispr.app.dev` holds only pre-#923 residue. Do not add a
# fallback to it: reading a stale domain is what caused #1997.
SHARED_DOMAIN = "com.enviouswispr.app"

PUSH_TO_TALK = "pushToTalk"

TOGGLE_KEY_CODE = "toggleKeyCode"
TOGGLE_MODIFIERS_RAW = "toggleModifiersRaw"
RECORDING_MODE = "recordingMode"

# Canonical shipped defaults, applied by SettingsManager when a key is absent.
# Mirrors Sources/EnviousWisprServices/SettingsDefaultValues.swift, the machine
# authority (.claude/knowledge/settings-defaults.md is the human one).
# `--self-test` asserts these against that Swift file, so changing a shipped
# default breaks CI here rather than silently turning this into a guess.
DEFAULT_TOGGLE_KEY_CODE = 61  # ModifierKeyCodes.rightOption
DEFAULT_TOGGLE_MODIFIERS_RAW = 0
DEFAULT_RECORDING_MODE = PUSH_TO_TALK


class PTTBindingError(RuntimeError):
    """The harness cannot establish a drivable binding.

    Raised, never returned as a false-like sentinel: a caller writing
    `if not result:` would silently recreate the defect this module exists to
    fix. CLI boundaries convert it to `INSTRUMENT INVALID` + exit 2 via
    `run_instrument_boundary`; ad-hoc callers let it propagate.
    """


class PreferenceFailure(str, Enum):
    COMMAND_UNAVAILABLE = "defaults command unavailable"
    COMMAND_FAILED = "defaults could not be launched or exited nonzero"
    TIMEOUT = "defaults export timed out"
    MALFORMED_DOMAIN = "domain export could not be parsed"
    MALFORMED_VALUE = "preference value malformed"
    INPUT_MAPS_UNAVAILABLE = "simulate_input key maps unavailable"


class PreferenceReadError(PTTBindingError):
    def __init__(self, key: str, failure: PreferenceFailure, detail: str = ""):
        self.key = key
        self.failure = failure
        self.detail = detail
        suffix = f": {detail}" if detail else ""
        super().__init__(f"{key}: {failure.value}{suffix}")


@dataclass(frozen=True)
class PTTBinding:
    """A fully resolved, drivable binding. Never partially populated."""

    keycode: int
    key_name: str
    modifiers_raw: int
    recording_mode: str
    is_modifier_only: bool


def read_domain(*, timeout: float = 5.0) -> dict:
    """Export the whole shared domain once, or raise a CLASSIFIED failure.

    Returns `{}` for a domain that does not exist — that is a real answer, not a
    failure: it means every key is unset and the app is on its canonical
    defaults. Any NONZERO exit is therefore unambiguously operational.
    """
    try:
        result = subprocess.run(
            ["defaults", "export", SHARED_DOMAIN, "-"],
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as error:
        raise PreferenceReadError(
            SHARED_DOMAIN, PreferenceFailure.COMMAND_UNAVAILABLE
        ) from error
    except subprocess.TimeoutExpired as error:
        raise PreferenceReadError(SHARED_DOMAIN, PreferenceFailure.TIMEOUT) from error
    except OSError as error:
        # PermissionError, ENOMEM, EMFILE... Letting a raw OSError escape would
        # let a caller's generic handler score it as a failed product scenario.
        raise PreferenceReadError(
            SHARED_DOMAIN,
            PreferenceFailure.COMMAND_FAILED,
            f"{type(error).__name__}: {error}",
        ) from error

    if result.returncode != 0:
        raise PreferenceReadError(
            SHARED_DOMAIN,
            PreferenceFailure.COMMAND_FAILED,
            f"exit {result.returncode}: {result.stderr.decode(errors='replace').strip()}",
        )

    try:
        parsed = plistlib.loads(result.stdout)
    except Exception as error:  # plistlib raises several shapes
        raise PreferenceReadError(
            SHARED_DOMAIN,
            PreferenceFailure.MALFORMED_DOMAIN,
            f"{type(error).__name__}: {error}",
        ) from error

    if not isinstance(parsed, dict):
        raise PreferenceReadError(
            SHARED_DOMAIN,
            PreferenceFailure.MALFORMED_DOMAIN,
            f"expected a dict, got {type(parsed).__name__}",
        )
    return parsed


def _int_or_default(domain: dict, key: str, default: int) -> int:
    """Absent -> the canonical shipped default; PRESENT but not Int-typed -> refuse.

    Absence is the one condition with a knowable answer, because an unset
    preference is exactly what makes the app apply `SettingsDefaultValues`.

    The type rule mirrors `SettingsManager`'s `as? Int`, MEASURED rather than
    assumed (`swiftc` probe, 2026-08-10):

        Int 63       -> 63        String "63"  -> nil
        Double 63.0  -> 63        Double 63.7  -> nil
        Bool true    -> 1

    So a Python `int` (plist integer, and `bool`, which Swift bridges to 1) and an
    exactly-integral `float` are what the app accepts. **A numeric STRING is the
    dangerous case**: `int("63")` would make the harness press Globe while the app,
    seeing `nil`, is listening on Right Option — this issue's exact defect, from a
    preference written with the wrong plist type.

    Anything Swift would reject REFUSES here rather than mirroring the app's
    fallback. Both directions are defensible, and the asymmetry decides it:
    accepting wrongly presses a key nobody is listening for and is silent, while
    refusing wrongly costs one loud message a human fixes in a single command.
    """
    if key not in domain:
        return default
    value = domain[key]
    if isinstance(value, bool) or isinstance(value, int):
        return int(value)
    if isinstance(value, float) and value.is_integer():
        return int(value)
    raise PreferenceReadError(
        key,
        PreferenceFailure.MALFORMED_VALUE,
        f"{type(value).__name__} {value!r} is not an Int the app would accept "
        f"(`as? Int` yields nil, so the app uses its default)",
    )


def _load_input_key_maps() -> tuple[dict[str, int], dict[str, int]]:
    # Production-only lazy import: simulate_input imports Quartz at module scope
    # (simulate_input.py:25), which CI does not have. Tests inject both maps.
    from simulate_input import KEY_CODES, MODIFIER_KEYS

    return dict(KEY_CODES), dict(MODIFIER_KEYS)


def _input_key_maps() -> tuple[dict[str, int], dict[str, int]]:
    try:
        return _load_input_key_maps()
    except ImportError as error:
        raise PreferenceReadError(
            "simulate_input", PreferenceFailure.INPUT_MAPS_UNAVAILABLE, str(error)
        ) from error


def require_push_to_talk(domain_reader: Callable[[], dict] = read_domain) -> str:
    """Refuse unless the app is in push-to-talk mode.

    A precondition of the HOLD GESTURE, not of the key, so it applies even when
    the caller supplied an explicit `key=`. In toggle mode key-down toggles once
    and key-up is ignored (`HotkeyService.swift:756` Carbon, `:823` modifier
    dispatch), so a hold cannot finish the recording it starts — it leaves
    recording ACTIVE. #963 (2026-06-21) is that failure capturing founder speech.
    """
    return _require_push_to_talk_in(domain_reader())


def _require_push_to_talk_in(domain: dict) -> str:
    mode = domain.get(RECORDING_MODE, DEFAULT_RECORDING_MODE)
    if mode != PUSH_TO_TALK:
        raise PTTBindingError(
            f"recordingMode is {mode!r}, not {PUSH_TO_TALK!r}: a key hold cannot "
            "start and then stop a recording in this mode"
        )
    return mode


def resolve(
    domain_reader: Callable[[], dict] = read_domain,
    *,
    key_codes_by_name: dict[str, int] | None = None,
    modifier_keys_by_name: dict[str, int] | None = None,
) -> PTTBinding:
    """Resolve the configured binding, or raise. Never returns a guess."""
    if key_codes_by_name is None or modifier_keys_by_name is None:
        prod_keys, prod_mods = _input_key_maps()
        key_codes_by_name = prod_keys if key_codes_by_name is None else key_codes_by_name
        modifier_keys_by_name = (
            prod_mods if modifier_keys_by_name is None else modifier_keys_by_name
        )

    domain = domain_reader()
    mode = _require_push_to_talk_in(domain)
    keycode = _int_or_default(domain, TOGGLE_KEY_CODE, DEFAULT_TOGGLE_KEY_CODE)
    modifiers_raw = _int_or_default(
        domain, TOGGLE_MODIFIERS_RAW, DEFAULT_TOGGLE_MODIFIERS_RAW
    )

    is_modifier_only = keycode in set(modifier_keys_by_name.values())

    # A nonzero modifier value only matters for an ORDINARY key. For a standalone
    # modifier the app never consults toggleModifiers: installModifierMonitors()
    # returns early unless isModifierOnly (HotkeyService.swift:629) and
    # registerToggleHotkey() returns early when it is (:704).
    if not is_modifier_only and modifiers_raw != 0:
        raise PTTBindingError(
            f"unsupported chord: keycode={keycode}, "
            f"{TOGGLE_MODIFIERS_RAW}={modifiers_raw}"
        )

    key_name = _name_for_keycode(keycode, key_codes_by_name, modifier_keys_by_name)
    if key_name is None:
        raise PTTBindingError(
            f"no synthesizable key for keycode={keycode}: absent from both "
            "simulate_input.MODIFIER_KEYS and KEY_CODES"
        )

    return PTTBinding(
        keycode=keycode,
        key_name=key_name,
        modifiers_raw=modifiers_raw,
        recording_mode=mode,
        is_modifier_only=is_modifier_only,
    )


def _name_for_keycode(
    keycode: int,
    key_codes_by_name: dict[str, int],
    modifier_keys_by_name: dict[str, int],
) -> str | None:
    """Modifiers first: a keycode in both maps must resolve to the modifier
    spelling, because the app registers it through the modifier monitor and only
    `modifier_down`/`modifier_up` reach that path."""
    for name, code in modifier_keys_by_name.items():
        if code == keycode:
            return name
    for name, code in key_codes_by_name.items():
        if code == keycode:
            return name
    return None


def run_instrument_boundary(action: Callable[[], int]) -> int:
    """Wrap a CLI entry point so an invalid instrument never looks like a verdict.

    One shared adapter rather than four hand-written formatters, so the output is
    lexically identical everywhere and the acceptance criterion is mechanical.
    """
    try:
        return action()
    except PTTBindingError as error:
        print(f"INSTRUMENT INVALID: {error}", file=sys.stderr)
        return 2


# --- Swift <-> Python parity ------------------------------------------------
# Static extraction: neither module is imported, so this runs on a CI box with
# no Quartz and no Swift toolchain.


def python_dict_literal(path: Path, name: str) -> dict[str, int]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            value = ast.literal_eval(node.value)
            if not isinstance(value, dict):
                break
            return {str(k): int(v) for k, v in value.items()}
    raise AssertionError(f"{name} literal not found in {path}")


def swift_modifier_constants(path: Path) -> dict[str, int]:
    return {
        name: int(value)
        for name, value in re.findall(
            r"(?:public|package|private|internal)?\s*static let (\w+): UInt16 = (\d+)",
            path.read_text(encoding="utf-8"),
        )
    }


def swift_modifier_keycodes(path: Path) -> set[int]:
    source = path.read_text(encoding="utf-8")
    constants = swift_modifier_constants(path)
    match = re.search(
        r"private static let flagsByKeyCode:"
        r"\s*\[UInt16:\s*NSEvent\.ModifierFlags\]\s*=\s*\[(.*?)\n\s*\]",
        source,
        re.DOTALL,
    )
    if match is None:
        # Raise rather than return an empty set: a silently empty extraction
        # would make the parity assertion vacuously true, worse than no check.
        raise AssertionError("ModifierKeyCodes.flagsByKeyCode not found")
    names = re.findall(r"\b([A-Za-z_]\w*)\s*:\s*\.", match.group(1))
    try:
        return {constants[name] for name in names}
    except KeyError as error:
        raise AssertionError(f"unresolved Swift modifier constant: {error}") from error


def swift_default_values(path: Path) -> dict[str, str]:
    """Extract `SettingsDefaultValues`' literals VERBATIM, unresolved, so the
    caller decides how to interpret each one; a parser that silently resolved
    them could paper over a genuine change."""
    source = path.read_text(encoding="utf-8")
    values = dict(
        re.findall(r"static let (\w+)(?::\s*[\w\.<>\[\] ]+)? = ([^\n]+)", source)
    )
    if not values:
        raise AssertionError(f"no `static let` declarations found in {path}")
    return {k: v.split("//")[0].strip() for k, v in values.items()}


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def assert_modifier_table_parity() -> None:
    root = _repo_root()
    python_codes = set(
        python_dict_literal(
            root / "Tests/RuntimeUAT/simulate_input.py", "MODIFIER_KEYS"
        ).values()
    )
    swift_codes = swift_modifier_keycodes(
        root / "Sources/EnviousWisprServices/KeySymbols.swift"
    )
    if python_codes != swift_codes:
        raise AssertionError(
            "modifier table drift: "
            f"Python-only={sorted(python_codes - swift_codes)}, "
            f"Swift-only={sorted(swift_codes - python_codes)}"
        )


def assert_canonical_defaults_match_swift() -> None:
    """Our default constants ARE the app's shipped defaults, not remembered ones.

    Without this the absent-key path degrades into exactly the guess #1997 was
    about, the moment a shipped default changes.
    """
    root = _repo_root()
    swift = swift_default_values(
        root / "Sources/EnviousWisprServices/SettingsDefaultValues.swift"
    )
    modifier_codes = swift_modifier_constants(
        root / "Sources/EnviousWisprServices/KeySymbols.swift"
    )

    raw_keycode = swift.get("toggleKeyCode", "")
    match = re.fullmatch(r"Int\(ModifierKeyCodes\.(\w+)\)", raw_keycode)
    if match is None:
        raise AssertionError(
            f"toggleKeyCode default is no longer Int(ModifierKeyCodes.x): {raw_keycode!r}"
        )
    expected = modifier_codes.get(match.group(1))
    if expected != DEFAULT_TOGGLE_KEY_CODE:
        raise AssertionError(
            f"DEFAULT_TOGGLE_KEY_CODE={DEFAULT_TOGGLE_KEY_CODE} but Swift ships "
            f"{match.group(1)}={expected}"
        )
    if swift.get("toggleModifiersRaw") != str(DEFAULT_TOGGLE_MODIFIERS_RAW):
        raise AssertionError(
            f"DEFAULT_TOGGLE_MODIFIERS_RAW={DEFAULT_TOGGLE_MODIFIERS_RAW} but Swift "
            f"ships {swift.get('toggleModifiersRaw')!r}"
        )
    if swift.get("recordingMode") != f".{DEFAULT_RECORDING_MODE}":
        raise AssertionError(
            f"DEFAULT_RECORDING_MODE={DEFAULT_RECORDING_MODE!r} but Swift ships "
            f"{swift.get('recordingMode')!r}"
        )


# --- Self-test --------------------------------------------------------------

TEST_KEY_CODES = {"space": 49, "return": 36, "a": 0}
TEST_MODIFIER_KEYS = {
    "rcmd": 54, "lcmd": 55, "lopt": 58, "ropt": 61, "lshift": 56,
    "rshift": 60, "lctrl": 59, "rctrl": 62, "fn": 63,
}


def _domain(**overrides):
    values = {RECORDING_MODE: PUSH_TO_TALK, TOGGLE_KEY_CODE: 63, TOGGLE_MODIFIERS_RAW: 0}
    values.update(overrides)
    return values


def _resolve(domain) -> PTTBinding:
    return resolve(
        lambda: domain,
        key_codes_by_name=TEST_KEY_CODES,
        modifier_keys_by_name=TEST_MODIFIER_KEYS,
    )


def _expect_refusal(domain, *, contains: str = "") -> PTTBindingError:
    try:
        binding = _resolve(domain)
    except PTTBindingError as error:
        if contains and contains not in str(error):
            raise AssertionError(f"expected {contains!r} in refusal, got {error!r}")
        return error
    raise AssertionError(f"expected a refusal, got {binding!r}")


def _case_globe_resolves() -> None:
    binding = _resolve(_domain())
    assert binding.key_name == "fn" and binding.keycode == 63, binding
    assert binding.is_modifier_only, binding


def _case_every_modifier_resolves() -> None:
    for name, code in TEST_MODIFIER_KEYS.items():
        binding = _resolve(_domain(**{TOGGLE_KEY_CODE: code}))
        assert binding.key_name == name, (name, code, binding)


def _case_ordinary_key_resolves() -> None:
    binding = _resolve(_domain(**{TOGGLE_KEY_CODE: 49}))
    assert binding.key_name == "space" and binding.is_modifier_only is False, binding


def _case_ordinary_key_with_modifiers_is_a_chord() -> None:
    _expect_refusal(
        _domain(**{TOGGLE_KEY_CODE: 49, TOGGLE_MODIFIERS_RAW: 1048576}),
        contains="unsupported chord",
    )


def _case_modifier_with_stray_modifiers_still_resolves() -> None:
    # Two-way control: proves the chord rule is not over-broad. The app ignores
    # toggleModifiers on the modifier-monitor path.
    binding = _resolve(_domain(**{TOGGLE_MODIFIERS_RAW: 1048576}))
    assert binding.key_name == "fn", binding


def _case_unknown_keycode_refuses() -> None:
    _expect_refusal(_domain(**{TOGGLE_KEY_CODE: 999}), contains="999")


def _case_fresh_install_resolves_to_canonical_defaults() -> None:
    # Nothing persisted: SettingsManager applies SettingsDefaultValues without
    # writing, so the app IS running Right Option in push-to-talk. `defaults
    # export` returns {} for a domain that does not exist, so this is the real
    # shape of that state, not a stand-in.
    binding = _resolve({})
    assert binding.keycode == DEFAULT_TOGGLE_KEY_CODE, binding
    assert binding.key_name == "ropt", binding
    assert binding.modifiers_raw == DEFAULT_TOGGLE_MODIFIERS_RAW, binding
    assert binding.recording_mode == DEFAULT_RECORDING_MODE, binding


def _case_absent_key_does_not_mask_a_configured_one() -> None:
    # Two-way control: defaulting applies ONLY when the key is genuinely absent.
    assert _resolve(_domain()).keycode == 63


def _case_present_but_malformed_refuses() -> None:
    # The distinction the whole absent-vs-failed design rests on: a value that is
    # PRESENT and unusable says nothing about what the app is running.
    _expect_refusal(_domain(**{TOGGLE_KEY_CODE: "not-a-number"}), contains="malformed")
    _expect_refusal(_domain(**{TOGGLE_MODIFIERS_RAW: []}), contains="malformed")


def _case_type_rule_matches_swift_as_int() -> None:
    """Each row measured against a real `swiftc` probe, not assumed.

    The numeric-STRING row is the one that matters: coercing it would make the
    harness press Globe while the app, getting `nil` from `as? Int`, listens on
    Right Option — this issue's defect reached through a mistyped preference.
    """
    # Swift ACCEPTS these, so we must resolve rather than refuse.
    assert _resolve(_domain(**{TOGGLE_KEY_CODE: 63})).keycode == 63
    assert _resolve(_domain(**{TOGGLE_KEY_CODE: 63.0})).keycode == 63

    # Swift REJECTS these (`as? Int` -> nil), so pressing a coerced value would
    # target a key the app is not listening for.
    _expect_refusal(_domain(**{TOGGLE_KEY_CODE: "63"}), contains="not an Int")
    _expect_refusal(_domain(**{TOGGLE_KEY_CODE: 63.7}), contains="not an Int")
    _expect_refusal(_domain(**{TOGGLE_MODIFIERS_RAW: "0"}), contains="not an Int")


def _case_toggle_mode_refuses() -> None:
    _expect_refusal(_domain(**{RECORDING_MODE: "toggle"}), contains="pushToTalk")


def _case_mode_is_checked_before_the_key() -> None:
    # Ordering is load-bearing: an explicit-key caller depends on the mode check
    # even when the configured key is unusable.
    _expect_refusal(
        _domain(**{RECORDING_MODE: "toggle", TOGGLE_KEY_CODE: "junk"}),
        contains="pushToTalk",
    )


def _case_require_push_to_talk_standalone() -> None:
    assert require_push_to_talk(lambda: {RECORDING_MODE: PUSH_TO_TALK}) == PUSH_TO_TALK
    assert require_push_to_talk(lambda: {}) == PUSH_TO_TALK  # fresh install
    try:
        require_push_to_talk(lambda: {RECORDING_MODE: "toggle"})
    except PTTBindingError:
        return
    raise AssertionError("expected a refusal for toggle mode")


def _case_operational_failures_refuse() -> None:
    """A nonzero `defaults` exit must NOT be read as 'the key is absent'.

    This is why the module exports the whole domain: `defaults read <key>` gives
    a missing key and an operational error the same exit status and the same
    English sentence, so absence could only be guessed at. `export` succeeds even
    for a nonexistent domain, making any nonzero exit unambiguously operational.
    """
    for failure in (
        PreferenceFailure.COMMAND_UNAVAILABLE,
        PreferenceFailure.COMMAND_FAILED,
        PreferenceFailure.TIMEOUT,
        PreferenceFailure.MALFORMED_DOMAIN,
    ):
        def reader(f=failure):
            raise PreferenceReadError(SHARED_DOMAIN, f)

        try:
            resolve(
                reader,
                key_codes_by_name=TEST_KEY_CODES,
                modifier_keys_by_name=TEST_MODIFIER_KEYS,
            )
        except PTTBindingError as error:
            assert failure.value in str(error), (failure, error)
        else:
            raise AssertionError(f"{failure.name} was not refused")


def _case_no_exception_escapes_as_a_product_verdict() -> None:
    """The whole class, not the single instance review named.

    Anything escaping as a non-`PTTBindingError` is caught by a caller's generic
    handler and recorded as a failed product scenario.
    """
    original = subprocess.run

    def deny(*_args, **_kwargs):
        raise PermissionError(13, "Permission denied")

    subprocess.run = deny
    try:
        read_domain()
    except PTTBindingError:
        pass
    except Exception as error:  # noqa: BLE001
        raise AssertionError(f"OSError escaped as {type(error).__name__}") from error
    else:
        raise AssertionError("expected a refusal when defaults cannot be launched")
    finally:
        subprocess.run = original

    original_loader = globals()["_load_input_key_maps"]

    def unavailable():
        raise ImportError("No module named 'Quartz'")

    globals()["_load_input_key_maps"] = unavailable
    try:
        resolve(lambda: _domain())
    except PTTBindingError:
        pass
    except Exception as error:  # noqa: BLE001
        raise AssertionError(f"ImportError escaped as {type(error).__name__}") from error
    else:
        raise AssertionError("expected a refusal when the key maps cannot load")
    finally:
        globals()["_load_input_key_maps"] = original_loader


def _case_domain_export_is_read_once() -> None:
    """One subprocess per resolve, not one per key.

    `faultInjection` taps inside a 100 ms fuzz window and a 500 ms double-tap
    window; three reads measured 24 ms mean / 49 ms max, enough to miss them and
    report a product failure. Counting the reads is what stops that returning.
    """
    calls = []

    def counting_reader():
        calls.append(1)
        return _domain()

    resolve(
        counting_reader,
        key_codes_by_name=TEST_KEY_CODES,
        modifier_keys_by_name=TEST_MODIFIER_KEYS,
    )
    assert len(calls) == 1, f"expected exactly 1 domain read, got {len(calls)}"


def _case_swift_python_modifier_parity() -> None:
    assert_modifier_table_parity()


def _case_canonical_defaults_match_swift() -> None:
    assert_canonical_defaults_match_swift()


def _case_parity_extractor_is_armed() -> None:
    # A parity check that silently extracts nothing would pass forever.
    import tempfile

    root = _repo_root()
    source = (root / "Sources/EnviousWisprServices/KeySymbols.swift").read_text(
        encoding="utf-8"
    )
    assert "flagsByKeyCode" in source, "fixture assumption broken"
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as handle:
        handle.write(source.replace("flagsByKeyCode", "renamed"))
        temp = Path(handle.name)
    try:
        swift_modifier_keycodes(temp)
    except AssertionError:
        return
    finally:
        temp.unlink(missing_ok=True)
    raise AssertionError("extractor returned instead of raising on a renamed table")


CASES: list[tuple[str, Callable[[], None]]] = [
    ("globe resolves to fn", _case_globe_resolves),
    ("every modifier resolves", _case_every_modifier_resolves),
    ("ordinary key resolves", _case_ordinary_key_resolves),
    ("ordinary key + modifiers is a chord", _case_ordinary_key_with_modifiers_is_a_chord),
    ("modifier + stray modifiers still resolves", _case_modifier_with_stray_modifiers_still_resolves),
    ("unknown keycode refuses", _case_unknown_keycode_refuses),
    ("fresh install resolves to canonical defaults", _case_fresh_install_resolves_to_canonical_defaults),
    ("absent key does not mask a configured one", _case_absent_key_does_not_mask_a_configured_one),
    ("present but malformed refuses", _case_present_but_malformed_refuses),
    ("type rule matches Swift as? Int", _case_type_rule_matches_swift_as_int),
    ("toggle mode refuses", _case_toggle_mode_refuses),
    ("mode is checked before the key", _case_mode_is_checked_before_the_key),
    ("require_push_to_talk standalone", _case_require_push_to_talk_standalone),
    ("operational failures refuse", _case_operational_failures_refuse),
    ("no exception escapes as a product verdict", _case_no_exception_escapes_as_a_product_verdict),
    ("domain export is read once", _case_domain_export_is_read_once),
    ("swift/python modifier parity", _case_swift_python_modifier_parity),
    ("canonical defaults match Swift", _case_canonical_defaults_match_swift),
    ("parity extractor is armed", _case_parity_extractor_is_armed),
]


def run_self_tests(cases: list[tuple[str, Callable[[], None]]]) -> int:
    """Print EVERY failure, then exit once — a required gate must not cost one CI
    run per defect."""
    failures: list[str] = []
    for name, test in cases:
        try:
            test()
        except Exception as error:  # noqa: BLE001 - a self-test reports every shape
            failures.append(f"{name}: {type(error).__name__}: {error}")

    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL: {failure}", file=sys.stderr)
        print(f"SELF-TEST FAILED: {len(failures)}/{len(cases)} cases", file=sys.stderr)
        return 1

    print(f"SELF-TEST PASS: {len(cases)} cases")
    return 0


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Resolve the app's PTT binding.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        return run_self_tests(CASES)

    binding = resolve()
    print(
        f"key={binding.key_name} keycode={binding.keycode} "
        f"modifiers={binding.modifiers_raw} mode={binding.recording_mode} "
        f"modifier_only={binding.is_modifier_only}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    return run_instrument_boundary(lambda: _main(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    raise SystemExit(main())
