// Parakeet model mirror (#1339).
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
// Downloads stream R2 objects with Range/206 support; the 445MB encoder is
// never buffered in worker memory.

import manifest from "../expected-manifest.json" with { type: "json" };

const REPO = "FluidInference/parakeet-tdt-0.6b-v3-coreml";
const R2_PREFIX = `parakeet/${REPO}/`;
const LISTING_BASE = `/api/models/${REPO}/tree/main`;
const RESOLVE_BASE = `/${REPO}/resolve/main/`;

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

// Parse a single-range "bytes=..." header against a known total size.
// Returns {offset, length} | "unsatisfiable" | null (absent/ignored → full 200).
function parseRange(header, size) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return null; // multi-range or malformed: ignore per RFC, serve 200
  const [, startStr, endStr] = m;
  if (startStr === "" && endStr === "") return null;
  if (startStr === "") {
    // suffix: last N bytes
    const n = Number(endStr);
    if (n === 0) return "unsatisfiable";
    const length = Math.min(n, size);
    return { offset: size - length, length };
  }
  const start = Number(startStr);
  if (start >= size) return "unsatisfiable";
  const end = endStr === "" ? size - 1 : Math.min(Number(endStr), size - 1);
  if (end < start) return "unsatisfiable";
  return { offset: start, length: end - start + 1 };
}

function contentTypeFor(path) {
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".txt")) return "text/plain";
  return "application/octet-stream";
}


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

async function handleResolve(request, env, pathname, isHead) {
  const filePath = safeDecode(pathname.slice(RESOLVE_BASE.length));
  const meta = filePath === null ? undefined : FILES.get(filePath);
  if (!meta) return notFound();

  const range = parseRange(request.headers.get("range"), meta.size);
  if (range === "unsatisfiable") {
    return new Response(null, {
      status: 416,
      headers: {
        "content-range": `bytes */${meta.size}`,
        "accept-ranges": "bytes",
      },
    });
  }

  const key = R2_PREFIX + filePath;
  const headers = new Headers({
    "accept-ranges": "bytes",
    "content-type": contentTypeFor(filePath),
  });

  if (isHead) {
    const head = await env.MODELS.head(key);
    if (!head) return notFound();
    headers.set("etag", head.httpEtag);
    headers.set("content-length", String(head.size));
    return new Response(null, { status: 200, headers });
  }

  const object = await env.MODELS.get(key, range ? { range } : undefined);
  if (!object) return notFound();
  headers.set("etag", object.httpEtag);

  if (range) {
    headers.set("content-length", String(range.length));
    headers.set(
      "content-range",
      `bytes ${range.offset}-${range.offset + range.length - 1}/${meta.size}`
    );
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("content-length", String(meta.size));
  return new Response(object.body, { status: 200, headers });
}

export default {
  async fetch(request, env) {
    const isHead = request.method === "HEAD";
    if (request.method !== "GET" && !isHead) {
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
      return handleResolve(request, env, pathname, isHead);
    }
    // Anything else under our narrowly-scoped routes is unknown.
    return notFound();
  },
};
