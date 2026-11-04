/**
 * Shared run-log reader for the weekly digest (#3837 Ollama, #4353 cloud models).
 *
 * A weekly routine posts one receipt comment per run on a GitHub issue. This
 * reader owns everything the two digest sections share about reading that
 * issue: the request, the response checks, the exact writer filter and the
 * choice of the newest receipt by GitHub's own creation time.
 *
 * It does NOT own what a receipt looks like. Each section passes its own
 * `parse(body)`, which returns the parsed receipt, `null` for a comment that is
 * not a receipt, or throws for a comment its contract says must never exist.
 * The two receipt grammars, their tails and their presentation stay with their
 * sections in index.js.
 *
 * Policies that differ between the sections are explicit arguments, never
 * defaults chosen here:
 *   - `pages`: `{ mode: "single", since }` reads one page of comments UPDATED
 *     since `since` (GitHub's `since` filters on updated_at) and refuses a full
 *     page, because a full page could hide the newest receipt on page two.
 *     `{ mode: "all", maxPages }` reads every page and refuses a log longer
 *     than `maxPages` pages rather than truncating it.
 *   - `oldestMs`: comments CREATED before this are ignored, or `null` to keep
 *     the newest receipt however old it is.
 *
 * Freshness and selection use `created_at` only. GitHub keeps `created_at`
 * when a comment is edited, so an edit never makes an old receipt fresh;
 * `updated_at` and the date typed inside the receipt are never read here. A
 * comment created after `now` is not accepted.
 *
 * The token goes only on the requests this function builds, which are always
 * `https://api.github.com/repos/<repo>/issues/<issue>/comments`.
 */

export const RUN_LOG_PAGE_SIZE = 100;

const USER_AGENT = "EnviousWispr-Digest-Worker";

/**
 * @returns {Promise<{ createdMs: number, receipt: any } | null>} the newest
 *   accepted receipt, or null when none was accepted.
 */
export async function readNewestReceipt({
  fetchFn,
  repo,
  issue,
  token,
  login,
  now,
  oldestMs,
  pages,
  parse,
}) {
  if (typeof login !== "string" || login === "") {
    throw new TypeError("run-log reader needs the exact writer login");
  }
  if (typeof parse !== "function") throw new TypeError("run-log reader needs a parse function");
  if (!(now instanceof Date) || Number.isNaN(now.getTime())) {
    throw new TypeError("run-log reader needs a valid now");
  }
  if (oldestMs !== null && !Number.isFinite(oldestMs)) {
    throw new TypeError("run-log reader needs oldestMs as a number or null");
  }

  const headers = { "User-Agent": USER_AGENT };
  if (token) headers.Authorization = `token ${token}`;
  const base = `https://api.github.com/repos/${repo}/issues/${issue}/comments`;

  const comments = [];
  if (pages?.mode === "single") {
    const page = await readPage(
      fetchFn,
      `${base}?since=${encodeURIComponent(pages.since)}&per_page=${RUN_LOG_PAGE_SIZE}`,
      headers
    );
    // GitHub lists comments oldest first; a full page could hide the newest one
    // on page two, so a full page fails rather than guessing.
    if (page.length >= RUN_LOG_PAGE_SIZE) throw new Error("GitHub run-log comments filled a whole page");
    comments.push(...page);
  } else if (pages?.mode === "all" && Number.isSafeInteger(pages.maxPages) && pages.maxPages > 0) {
    let complete = false;
    for (let n = 1; n <= pages.maxPages; n += 1) {
      const page = await readPage(fetchFn, `${base}?per_page=${RUN_LOG_PAGE_SIZE}&page=${n}`, headers);
      comments.push(...page);
      if (page.length < RUN_LOG_PAGE_SIZE) {
        complete = true;
        break;
      }
    }
    // A log longer than the bound is refused, never read as its first pages:
    // the newest receipt is on the last page.
    if (!complete) throw new Error(`GitHub run-log comments exceeded ${pages.maxPages} pages`);
  } else {
    throw new TypeError("run-log reader needs an explicit pages policy");
  }

  let newest = null;
  for (const c of comments) {
    if (typeof c?.body !== "string" || typeof c?.created_at !== "string") {
      throw new Error("GitHub run-log comments returned a comment without body or created_at");
    }
    const created = Date.parse(c.created_at);
    if (Number.isNaN(created)) {
      throw new Error("GitHub run-log comments returned an unreadable created_at");
    }
    // Exact login only: a similar name, a missing user or another account is
    // never a receipt.
    if (c.user?.login !== login) continue;
    const receipt = parse(c.body);
    if (receipt === null) continue;
    if (created > now.getTime()) continue;
    if (oldestMs !== null && created < oldestMs) continue;
    if (newest === null || created > newest.createdMs) newest = { createdMs: created, receipt };
  }
  return newest;
}

async function readPage(fetchFn, url, headers) {
  const res = await fetchFn(url, { headers });
  if (!res.ok) throw new Error(`GitHub run-log comments HTTP ${res.status}`);
  const page = await res.json();
  if (!Array.isArray(page)) throw new Error("GitHub run-log comments returned a non-array");
  return page;
}
