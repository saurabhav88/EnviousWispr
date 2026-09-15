// Cloudflare Pages Function — the /download doorway.
// Records where a download came from (server-side, ad-blocker-proof), then
// 302-redirects to the latest GitHub .dmg.
//
// HEART PATH = the redirect. It ALWAYS happens, even if telemetry throws.
// Telemetry is a fire-and-forget limb (ctx.waitUntil + swallowed errors).
//
// Plan: docs/feature-requests/plan-2026-06-29-download-attribution.md (§3, §3d)
// for the off-site buckets; #2953 for the on-site path.
//
// Since #2953 EVERY download passes through here and this redirect is the one
// download record (workers/shared/download-intent.js). Off-site owned links
// (README, directories, profile bios, social posts) carry ?source=<bucket>;
// every on-site button carries ?source=onsite plus &placement=<button>, which
// the page script writes into the link on click. The browser emits no download
// event of its own any more: this fires even when the tracker never loaded, it
// carries the real IP for country and the User-Agent for platform, and when the
// visitor's first-party PostHog cookie is present it carries the SAME
// distinct_id and session id as the page views, so a download joins the visit
// that produced it.

const DMG_URL =
  "https://github.com/saurabhav88/EnviousWispr/releases/latest/download/EnviousWispr.dmg";
const POSTHOG_HOST = "https://us.i.posthog.com";
// Public PostHog project key — the same client key already embedded in the website
// (BaseLayout.astro). Safe to expose; it is a write-only ingest key.
const POSTHOG_PUBLIC_KEY = "phc_W1N51z2mqKZGo8UxBYQ5avkpjpJ3npT8retNQUaRSKk";

// Canonical source buckets (§3d). Extend only deliberately.
const KNOWN_BUCKETS = new Set([
  "github_readme", "github_release", "blog",
  "directory_alternativeto", "directory_macupdate", "directory_other",
  "linkedin", "reddit", "x", "youtube", "medium", "facebook", "hackernews",
  "producthunt", "discord", "ai_assistant", "newsletter",
  "direct_or_dark", "unknown_referrer", "bot_filtered",
  "onsite", // #2953: every on-site button, with &placement=<button> stamped on click
]);

// Link-preview scanners, crawlers, and non-browser agents. GET hits from these are
// captured but tagged excluded_reason='bot_ua' so the KPI can exclude them while we
// retain audit visibility. (Cloudflare's own request analytics counts the full,
// incl-bot volume separately — this is just the PostHog-side hygiene.)
//
// Match crawler/fetcher SIGNATURES, not bare app names. Real preview fetchers carry
// "bot"/"crawl" (Discordbot, TelegramBot, Slackbot, redditbot, twitterbot, ...) so the
// generic tokens already cover them, plus the non-"bot" fetchers named explicitly. We
// deliberately do NOT match bare "discord"/"slack"/"whatsapp"/"telegram"/"pinterest":
// those also appear in the UAs of real humans clicking from an in-app WebView, and
// tagging them bot would lose real downloads — the very off-site clicks this doorway
// exists to count. (Cloud review, PR #1240.)
const BOT_UA =
  /bot|crawl|spider|slurp|facebookexternalhit|bingpreview|embedly|vkshare|preview|scanner|monitor|curl|wget|python-requests|headless|w3c_validator/i;

// Exported for unit testing the bot heuristic without the Cloudflare runtime.
export function isLikelyBot(ua) {
  return BOT_UA.test(ua || "");
}

// PostHog's browser SDK persists `{distinct_id, $sesid: [lastActivityMs,
// sessionId, startMs], ...}` as encodeURIComponent(JSON) in the first-party
// cookie `ph_<project key>_posthog` (posthog-js storage.ts / sessionid.ts).
// A same-origin request to /download carries it, so the doorway can stamp the
// redirect with the visitor and session the page views already use (#2953).
//
// The cookie is client-writable, so every value is treated as an opaque id:
// bounded in length, never branched on, never logged. Identity and session are
// independent: a visitor whose session idled out still keeps their distinct id;
// the session id is dropped when its tuple is missing, malformed, idle for more
// than the SDK's 30-minute timeout, or older than its 24-hour ceiling. Any
// failure at all returns null and the caller falls back to the anonymous id.
const SESSION_IDLE_MS = 30 * 60_000;
const SESSION_MAX_MS = 24 * 60 * 60_000;
const COOKIE_MAX_LENGTH = 4096;
const ID_MAX_LENGTH = 256;

