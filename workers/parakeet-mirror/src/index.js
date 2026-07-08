// Parakeet model mirror (#1339, #1405).
//
// Serves the pinned Parakeet v3 set from R2 behind the two URL shapes
// FluidAudio's ModelRegistry builds from its baseURL:
//   listing:  GET /api/models/{REPO}/tree/main[/{subPath}]
//   download: GET /{REPO}/resolve/main/{filePath}
//
// The listing is answered from a precomputed static tree derived from the
// committed expected-manifest.json (generated from the pinned upstream
// revision, never from bucket contents) — this kills the listing-API hang at
// its root: no origin round-trip, no rate limit, byte-exact contract.
//
// Downloads are 302-redirected to the object's native R2 custom-domain path
// (/parakeet/{REPO}/{filePath}), which is edge-cached (#1405 Cache Rule) and
// serves 200/206/416/HEAD/ETag natively — so a far-from-origin user is served
// from a regional edge, not transatlantic R2, and the 445MB encoder never
// streams through this worker's memory or its 100k/day request budget. The
// worker stays the allowlist authority: an unknown path returns THIS worker's
// JSON 404, never R2's default HTML 404 (which the app's captive-portal guard
// would treat as an intercepted network). §14.1 verified the app's URLSession
// follows the 302 preserving Range + resume identity + the SHA-256 admission
// gate (2026-07-07), and v2.3.1 clients follow it with no app update.

import manifest from "../expected-manifest.json" with { type: "json" };

const REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml";
const R2_PREFIX = `parakeet/${REPO}/`;
const LISTING_BASE = `/api/models/${REPO}/tree/main`;
const RESOLVE_BASE = `/${REPO}/resolve/main/`;
// Downloads redirect to the object's native path on the same custom domain.
// This path is NOT covered by this worker's routes (which are scoped to
// LISTING_BASE and RESOLVE_BASE), so it falls through to the R2 custom-domain
// binding — no loop back through the worker.
const REDIRECT_ORIGIN = "https://models.enviouslabs.co";

// path -> {size, sha256} for every expected file (the only downloadable set).
const FILES = new Map(manifest.files.map((f) => [f.path, f]));

// dirPath ("" = root) -> immediate children in Hugging Face tree-API shape:
// [{type: "directory"|"file", path: <full path from repo root>, size}].
// FluidAudio reads exactly type/path/size and recurses into directories.
const TREE = (() => {
  const dirs = new Map(); // dirPath -> Map(childName -> entry)
  const ensureDir = (p) => {
    if (!dirs.has(p)) dirs.set(p, new Map());
    return dirs.get(p);
  };
  ensureDir("");
  for (const f of manifest.files) {
    const parts = f.path.split("/");
    for (let i = 0; i < parts.length; i++) {
      const parent = parts.slice(0, i).join("/");
      const full = parts.slice(0, i + 1).join("/");
      const children = ensureDir(parent);
      if (i === parts.length - 1) {
        children.set(parts[i], { type: "file", path: full, size: f.size });
      } else {
        ensureDir(full);
        if (!children.has(parts[i])) {
          children.set(parts[i], { type: "directory", path: full, size: 0 });
        }
      }
    }
  }
  const out = new Map();
  for (const [dir, children] of dirs) out.set(dir, [...children.values()]);
  return out;
})();

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const notFound = () => json({ error: "Not found" }, 404);

// Malformed percent-encoding must map to the JSON 404 contract, not a thrown
// URIError -> 500 (public route; Codex r2). Returns null on bad escapes.
function safeDecode(component) {
  try {
    return decodeURIComponent(component);
  } catch {
    return null;
  }
}

async function handleListing(pathname) {
  let sub = "";
  if (pathname !== LISTING_BASE) {
    if (!pathname.startsWith(LISTING_BASE + "/")) return notFound();
    sub = safeDecode(pathname.slice(LISTING_BASE.length + 1));
    if (sub === null) return notFound();
  }
  const children = TREE.get(sub);
  if (!children) return notFound();
  return json(children);
}

function handleResolve(pathname) {
  // Allowlist authority: the committed manifest is the ONLY downloadable set.
  // Validate against the DECODED path; an unknown or malformed path gets this
  // worker's JSON 404 and never reaches R2 (whose miss is an HTML 404).
  const rawSuffix = pathname.slice(RESOLVE_BASE.length);
  const filePath = safeDecode(rawSuffix);
  if (filePath === null || !FILES.get(filePath)) return notFound();

  // Known file: 302 to the cache-enabled native R2 path. Forward the request's
  // raw (still percent-encoded) suffix unchanged so Cloudflare's own decode
  // resolves the exact R2 key — no re-encode asymmetry. GET and HEAD both
  // redirect; a 302 preserves the method and the Range header (§14.1), and R2
  // returns the object's stable ETag on both so resume identity is unbroken.
  const location = `${REDIRECT_ORIGIN}/${R2_PREFIX}${rawSuffix}`;
  return new Response(null, { status: 302, headers: { location } });
}

export default {
  async fetch(request) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method not allowed", {
        status: 405,
        headers: { allow: "GET, HEAD" },
      });
    }
    const { pathname } = new URL(request.url);
    if (pathname === LISTING_BASE || pathname.startsWith(LISTING_BASE + "/")) {
      return handleListing(pathname);
    }
    if (pathname.startsWith(RESOLVE_BASE)) {
      return handleResolve(pathname);
    }
    // Anything else under our narrowly-scoped routes is unknown.
    return notFound();
  },
};
