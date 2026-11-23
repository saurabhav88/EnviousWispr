#!/usr/bin/env python3
"""Sign the published first-run Setup rules (#4528 plan §3.2). Needs the `cryptography` package.

  sign.py sign [FILE]          write FILE.sig (default: website/public/setup-rules.json)
  sign.py public-key           print the public key (32 raw bytes, standard base64)
  sign.py verify KEY [FILE]    check FILE against FILE.sig with public key KEY (base64)
  sign.py same A B             require two files to be byte-identical (bundled vs website copy)
  sign.py --self-test          run the cases below with throwaway keys and the interop fixtures

The private key never touches disk or a command line: `sign` and `public-key` read it from the
environment variable SETUP_RULES_SIGNING_KEY (PKCS#8 PEM), which you provide only through
  ~/.claude/bin/get-key launch setup-rules-signing-key SETUP_RULES_SIGNING_KEY -- \\
    python3 scripts/setup-rules/sign.py sign

Encoding, shared with the app (`SetupRulesSignature` in
Sources/EnviousWisprServices/Setup/SetupRulesStore.swift): Ed25519 over the EXACT bytes of the
rules file; FILE.sig holds the 64-byte signature as standard base64 text plus one newline; the
public key is the 32 raw bytes as standard base64. Exit 0 on success, 1 on any failure.
"""

import base64
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_FILE = REPO_ROOT / "website/public/setup-rules.json"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "interop"
KEY_ENV = "SETUP_RULES_SIGNING_KEY"


def _crypto():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )

    return serialization, Ed25519PrivateKey, Ed25519PublicKey


def private_key_from_env():
    serialization, Ed25519PrivateKey, _ = _crypto()
    pem = os.environ.get(KEY_ENV)
    if not pem:
        raise SystemExit(f"sign.py: {KEY_ENV} is not set; run through get-key launch (see header)")
    key = serialization.load_pem_private_key(pem.encode(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise SystemExit("sign.py: the key is not an Ed25519 private key")
    return key


def public_key_base64(private_key) -> str:
    serialization, _, _ = _crypto()
    raw = private_key.public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw
    )
    return base64.b64encode(raw).decode()


def signature_text(private_key, payload: bytes) -> str:
    return base64.b64encode(private_key.sign(payload)).decode() + "\n"


def verify(public_key_b64: str, payload: bytes, sig_text: bytes) -> bool:
    _, _, Ed25519PublicKey = _crypto()
    try:
        raw = base64.b64decode(public_key_b64, validate=True)
        signature = base64.b64decode(sig_text.decode().strip(), validate=True)
    except Exception:
        return False
    if len(raw) != 32 or len(signature) != 64:
        return False
    try:
        Ed25519PublicKey.from_public_bytes(raw).verify(signature, payload)
        return True
    except Exception:
        return False


def self_test() -> int:
    _, Ed25519PrivateKey, _ = _crypto()
    failures = []
    cases = 0

    def check(name, ok):
        nonlocal cases
        cases += 1
        if not ok:
            failures.append(name)

    key = Ed25519PrivateKey.generate()
    other = Ed25519PrivateKey.generate()
    payload = b'{"schema": 1, "revision": 2}\n'
    sig = signature_text(key, payload).encode()
    pub = public_key_base64(key)
    check("valid signature verifies", verify(pub, payload, sig))
    check("changed payload fails", not verify(pub, payload + b" ", sig))
    check("wrong key fails", not verify(public_key_base64(other), payload, sig))
    check("non-base64 signature fails", not verify(pub, payload, b"not base64!"))
    check("short signature fails", not verify(pub, payload, base64.b64encode(b"x" * 10)))
    check("bad public key fails", not verify("AAAA", payload, sig))
    check("signature text ends with one newline", sig.endswith(b"\n") and not sig.endswith(b"\n\n"))

    # Interop: the same fixture files the Swift tests verify (SetupRulesStoreTests).
    fixture_payload = (FIXTURES / "payload.json").read_bytes()
    fixture_sig = (FIXTURES / "payload.json.sig").read_bytes()
    fixture_pub = (FIXTURES / "public-key.txt").read_text().strip()
    check("interop fixture verifies", verify(fixture_pub, fixture_payload, fixture_sig))
    check("interop fixture fails when changed", not verify(fixture_pub, fixture_payload + b"\n", fixture_sig))

    for name in failures:
        print(f"FAIL: {name}")
    print(f"sign.py self-test: {cases - len(failures)}/{cases} passed")
    return 1 if failures or cases == 0 else 0


def main(argv) -> int:
    if not argv:
        print(__doc__)
        return 1
    command, rest = argv[0], argv[1:]
    if command == "--self-test":
        return self_test()
    if command == "public-key":
        print(public_key_base64(private_key_from_env()))
        return 0
    if command == "sign":
        path = Path(rest[0]) if rest else DEFAULT_FILE
        payload = path.read_bytes()
        Path(str(path) + ".sig").write_text(signature_text(private_key_from_env(), payload))
        print(f"signed {path} -> {path}.sig")
        return 0
    if command == "verify":
        if not rest:
            print("sign.py verify KEY [FILE]")
            return 1
        path = Path(rest[1]) if len(rest) > 1 else DEFAULT_FILE
        ok = verify(rest[0], path.read_bytes(), Path(str(path) + ".sig").read_bytes())
        print("verified" if ok else "SIGNATURE DOES NOT VERIFY")
        return 0 if ok else 1
    if command == "same":
        if len(rest) != 2:
            print("sign.py same A B")
            return 1
        same = Path(rest[0]).read_bytes() == Path(rest[1]).read_bytes()
        print("identical" if same else "FILES DIFFER")
        return 0 if same else 1
    print(f"unknown command {command}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
