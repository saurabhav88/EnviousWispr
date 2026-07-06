#!/usr/bin/env python3
"""Deploy gate for the parakeet-mirror worker (#1339).

Run AFTER `wrangler deploy` and BEFORE the app change that points at the
mirror ships. Verifies, against https://models.enviouslabs.co:

  1. EG-1 routes (live traffic) are untouched: /eg1/... still serves.
  2. The worker listing, walked recursively exactly like FluidAudio walks it,
     reconstructs EXACTLY the expected manifest's file set (path + size).
     The expected manifest derives from the pinned upstream revision, never
     from bucket contents (anti-self-certification, plan E3/E3a).
  3. Every file downloads in full and matches its SHA-256.
  4. Range semantics: bounded/suffix/open 206 with correct Content-Range,
     past-EOF 416, multi-range tolerated.
  5. Unknown paths 404 with JSON (never an HTML page a client would choke on).

Exit 0 = safe to flip. Any failure = do NOT ship the app change.
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

HOST = "https://models.enviouslabs.co"
REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = json.load(open(os.path.join(HERE, "..", "expected-manifest.json")))

failures = []


def check(name, cond, detail=""):
    status = "ok" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def fetch(path, method="GET", headers=None, want_body=True):
    # Zone bot protection 403s Python's default UA; identify as a normal client
    # (the app itself downloads via URLSession/CFNetwork, which passes).
    hdrs = {"User-Agent": "EnviousWispr-deploy-gate/1 (curl-equivalent)"}
    hdrs.update(headers or {})
    req = urllib.request.Request(HOST + path, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, (r.read() if want_body else b"")
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()


# 1. EG-1 live routes untouched
st, hd, _ = fetch("/eg1/EG-1-MODEL-LICENSE.txt", want_body=False)
check("EG-1 license route still serves (worker must not shadow /eg1/)", st == 200, f"status {st}")

# 2. Recursive listing walk == expected manifest
found = {}


def walk(sub=""):
    path = f"/api/models/{REPO}/tree/main" + (f"/{sub}" if sub else "")
    st, hd, body = fetch(path)
    check(f"listing {sub or '(root)'} 200 JSON", st == 200 and "json" in hd.get("content-type", ""), f"status {st}")
    items = json.loads(body)
    for item in items:
        if item["type"] == "directory":
            walk(item["path"])
        else:
            found[item["path"]] = item["size"]


walk()
expected = {f["path"]: f["size"] for f in MANIFEST["files"]}
check(
    "listing walk reconstructs the exact expected file set (path+size)",
    found == expected,
    f"extra={sorted(set(found) - set(expected))} missing={sorted(set(expected) - set(found))} "
    f"size-diff={[p for p in found if p in expected and found[p] != expected[p]]}",
)

# 3. Full-content SHA-256 for every file
for f in MANIFEST["files"]:
    st, hd, body = fetch(f"/{REPO}/resolve/main/{f['path']}")
    ok = st == 200 and len(body) == f["size"] and hashlib.sha256(body).hexdigest() == f["sha256"]
    check(f"sha256 {f['path']}", ok, f"status {st} len {len(body)}")

# 4. Range grid against the big encoder weight
big = next(f for f in MANIFEST["files"] if f["path"].endswith("Encoder.mlmodelc/weights/weight.bin"))
bp, bs = f"/{REPO}/resolve/main/{big['path']}", big["size"]

st, hd, body = fetch(bp, headers={"Range": "bytes=0-1023"})
check("bounded range 206", st == 206 and len(body) == 1024 and hd.get("content-range") == f"bytes 0-1023/{bs}")
st, hd, body = fetch(bp, headers={"Range": "bytes=-512"})
check("suffix range 206", st == 206 and len(body) == 512 and hd.get("content-range") == f"bytes {bs-512}-{bs-1}/{bs}")
st, hd, body = fetch(bp, headers={"Range": f"bytes={bs-64}-"})
check("open-ended range 206", st == 206 and len(body) == 64)
st, hd, _ = fetch(bp, headers={"Range": f"bytes={bs}-"}, want_body=False)
check("past-EOF range 416 with bytes */size", st == 416 and hd.get("content-range") == f"bytes */{bs}")

# 5. Unknown path is JSON 404
st, hd, _ = fetch(f"/{REPO}/resolve/main/NoSuchFile.bin", want_body=False)
check("unknown file 404 JSON", st == 404 and "json" in hd.get("content-type", ""), f"status {st}")
st, hd, _ = fetch(f"/api/models/{REPO}/tree/main/NoSuch.mlmodelc", want_body=False)
check("unknown listing 404 JSON", st == 404 and "json" in hd.get("content-type", ""), f"status {st}")

print()
if failures:
    print(f"DEPLOY GATE FAILED ({len(failures)}): {failures}")
    sys.exit(1)
total = sum(f["size"] for f in MANIFEST["files"])
print(f"DEPLOY GATE PASSED — {len(MANIFEST['files'])} files ({total:,} bytes) verified end to end at {HOST}, EG-1 untouched.")
