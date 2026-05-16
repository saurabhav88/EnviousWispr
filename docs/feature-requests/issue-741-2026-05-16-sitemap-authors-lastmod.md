# Issue #741 — Sitemap /authors/* lastmod falls through to today's date — 2026-05-16

GitHub issue: `#741`. Parent / epic: n/a (Codex finding from PR #732 SEO audit). Tier: SMALL. Status: DRAFT.

## Preface — Lane + Live UAT declaration

**Lane:** Code (touches `website/astro.config.mjs`, which is in code-lane per `workflow-process.md §7`).

**Live UAT:** N — pure SEO-internal sitemap generator; no app/audio/UI surface. Verification is `astro build` + grep `sitemap-0.xml` for the expected `lastmod` value.

## Preface — User Rubric

User Rubric: N/A — Codex auto-triaged finding under SEO hygiene; no user-visible surface. The "user" of the sitemap is Googlebot / Bingbot / AI crawlers. Closest persona analog: Marcus (the SEO observer), but the change is mechanical.

## 0. TL;DR

`sourceForUrl()` in `website/astro.config.mjs:56` early-returns `null` for any URL starting with `/authors/`. Author pages are static `.astro` files on disk, so they could and should be mapped to their source mtime. As-is, every build stamps today's date on the author sitemap entry, defeating PR #732's freshness contract. Fix: map `/authors/<slug>/` → `src/pages/authors/<slug>.astro` and let the existing `mtimeIso` path resolve. SMALL. Evidence: build the site, grep the generated `sitemap-0.xml`, confirm `lastmod` matches the file mtime rather than `new Date().toISOString().slice(0,10)`.

## 1. Problem

PR #732 introduced an mtime-driven `lastmod` serializer for the sitemap so static pages report truthful change dates instead of every build looking fresh. `sourceForUrl` returns the source `.astro` path for routable static pages; the serializer reads `fs.statSync(src).mtime`. For author pages the function explicitly bails:

```js
// Author pages: /authors/<slug>/ → dynamic route, no single source file. Skip.
if (p.startsWith('/authors/')) return null;
```

The comment is inaccurate. The site has exactly one author page (`website/src/pages/authors/saurabh-vaish.astro`) and it is a static file. With `sourceForUrl` returning null, the serializer falls through to the final fallback at line 107: `item.lastmod = new Date().toISOString().slice(0, 10)`. Result: the `/authors/saurabh-vaish/` sitemap row updates every build whether the page changed or not.

Codex finding (PR #732 review): "this produces inaccurate churny sitemap metadata and undermines the goal of truthful `lastmod` values."

## 2. Goals & non-goals

### 2.1 Goals
- `/authors/saurabh-vaish/` sitemap entry reports `lastmod` matching the source file mtime, not today's date.
- Implementation extends the same pattern used for `/compare/<slug>/` (mtime-driven from `src/pages/<path>.astro`).
- No regression to existing sitemap entries (homepage, blog, compare, blog/index, static pages).

### 2.2 Non-goals
- Adding tag pages or tag routing. `website/src/pages/tags/` does not exist; the existing `/tags/` early return stays as-is.
- Dynamic-author support (we have one author file; if a `[...slug].astro` is added later, the routing logic can be revisited).
- Frontmatter-driven dates for author pages (no need; file mtime is the source of truth for static `.astro`).

## 3. Design

Replace the `/authors/*` null early return with a per-slug source-file mapping. Add a corresponding entry for parallelism with the `/compare/` blocks already in the function.

```js
// Author pages: /authors/<slug>/ → src/pages/authors/<slug>.astro (static file)
if (p.startsWith('/authors/')) {
  const slug = p.replace('/authors/', '');
  return path.join(__dirname, `src/pages/authors/${slug}.astro`);
}
```

`mtimeIso` already handles missing files (catches `statSync` failure and returns `null`), so a future `/authors/unknown-slug/` URL would safely fall through to the today-fallback rather than crashing the build.

The `/tags/` early return stays (`return null`) — no tag pages exist on disk, so any sitemap URL starting `/tags/` is either zero-result or future work.

## 3a. Metric Definition + Earliest Failure Point

**Metric definition.** Sitemap `lastmod` value for `https://enviouswispr.com/authors/saurabh-vaish/` equals the mtime of `website/src/pages/authors/saurabh-vaish.astro` in `YYYY-MM-DD` form (UTC), measured by running `cd website && npm run build` and grepping `dist/sitemap-0.xml`.

**Earliest failure point.** Build-time. If `path.join(__dirname, 'src/pages/authors/<slug>.astro')` resolves to a non-existent file, `mtimeIso` returns null and the serializer falls through to today's date — same behavior as before (no regression, just no fix for the missing case). A reviewer can verify the fix by greping the generated XML.

## 3b. Ownership justification

N/A — no coordinator/manager affected. This is a pure-function edit inside `website/astro.config.mjs`.

## 4. Contract deltas

None. `sourceForUrl` is internal to the Astro build pipeline and returns `string | null`. The change broadens which inputs return a string instead of null; downstream consumer (`mtimeIso`) already handles both branches.

**Legacy data compatibility.** No persisted state, no Codable. Sitemap is regenerated every build.

## 5. E2E state & lifecycle audit

| Path | Behavior under this change |
|---|---|
| Live / new item (primary path) | Author URL `/authors/saurabh-vaish/` → mapped → mtime → stamped in sitemap. |
| Saved / reloaded item | N/A — sitemap is build-time output, no persistence. |
| Retry or re-run (same item, same step) | Idempotent. Rebuild produces same `lastmod` until the source file is touched. |
| Background / async completion arriving after state changed | N/A — synchronous build step. |
| User manual override / edit path | N/A. |

**Upstream sources.** Single source: `npm run build` invokes `@astrojs/sitemap` integration via `astro.config.mjs`.

**UI side effects.** None. Sitemap is bot-facing.

**Persistence.** None inside the app. Generated XML lives in `website/dist/sitemap-0.xml` per build.

**App-kill scenario.** N/A.

**Concurrency guard.** N/A.

## 6. Downstream consumer matrix

| Contract delta | Consumer | Current behavior | Required behavior | Code change? | Verified by |
|---|---|---|---|---|---|
| `sourceForUrl('/authors/saurabh-vaish/')` returns a path instead of null | Sitemap `serialize` closure at `astro.config.mjs:97-105` | Falls through to today-date fallback at line 107 | Reads `mtimeIso(src)`, stamps file mtime | No additional change to consumer (already handles both branches) | Build-and-grep evidence in PR body |

Discovery method:
```
grep -n "sourceForUrl\|item.lastmod" website/astro.config.mjs
```
Confirms one definition, two read sites, no other consumers.

## 7. Failure-mode × caller table

| Failure mode | Origin | Caller | Expected UX | Expected persisted state | Expected metadata stamp | Expected retry |
|---|---|---|---|---|---|---|
| Author file missing for a URL the sitemap generator produces | `mtimeIso` returns null | sitemap `serialize` | URL falls through to today-fallback (unchanged from pre-fix behavior for that case) | N/A | None | Manual: add the file or remove the URL from routes |

## 8. Caller-visible signals audit

No implicit signals on touched types. `sourceForUrl`'s return value is read at exactly one call site and immediately consumed by `mtimeIso(src)`; neither `null` nor a path string carries semantic meaning beyond "do I have a file to stat." Verified by:

```
grep -nE "sourceForUrl|mtimeIso" website/astro.config.mjs
```

No UI, persistence, or analytics consumer of the function or its return.

## 9. Fallback source-of-truth audit

Single fallback unchanged: when `mtimeIso(src)` returns null (no file at the resolved path), `item.lastmod = new Date().toISOString().slice(0, 10)` (today). This branch is preserved as-is; the fix only changes which URLs reach `mtimeIso` with a non-null path.

## 10. Code reality check

```
$ grep -n "sourceForUrl\|authors\|tags" website/astro.config.mjs
51:function sourceForUrl(url) {
56:  if (p.startsWith('/authors/')) return null;
58:  if (p.startsWith('/tags/')) return null;
98:  const src = sourceForUrl(item.url);
```

```
$ ls website/src/pages/authors/
saurabh-vaish.astro

$ ls website/src/pages/tags/
ls: website/src/pages/tags/: No such file or directory
```

```
$ stat -f "%Sm" website/src/pages/authors/saurabh-vaish.astro
May 16 01:58:53 2026
```

Module-import claim: none changed.

Process-init claim: none changed.

String-literal claim: the path template `src/pages/authors/${slug}.astro` matches the existing `/compare/` pattern at `astro.config.mjs:67-68`.

### File list

- `website/astro.config.mjs`
  - Replace lines 55-56 (`/authors/*` null early return) with a per-slug source-path mapping mirroring the `/compare/<slug>/` block at lines 66-69. ~4 lines changed.

## 11. Testing

- Unit tests: none in the website Astro pipeline today. Adding one purely for this would create a parallel harness; correctness is verified by the build output.
- Build evidence: `cd website && npm run build`, then `grep -A1 "/authors/saurabh-vaish/" dist/sitemap-0.xml`. Expected `<lastmod>` matches the source file's mtime date (YYYY-MM-DD), NOT `new Date()` of the build run.

### 11.1 Live UAT spec

N/A — Preface declared Live UAT: N. Lane is Content/website-code; obligation is Astro `build-check` + sitemap evidence in the PR body. Per `phase3-validation.md §3`, the Content-lane Live UAT counterpart is the build + visual / output-grep; the Code-lane application of this here is the same, plus the regression check that no other URL's `lastmod` changes shape.

### 11.2 Other test obligations

`npm run build` exits 0. `grep` evidence pasted in PR body. No swift-test or other obligation applies to a website-only mjs edit.

## 12. Blast radius & rollback

- Modules touched: `website/astro.config.mjs` (one function).
- Modules NOT touched: any Swift source, any other website source, public/, content collections, _headers, package.json.
- Rollback: revert the single commit. No persisted state, no migration.

## 13. Ship criteria

- [ ] `cd website && npm run build` exits 0.
- [ ] `dist/sitemap-0.xml` shows author lastmod matching file mtime, not today (unless run on the same day the source was touched, in which case they tie — that's correct behavior).
- [ ] Codex code-diff review pass.
- [ ] Council coverage review pass.
- [ ] Codex grounded review on plan: PROCEED.
- [ ] Zero em/en-dashes in new code or docs.

## 14. Open questions

1. Should the `/tags/` early return be removed as dead code, or kept as forward-compatible scaffolding? Recommendation: keep, comment is still accurate (no tag pages exist).
2. Should we add a guard rail (test, CI script) so a future "author slug ≠ file" mismatch is caught at build time rather than silently falling through to today's date? Recommendation: out of scope for this fix; file as a follow-up if SEO drift recurs.

## 15. Related

- Parent PR: #732 (SEO audit fixes — schema, perf, content, CSP, www DNS).
- Sibling Codex finding: #740 (CSP omits comments host — separate fix, content-lane).
- Owner of the freshness contract: Codex grounded review on #732 introduced the mtime serializer; this issue closes the gap that review flagged.
