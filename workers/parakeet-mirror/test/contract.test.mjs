// Contract grid for the parakeet-mirror worker (#1339, #1405).
// The worker owns listing + the download ALLOWLIST; it 302-redirects known
// files to the cache-enabled native R2 path and no longer serves bytes itself.
// So this suite locks: listing shape, the 302 target for known files, the
// JSON-404 allowlist (never R2's HTML 404), method/encoding hygiene, and
// manifest integrity. The BYTE + Range grid now lives against live R2 in
// scripts/verify-deploy.py (R2 owns 200/206/416/HEAD/ETag natively).
// Run: node --test workers/parakeet-mirror/test/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const manifest = JSON.parse(
  readFileSync(
    fileURLToPath(new URL("../expected-manifest.json", import.meta.url)),
    "utf8"
  )
);
const worker = (await import("../src/index.js")).default;

const REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml";
const SMALL = "config.json"; // 2 bytes
const SUB = "Encoder.mlmodelc/model.mil"; // a nested known file

// Expected 302 target for a given raw (as-sent) resolve suffix: the object's
// native R2 custom-domain path on the same host, raw suffix forwarded verbatim.
const loc = (rawSuffix) =>
  `https://models.enviouslabs.co/parakeet/${REPO}/${rawSuffix}`;

// The worker no longer reads env (bytes left the worker); pass none.
const req = (path, init = {}) =>
  worker.fetch(new Request(`https://models.enviouslabs.co${path}`, init));

// --- Listing (unchanged: precomputed static tree) ---
test("listing root returns HF-shaped immediate children", async () => {
  const r = await req(`/api/models/${REPO}/tree/main`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-type"), "application/json");
  const items = await r.json();
  assert.ok(Array.isArray(items));
  const dirs = items.filter((i) => i.type === "directory").map((i) => i.path);
  assert.ok(dirs.includes("Encoder.mlmodelc"));
  assert.ok(dirs.includes("JointDecisionv3.mlmodelc"));
  const files = items.filter((i) => i.type === "file").map((i) => i.path);
  assert.ok(files.includes("parakeet_vocab.json"));
  assert.ok(files.includes("config.json"));
  for (const i of items) {
    assert.ok(["file", "directory"].includes(i.type));
    assert.equal(typeof i.path, "string");
    assert.equal(typeof i.size, "number");
  }
});

test("listing subdirectory returns full paths from repo root", async () => {
  const r = await req(`/api/models/${REPO}/tree/main/Encoder.mlmodelc`);
  const items = await r.json();
  const weights = items.find((i) => i.path === "Encoder.mlmodelc/weights");
  assert.equal(weights.type, "directory");
  const mil = items.find((i) => i.path === "Encoder.mlmodelc/model.mil");
  assert.equal(mil.type, "file");
});

test("listing nested subdirectory", async () => {
  const r = await req(`/api/models/${REPO}/tree/main/Encoder.mlmodelc/weights`);
  const items = await r.json();
  assert.equal(items.length, 1);
  assert.equal(items[0].path, "Encoder.mlmodelc/weights/weight.bin");
});

test("listing unknown path is 404 JSON, never HTML", async () => {
  const r = await req(`/api/models/${REPO}/tree/main/NoSuch.mlmodelc`);
  assert.equal(r.status, 404);
  assert.equal(r.headers.get("content-type"), "application/json");
});

test("listing for a different repo is 404 (route scope)", async () => {
  const r = await req(`/api/models/Other/repo/tree/main`);
  assert.equal(r.status, 404);
});

// --- Resolve: known files 302 to the cached native R2 path ---
test("resolve known file: 302 to the native R2 path, no body", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`);
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), loc(SMALL));
  assert.equal((await r.arrayBuffer()).byteLength, 0);
});

test("resolve nested known file: 302 preserves the full sub-path", async () => {
  const r = await req(`/${REPO}/resolve/main/${SUB}`);
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), loc(SUB));
});

test("HEAD known file: also 302 (client follows HEAD->HEAD, resume identity intact)", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, { method: "HEAD" });
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), loc(SMALL));
});

test("Range on a known file: still a plain 302 (R2 owns Range, worker never parses it)", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, {
    headers: { range: "bytes=0-0" },
  });
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), loc(SMALL));
});

test("302 forwards the raw (percent-encoded) suffix verbatim so CF's own decode resolves the key", async () => {
  // config%2Ejson decodes to config.json (a known file); the worker validates
  // the DECODED path but forwards the RAW suffix, and CF applies the same decode.
  const r = await req(`/${REPO}/resolve/main/config%2Ejson`);
  assert.equal(r.status, 302);
  assert.equal(r.headers.get("location"), loc("config%2Ejson"));
});

// --- Resolve allowlist: unknown/malformed never redirect, never reach R2 ---
test("resolve unknown file: 404 JSON (never a 302 to R2's HTML 404)", async () => {
  const r = await req(`/${REPO}/resolve/main/NoSuch.bin`);
  assert.equal(r.status, 404);
  assert.match(r.headers.get("content-type") ?? "", /application\/json/);
});

test("resolve file NOT in manifest but maybe in bucket (_meta) is 404 — manifest is the allowlist", async () => {
  const r = await req(`/${REPO}/resolve/main/_meta/expected-manifest.json`);
  assert.equal(r.status, 404);
});

test("path-traversal attempt is 404 (not in allowlist, never redirected)", async () => {
  const r = await req(`/${REPO}/resolve/main/../../etc/passwd`);
  assert.equal(r.status, 404);
});

test("malformed percent-encoding on resolve: 404 JSON, never a thrown 500", async () => {
  const r = await req(`/${REPO}/resolve/main/%E0%A4%A`);
  assert.equal(r.status, 404);
  assert.match(r.headers.get("content-type") ?? "", /application\/json/);
});

test("malformed percent-encoding on listing: 404 JSON, never a thrown 500", async () => {
  const r = await req(`/api/models/${REPO}/tree/main/%ZZ`);
  assert.equal(r.status, 404);
  assert.match(r.headers.get("content-type") ?? "", /application\/json/);
});

// --- Methods and route hygiene ---
test("POST: 405 with Allow", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, { method: "POST" });
  assert.equal(r.status, 405);
  assert.equal(r.headers.get("allow"), "GET, HEAD");
});

test("unrelated path under scope: 404 JSON", async () => {
  const r = await req(`/${REPO}/resolve/other/${SMALL}`);
  assert.equal(r.status, 404);
});

// --- Manifest integrity (the committed manifest itself) ---
test("manifest carries sha256+size for all 23 files incl. vocab and required dirs", async () => {
  assert.equal(manifest.files.length, 23);
  assert.equal(manifest.repo, REPO);
  assert.ok(manifest.revision.length === 40);
  const paths = manifest.files.map((f) => f.path);
  assert.ok(paths.includes("parakeet_vocab.json"));
  for (const dir of manifest.requiredModelDirs) {
    assert.ok(paths.some((p) => p.startsWith(dir + "/")), `missing ${dir}`);
  }
  for (const f of manifest.files) {
    assert.match(f.sha256, /^[0-9a-f]{64}$/);
    assert.ok(f.size > 0);
  }
});