export function identityFromCookie(cookieHeader, key, nowMs) {
  try {
    const prefix = `ph_${key}_posthog=`;
    const entry = (cookieHeader || "")
      .split(";")
      .map((v) => v.trim())
      .find((v) => v.startsWith(prefix));
    if (!entry) return null;
    const raw = entry.slice(prefix.length);
    if (raw.length === 0 || raw.length > COOKIE_MAX_LENGTH) return null;
    const value = JSON.parse(decodeURIComponent(raw));
    const validId = (v) => typeof v === "string" && v.length > 0 && v.length <= ID_MAX_LENGTH;
    if (!validId(value?.distinct_id)) return null;
    const s = value.$sesid;
    const start = s?.[2] ?? s?.[0];
    const validTime = (v) => Number.isFinite(v) && v > 0;
    const validSession =
      Array.isArray(s) &&
      validId(s[1]) &&
      validTime(nowMs) &&
      validTime(s[0]) &&
      validTime(start) &&
      Math.abs(nowMs - s[0]) <= SESSION_IDLE_MS &&
      Math.abs(nowMs - start) <= SESSION_MAX_MS;
    return { distinctId: value.distinct_id, sessionId: validSession ? s[1] : null };
  } catch {
    return null;
  }
}

// The page an on-site click came from, as a pathname (the same shape as the
// tracker's $pathname). Only a Referer on the request's own origin is a page of
// ours; an off-site referrer's path is not, and returns null.
export function pageFromReferer(referer, requestUrl) {
  try {
    if (!referer) return null;
    const ref = new URL(referer);
    return ref.origin === new URL(requestUrl).origin ? ref.pathname : null;
  } catch {
    return null;
  }
}

// The on-site button that was pressed, as written by the page script; null
// when absent or not a plain token. Enumerated by the data-download-source
// attributes and the fallback list in SiteServices.astro.
export function placementFromQuery(value) {
  return typeof value === "string" && /^[a-z0-9-]{1,40}$/.test(value) ? value : null;
}

