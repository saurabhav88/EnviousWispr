#!/usr/bin/env python3
"""Deploy gate for the parakeet-mirror worker (#1339, #1405).

Run AFTER `wrangler deploy` and BEFORE the app change that points at the
mirror ships. Verifies, against https://models.enviouslabs.co:

  1. EG-1 routes (live traffic) are untouched: /eg1/... still serves DIRECTLY
     (200, no redirect) — the worker must not shadow /eg1/.
  2. The download bridge (#1405): a known resolve URL returns a 302 to the
     native cache-enabled R2 path (/parakeet/{REPO}/{file}); an unknown resolve
     URL returns THIS worker's JSON 404 (never a redirect, never R2's HTML 404).
  3. The worker listing, walked recursively exactly like FluidAudio walks it,
     reconstructs EXACTLY the expected manifest's file set (path + size).
     The expected manifest derives from the pinned upstream revision, never
     from bucket contents (anti-self-certification, plan E3/E3a).
  4. Every file, fetched the way a client walks it (resolve -> 302 -> R2),
     downloads in full and matches its SHA-256, landing on the /parakeet/ path.
  5. Range semantics through the redirect: bounded/suffix/open 206 with correct
     Content-Range, past-EOF 416. HEAD through the redirect: 200 + length + etag.

Exit 0 = safe to flip. Any failure = do NOT ship the app change.
(Cache MISS->HIT + object-size guardrail assertions are Phase 3, #1405.)
"""
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

HOST = "https://models.enviouslabs.co"
REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
NATIVE_PREFIX = f"/parakeet/{REPO}/"  # cache-enabled R2 custom-domain path
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = json.load(open(os.path.join(HERE, "..", "expected-manifest.json")))

# Zone bot protection 403s Python's default UA; identify as a normal client
# (the app itself downloads via URLSession/CFNetwork, which passes).
UA = {"User-Agent": "EnviousWispr-deploy-gate/1 (curl-equivalent)"}

failures = []


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # decline: the 3xx surfaces as HTTPError, we assert on it


_no_redirect = urllib.request.build_opener(_NoRedirect)


def check(name, cond, detail=""):
    status = "ok" if cond else "FAIL"
    print(f"[{status}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def fetch(path, method="GET", headers=None, want_body=True):
    """Follow redirects (client simulation). Returns (status, headers, body, final_url)."""
    hdrs = dict(UA)
    hdrs.update(headers or {})
    req = urllib.request.Request(HOST + path, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read() if want_body else b""
            return r.status, {k.lower(): v for k, v in r.headers.items()}, body, r.geturl()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read(), e.url


def fetch_no_redirect(path, method="GET", headers=None):
    """Do NOT follow redirects. Returns (status, headers). Used to assert the 302 itself."""
    hdrs = dict(UA)
    hdrs.update(headers or {})
    req = urllib.request.Request(HOST + path, method=method, headers=hdrs)
    try:
        with _no_redirect.open(req) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}


# 1. EG-1 live routes untouched — served DIRECTLY (200), not shadowed/redirected.
st, hd = fetch_no_redirect("/eg1/EG-1-MODEL-LICENSE.txt", method="HEAD")
check("EG-1 license route serves directly, no worker shadow", st == 200, f"status {st}")

# 2. Download bridge (#1405): known -> 302 to native path; unknown -> JSON 404.
sample = MANIFEST["files"][0]["path"]
st, hd = fetch_no_redirect(f"/{REPO}/resolve/main/{sample}")
loc = hd.get("location", "")
check(
    "known resolve -> 302 to native /parakeet/ path",
    st == 302 and loc == f"{HOST}{NATIVE_PREFIX}{sample}",
    f"status {st} location {loc!r}",
)
st, hd = fetch_no_redirect(f"/{REPO}/resolve/main/NoSuchFile.bin")
check("unknown resolve -> JSON 404, NOT a redirect", st == 404 and "json" in hd.get("content-type", ""), f"status {st}")

# 3. Recursive listing walk == expected manifest
found = {}


def walk(sub=""):
    path = f"/api/models/{REPO}/tree/main" + (f"/{sub}" if sub else "")
    st, hd, body, _ = fetch(path)
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

# 4. Full-content SHA-256 for every file, walked resolve -> 302 -> R2 like a client.
first = True
for f in MANIFEST["files"]:
    st, hd, body, final = fetch(f"/{REPO}/resolve/main/{f['path']}")
    ok = st == 200 and len(body) == f["size"] and hashlib.sha256(body).hexdigest() == f["sha256"]
    check(f"sha256 {f['path']}", ok, f"status {st} len {len(body)}")
    if first:
        # Prove the bytes actually came THROUGH the redirect to the cached path,
        # not from a worker regression that started serving bytes again.
        check("download lands on the native /parakeet/ path after 302", NATIVE_PREFIX in final, f"final {final}")
        first = False

# 5. Range grid + HEAD through the redirect, against the big encoder weight.
big = next(f for f in MANIFEST["files"] if f["path"].endswith("Encoder.mlmodelc/weights/weight.bin"))
bp, bs = f"/{REPO}/resolve/main/{big['path']}", big["size"]

st, hd, body, final = fetch(bp, headers={"Range": "bytes=0-1023"})
check("bounded range 206 (via 302)", st == 206 and len(body) == 1024 and hd.get("content-range") == f"bytes 0-1023/{bs}", f"status {st} final {final}")
st, hd, body, _ = fetch(bp, headers={"Range": "bytes=-512"})
check("suffix range 206", st == 206 and len(body) == 512 and hd.get("content-range") == f"bytes {bs-512}-{bs-1}/{bs}")
st, hd, body, _ = fetch(bp, headers={"Range": f"bytes={bs-64}-"})
check("open-ended range 206", st == 206 and len(body) == 64)
st, hd, _, _ = fetch(bp, headers={"Range": f"bytes={bs}-"}, want_body=False)
check("past-EOF range 416 with bytes */size", st == 416 and hd.get("content-range") == f"bytes */{bs}")

# HEAD through the redirect (the resume-identity path): 200 + length + etag.
st, hd, _, _ = fetch(bp, method="HEAD", want_body=False)
check("HEAD via 302 -> 200 with content-length + etag", st == 200 and hd.get("content-length") == str(bs) and bool(hd.get("etag")), f"status {st}")

# 6. Unknown listing path is JSON 404 (the resolve 404 is checked in section 2).
st, hd, _, _ = fetch(f"/api/models/{REPO}/tree/main/NoSuch.mlmodelc", want_body=False)
check("unknown listing 404 JSON", st == 404 and "json" in hd.get("content-type", ""), f"status {st}")

print()
if failures:
    print(f"DEPLOY GATE FAILED ({len(failures)}): {failures}")
    sys.exit(1)
total = sum(f["size"] for f in MANIFEST["files"])
print(f"DEPLOY GATE PASSED — {len(MANIFEST['files'])} files ({total:,} bytes) verified end to end (resolve -> 302 -> cached R2) at {HOST}, EG-1 untouched.")
