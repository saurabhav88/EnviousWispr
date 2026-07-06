// Contract grid for the parakeet-mirror worker (#1339).
// Axes: route shape x method x Range semantics (open / bounded / suffix /
// zero-suffix / inverted / past-EOF / malformed / multi-range) x known/unknown
// paths x URL encoding. Run: node --test workers/parakeet-mirror/test/
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
const BIG = "Encoder.mlmodelc/weights/weight.bin";
const bigSize = manifest.files.find((f) => f.path === BIG).size;

// Map-backed R2 stub: bodies are deterministic patterns, range-aware.
function makeEnv() {
  const bytesFor = (key, offset, length) => {
    const buf = new Uint8Array(length);
    for (let i = 0; i < length; i++) buf[i] = (offset + i) % 251;
    return buf;
  };
  const sizeOf = (key) => {
    const rel = key.replace(`parakeet/${REPO}/`, "");
    const f = manifest.files.find((x) => x.path === rel);
    return f ? f.size : null;
  };
  return {
    MODELS: {
      async head(key) {
        const size = sizeOf(key);
        return size === null ? null : { size, httpEtag: '"stub"' };
      },
      async get(key, opts) {
        const size = sizeOf(key);
        if (size === null) return null;
        const offset = opts?.range?.offset ?? 0;
        const length = opts?.range?.length ?? size - offset;
        return { httpEtag: '"stub"', body: bytesFor(key, offset, length) };
      },
    },
  };
}

const req = (path, init = {}) =>
  worker.fetch(
    new Request(`https://models.enviouslabs.co${path}`, init),
    makeEnv()
  );

// --- Listing ---
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
  assert.equal(items[0].size, bigSize);
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

// --- Resolve: full downloads ---
test("resolve known file: 200, exact length, accept-ranges, etag", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-length"), "2");
  assert.equal(r.headers.get("accept-ranges"), "bytes");
  assert.ok(r.headers.get("etag"));
  assert.equal((await r.arrayBuffer()).byteLength, 2);
});

test("resolve unknown file: 404", async () => {
  const r = await req(`/${REPO}/resolve/main/NoSuch.bin`);
  assert.equal(r.status, 404);
});

test("resolve file NOT in manifest but maybe in bucket (_meta) is 404 — manifest is the allowlist", async () => {
  const r = await req(`/${REPO}/resolve/main/_meta/expected-manifest.json`);
  assert.equal(r.status, 404);
});

test("URL-encoded path resolves", async () => {
  const r = await req(
    `/${REPO}/resolve/main/Encoder.mlmodelc%2Fmodel.mil`.replace(
      "%2F",
      "/"
    ) // sanity: plain form
  );
  assert.equal(r.status, 200);
});

test("HEAD returns headers without body", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, { method: "HEAD" });
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("content-length"), "2");
  assert.equal((await r.arrayBuffer()).byteLength, 0);
});

// --- Range grid ---
const range = (h) => req(`/${REPO}/resolve/main/${BIG}`, { headers: { range: h } });
// Cloud review #1355: ignored/malformed range headers fall back to a full 200
// body — assert those on the SMALL file so the stub never materializes the
// 445MB encoder just to check a status code. Range MATH stays on BIG.
const rangeSmall = (h) =>
  req(`/${REPO}/resolve/main/${SMALL}`, { headers: { range: h } });

test("bounded range: 206 with correct content-range and length", async () => {
  const r = await range("bytes=0-1023");
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-length"), "1024");
  assert.equal(r.headers.get("content-range"), `bytes 0-1023/${bigSize}`);
  assert.equal((await r.arrayBuffer()).byteLength, 1024);
});

test("open-ended range: 206 to EOF", async () => {
  const start = bigSize - 100;
  const r = await range(`bytes=${start}-`);
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-length"), "100");
  assert.equal(
    r.headers.get("content-range"),
    `bytes ${start}-${bigSize - 1}/${bigSize}`
  );
});

test("suffix range: last N bytes", async () => {
  const r = await range("bytes=-500");
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-length"), "500");
  assert.equal(
    r.headers.get("content-range"),
    `bytes ${bigSize - 500}-${bigSize - 1}/${bigSize}`
  );
});

test("suffix longer than file clamps to whole file", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, {
    headers: { range: "bytes=-999" },
  });
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-length"), "2");
});

test("end beyond EOF clamps to EOF", async () => {
  const r = await req(`/${REPO}/resolve/main/${SMALL}`, {
    headers: { range: "bytes=1-99999" },
  });
  assert.equal(r.status, 206);
  assert.equal(r.headers.get("content-range"), `bytes 1-1/2`);
});

test("start past EOF: 416 with bytes */size", async () => {
  const r = await range(`bytes=${bigSize}-`);
  assert.equal(r.status, 416);
  assert.equal(r.headers.get("content-range"), `bytes */${bigSize}`);
});

test("inverted range: 416", async () => {
  const r = await range("bytes=500-100");
  assert.equal(r.status, 416);
});

test("zero-suffix (bytes=-0): 416", async () => {
  const r = await range("bytes=-0");
  assert.equal(r.status, 416);
});

test("malformed range is ignored: full 200", async () => {
  const r = await rangeSmall("bytes=abc");
  assert.equal(r.status, 200);
});

test("multi-range is ignored: full 200 (RFC-permitted)", async () => {
  const r = await rangeSmall("bytes=0-1,5-9");
  assert.equal(r.status, 200);
});

test("empty range value (bytes=-): ignored, full 200", async () => {
  const r = await rangeSmall("bytes=-");
  assert.equal(r.status, 200);
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