// Coarse platform from the User-Agent so the download notification can say
// "Mac OS X / Safari" for a redirect the way the browser event used to.
// Returns nulls, never guesses, when nothing matches.
export function platformFromUserAgent(ua) {
  const s = String(ua || "");
  let os = null;
  if (/iPhone|iPad|iPod/.test(s)) os = "iOS";
  else if (/Android/.test(s)) os = "Android";
  else if (/Mac OS X|Macintosh/.test(s)) os = "Mac OS X";
  else if (/Windows/.test(s)) os = "Windows";
  else if (/CrOS/.test(s)) os = "Chrome OS";
  else if (/Linux/.test(s)) os = "Linux";
  let browser = null;
  if (/Edg\//.test(s)) browser = "Microsoft Edge";
  else if (/OPR\/|Opera/.test(s)) browser = "Opera";
  else if (/Firefox\//.test(s)) browser = "Firefox";
  else if (/Chrome\/|CriOS\//.test(s)) browser = "Chrome";
  else if (/Safari\//.test(s) && /Version\//.test(s)) browser = "Safari";
  return { os, browser };
}

// First language tag of Accept-Language, the same shape as $browser_language.
export function languageFromHeader(value) {
  const first = String(value || "").split(",")[0].trim().split(";")[0].trim();
  return /^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(first) ? first : null;
}

function refHost(referer) {
  try {
    return referer ? new URL(referer).hostname.toLowerCase() : null;
  } catch {
    return null;
  }
}

// $referring_domain -> bucket
function bucketFromReferrer(host) {
  if (!host) return null;
  if (/(^|\.)(chatgpt\.com|openai\.com|perplexity\.ai|claude\.ai)$|^gemini\.google\.com$|^copilot\.microsoft\.com$/.test(host)) return "ai_assistant";
  if (/(^|\.)reddit\.com$/.test(host)) return "reddit";
  if (/(^|\.)linkedin\.com$/.test(host)) return "linkedin";
  if (/(^|\.)(x\.com|twitter\.com)$|^t\.co$/.test(host)) return "x";
  if (/(^|\.)youtube\.com$|^youtu\.be$/.test(host)) return "youtube";
  if (/(^|\.)medium\.com$/.test(host)) return "medium";
  if (/(^|\.)facebook\.com$/.test(host)) return "facebook";
  if (/^news\.ycombinator\.com$/.test(host)) return "hackernews";
  if (/(^|\.)producthunt\.com$/.test(host)) return "producthunt";
  if (/(^|\.)github\.com$/.test(host)) return "github_release";
  if (/(^|\.)alternativeto\.net$/.test(host)) return "directory_alternativeto";
  if (/(^|\.)macupdate\.com$/.test(host)) return "directory_macupdate";
  return "unknown_referrer";
}

// utm_source / utm_medium -> bucket (null = fall through to referrer)
function bucketFromUtm(utmSource, utmMedium) {
  const s = (utmSource || "").toLowerCase();
  const m = (utmMedium || "").toLowerCase();
  if (!s && !m) return null;
  if (m === "email" || /newsletter|substack|beehiiv|mailchimp|buttondown|ghost|convertkit|^kit$/.test(s)) return "newsletter";
  if (/chatgpt|openai|perplexity|claude|gemini|copilot/.test(s)) return "ai_assistant";
  if (s === "reddit") return "reddit";
  if (s === "linkedin") return "linkedin";
  if (s === "twitter" || s === "x") return "x";
  if (s === "youtube") return "youtube";
  if (s === "medium") return "medium";
  if (s === "github") return "github_readme";
  return null;
}

// Pure resolver — exported for unit testing without the Cloudflare runtime.
export function resolveSourceBucket({ isBot, explicit, utmSource, utmMedium, referrerHost }) {
  if (isBot) return { bucket: "bot_filtered", excludedReason: "bot_ua" };
  if (explicit && KNOWN_BUCKETS.has(explicit)) return { bucket: explicit, excludedReason: null };
  const bucket =
    bucketFromUtm(utmSource, utmMedium) ||
    bucketFromReferrer(referrerHost) ||
    (referrerHost ? "unknown_referrer" : "direct_or_dark");
  return { bucket, excludedReason: null };
}

export async function onRequest(context) {
  const { request } = context;

  // HEART PATH: the redirect. Build it first so nothing below can block it.
  const resp = new Response(null, {
    status: 302, // 302, never 301 — a permanent redirect would cache and freeze the target
    headers: { Location: DMG_URL, "Cache-Control": "no-store" },
  });

  try {
    // Only GET is counted. HEAD/OPTIONS/other = probes → redirect, no event.
    if (request.method !== "GET") return resp;

    const url = new URL(request.url);
    const q = url.searchParams;
    const ua = request.headers.get("User-Agent") || "";
    const referer = request.headers.get("Referer") || "";
    const referrerHost = refHost(referer);

    const explicit = (q.get("source") || "").toLowerCase();
    const utmSource = q.get("utm_source");
    const utmMedium = q.get("utm_medium");

    const { bucket, excludedReason } = resolveSourceBucket({
      isBot: isLikelyBot(ua),
      explicit,
      utmSource,
      utmMedium,
      referrerHost,
    });

    // #2953: the visitor's own id and session when the first-party cookie is
    // present; the anonymous fallback otherwise. Profile processing follows the
    // identity: an anonymous fallback must never create a person.
    const identity = identityFromCookie(request.headers.get("Cookie"), POSTHOG_PUBLIC_KEY, Date.now());
    const platform = platformFromUserAgent(ua);

    const event = {
      api_key: POSTHOG_PUBLIC_KEY,
      event: "download_redirect",
      distinct_id: identity ? identity.distinctId : "anon-" + crypto.randomUUID(),
      properties: {
        app: "enviouswispr",
        source: explicit || null,
        source_bucket: bucket,
        method: request.method,
        excluded_reason: excludedReason,
        known_updater: false, // Sparkle uses versioned GitHub URLs, never /download
        utm_source: utmSource,
        utm_medium: utmMedium,
        utm_campaign: q.get("utm_campaign"),
        utm_content: q.get("utm_content"),
        $referrer: referer || "$direct",
        $referring_domain: referrerHost || "$direct",
        $current_url: url.toString(),
        // #2953: the on-site record. `page` matches the tracker's $pathname so a
        // session can put the download beside the page views that led to it.
        page: pageFromReferer(referer, request.url),
        placement: placementFromQuery(q.get("placement")),
        $os: platform.os,
        $browser: platform.browser,
        $browser_language: languageFromHeader(request.headers.get("Accept-Language")),
        $ip: request.headers.get("CF-Connecting-IP") || undefined, // real user IP for GeoIP, not CF egress
        // #2953: attach to the visitor's person when we have their id (the site
        // runs person_profiles:'always'); never mint a person for an anon hit.
        $process_person_profile: Boolean(identity),
        ...(identity?.sessionId ? { $session_id: identity.sessionId } : {}),
      },
    };

    // Fire-and-forget. Never block or fail the redirect on telemetry.
    context.waitUntil(
      fetch(`${POSTHOG_HOST}/capture/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(event),
      }).catch(() => {})
    );
  } catch {
    // Swallow — fail open. The user always gets the download.
  }

  return resp;
}
