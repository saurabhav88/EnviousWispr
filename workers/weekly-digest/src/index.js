/**
 * EnviousWispr Weekly Digest — Cloudflare Worker
 * Runs every Monday 9am ET via cron trigger.
 * Pulls stats from Cloudflare Analytics, GitHub Releases, and PostHog,
 * then posts a formatted embed to Discord.
 */

export default {
  async scheduled(event, env) {
    await sendDigest(env);
  },

  // Manual trigger via HTTP for testing: curl <worker-url>
  async fetch(request, env) {
    await sendDigest(env);
    return new Response("Digest sent.");
  },
};

async function sendDigest(env) {
  const now = new Date();
  const weekEnd = now.toISOString().slice(0, 10);
  const weekStart = new Date(now - 7 * 86400000).toISOString().slice(0, 10);

  const [cf, gh, ph] = await Promise.all([
    fetchCloudflareStats(env, weekStart, weekEnd),
    fetchGitHubDownloads(env),
    fetchPostHogStats(env, weekStart, weekEnd),
  ]);

  const embed = buildEmbed(weekStart, weekEnd, cf, gh, ph);
  await postToDiscord(env.DISCORD_WEBHOOK_URL, embed);
}

// ── Cloudflare Analytics ──────────────────────────────────────

async function fetchCloudflareStats(env, dateFrom, dateTo) {
  const query = `query {
    viewer {
      zones(filter: {zoneTag: "${env.CF_ZONE_ID}"}) {
        totals: httpRequests1dGroups(
          limit: 7
          filter: {date_geq: "${dateFrom}", date_leq: "${dateTo}"}
        ) {
          sum { requests pageViews }
          uniq { uniques }
        }
        byDay: httpRequests1dGroups(
          limit: 7
          filter: {date_geq: "${dateFrom}", date_leq: "${dateTo}"}
        ) {
          dimensions { date }
          sum {
            pageViews
            countryMap { clientCountryName requests }
          }
        }
      }
    }
  }`;

  // NOTE: the former "Top Referrers" query (httpRequestsAdaptiveGroups { refererHost })
  // was removed (#1243): refererHost is rejected by the Cloudflare API on the zone
  // dataset (the valid field, clientRefererHost, is paid-only), so the section was
  // silently empty. Download attribution now comes from PostHog source_bucket — see
  // the "Download Sources" field built from fetchPostHogStats.
  const opts = {
    method: "POST",
    headers: {
      "X-Auth-Email": env.CF_EMAIL,
      "X-Auth-Key": env.CF_API_KEY,
      "Content-Type": "application/json",
    },
  };

  const mainRes = await fetch("https://api.cloudflare.com/client/v4/graphql", {
    ...opts,
    body: JSON.stringify({ query }),
  }).then((r) => r.json());

  const zone = mainRes?.data?.viewer?.zones?.[0];
  const totals = zone?.totals || [];
  const byDay = zone?.byDay || [];

  let totalRequests = 0, totalPageViews = 0, totalUniques = 0;
  const countries = {};

  for (const g of totals) {
    totalRequests += g.sum?.requests || 0;
    totalPageViews += g.sum?.pageViews || 0;
    totalUniques += g.uniq?.uniques || 0;
  }
  for (const g of byDay) {
    for (const c of g.sum?.countryMap || []) {
      countries[c.clientCountryName] = (countries[c.clientCountryName] || 0) + c.requests;
    }
  }

  const topCountries = Object.entries(countries)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  return { totalRequests, totalPageViews, totalUniques, topCountries };
}

// ── GitHub Release Downloads ──────────────────────────────────

async function fetchGitHubDownloads(env) {
  const headers = { "User-Agent": "EnviousWispr-Digest-Worker" };
  if (env.GITHUB_TOKEN) headers.Authorization = `token ${env.GITHUB_TOKEN}`;

  const res = await fetch(
    `https://api.github.com/repos/${env.GITHUB_REPO}/releases`,
    { headers }
  );
  if (!res.ok) return { totalDownloads: "?", latestVersion: "?" };

  const releases = await res.json();
  let totalDownloads = 0;
  let latestVersion = releases[0]?.tag_name || "?";

  for (const rel of releases) {
    for (const asset of rel.assets || []) {
      if (asset.name.endsWith(".dmg")) {
        totalDownloads += asset.download_count;
      }
    }
  }

  return { totalDownloads, latestVersion };
}

// ── PostHog Stats ─────────────────────────────────────────────

async function fetchPostHogStats(env, dateFrom, dateTo) {
  const apiKey = env.POSTHOG_PERSONAL_API_KEY;
  if (!apiKey) return { weeklyActiveUsers: "?", newUsers: "?", downloadIntents: "?", downloadSources: null, botExcluded: "?" };

  const headers = {
    Authorization: `Bearer ${apiKey}`,
    "Content-Type": "application/json",
  };

  // Weekly active users (production only — excludes dev dogfooding)
  const prodFilter = [{ key: "environment", operator: "exact", type: "event", value: "production" }];
  const wauQuery = {
    kind: "TrendsQuery",
    dateRange: { date_from: dateFrom, date_to: dateTo },
    interval: "week",
    properties: prodFilter,
    series: [
      { kind: "EventsNode", event: "app.launched", math: "dau", custom_name: "WAU" },
      { kind: "EventsNode", event: "app.launched", math: "first_time_for_user", custom_name: "New" },
    ],
  };

  // Download intents (7d) = on-site clicks + non-bot off-site doorway redirects.
  // HogQL (not TrendsQuery) because the union + bot-exclusion needs coalesce() on a
  // property; bare property names do NOT resolve in HogQL — must be properties.<name>.
  const intentsQuery = { kind: "HogQLQuery", query: downloadIntentsHogQL(dateFrom, dateTo) };
  // Off-site download sources (non-bot) grouped by canonical source_bucket.
  const sourcesQuery = { kind: "HogQLQuery", query: downloadSourcesHogQL(dateFrom, dateTo) };
  // Off-site bot hits excluded this week — integrity line (surfaces a bot surge OR
  // over-aggressive filtering).
  const botQuery = { kind: "HogQLQuery", query: botExcludedHogQL(dateFrom, dateTo) };

  // Website pageviews
  const pvQuery = {
    kind: "TrendsQuery",
    dateRange: { date_from: dateFrom, date_to: dateTo },
    interval: "week",
    series: [
      { kind: "EventsNode", event: "$pageview", math: "total", custom_name: "Website PVs" },
      { kind: "EventsNode", event: "$pageview", math: "dau", custom_name: "Website visitors" },
    ],
  };

  const queryUrl = `https://us.posthog.com/api/projects/${env.POSTHOG_PROJECT_ID}/query/`;

  const post = (query) =>
    fetch(queryUrl, { method: "POST", headers, body: JSON.stringify({ query }) })
      .then((r) => r.json())
      .catch(() => null);

  const [wauRes, pvRes, intentsRes, sourcesRes, botRes] = await Promise.all([
    post(wauQuery),
    post(pvQuery),
    post(intentsQuery),
    post(sourcesQuery),
    post(botQuery),
  ]);

  return {
    weeklyActiveUsers: extractTrendTotal(wauRes, 0),
    newUsers: extractTrendTotal(wauRes, 1),
    websitePageViews: extractTrendTotal(pvRes, 0),
    websiteVisitors: extractTrendTotal(pvRes, 1),
    downloadIntents: extractHogScalar(intentsRes),
    downloadSources: extractHogRows(sourcesRes),
    botExcluded: extractHogScalar(botRes),
  };
}

// ── Helpers (pure; exported for node --test) ──────────────────

// HogQL query builders. NOTE: every event-property ref MUST be properties.<name>
// (bare names do not resolve in PostHog HogQL). The union/bot predicate is the
// single shared DEFINITION (mirrored by the PostHog ping function; see
// .claude/knowledge/analytics-operations.md). #1243
export function downloadIntentsHogQL(dateFrom, dateTo) {
  return `SELECT count() FROM events WHERE toDate(timestamp) >= toDate('${dateFrom}') AND toDate(timestamp) <= toDate('${dateTo}') AND (event = 'download_clicked' OR (event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = ''))`;
}
export function downloadSourcesHogQL(dateFrom, dateTo) {
  return `SELECT properties.source_bucket AS bucket, count() AS n FROM events WHERE event = 'download_redirect' AND coalesce(properties.excluded_reason, '') = '' AND toDate(timestamp) >= toDate('${dateFrom}') AND toDate(timestamp) <= toDate('${dateTo}') GROUP BY bucket ORDER BY n DESC LIMIT 8`;
}
export function botExcludedHogQL(dateFrom, dateTo) {
  return `SELECT count() FROM events WHERE event = 'download_redirect' AND coalesce(properties.excluded_reason, '') != '' AND toDate(timestamp) >= toDate('${dateFrom}') AND toDate(timestamp) <= toDate('${dateTo}')`;
}

// TrendsQuery total extractor (aggregated_value or summed data array).
export function extractTrendTotal(res, seriesIdx = 0) {
  try {
    const series = res?.results?.[seriesIdx];
    if (!series) return "?";
    if (series.aggregated_value != null) return series.aggregated_value;
    if (Array.isArray(series.data)) return series.data.reduce((a, b) => a + b, 0);
    return "?";
  } catch {
    return "?";
  }
}

// HogQLQuery scalar (first cell of first row, e.g. a count()).
export function extractHogScalar(res) {
  try {
    const v = res?.results?.[0]?.[0];
    return v == null ? "?" : v;
  } catch {
    return "?";
  }
}

// HogQLQuery rows (array of [col0, col1, ...]). Returns null (NOT []) on a failed
// or malformed response, so a query error is distinguishable from a genuine empty
// week — a real empty array means "zero off-site downloads", null means "unknown".
export function extractHogRows(res) {
  return Array.isArray(res?.results) ? res.results : null;
}

// Canonical source_bucket -> human label for the digest (concise; the live ping
// uses its own slightly longer phrasing). Unknown/null -> "Other".
export const SOURCE_LABELS = {
  github_readme: "GitHub README",
  github_release: "GitHub",
  blog: "Blog",
  directory_alternativeto: "AlternativeTo",
  directory_macupdate: "MacUpdate",
  directory_other: "Directory listing",
  linkedin: "LinkedIn",
  reddit: "Reddit",
  x: "X",
  youtube: "YouTube",
  medium: "Medium",
  facebook: "Facebook",
  hackernews: "Hacker News",
  producthunt: "Product Hunt",
  discord: "Discord",
  ai_assistant: "AI assistant",
  newsletter: "Newsletter",
  direct_or_dark: "Direct / untracked",
  unknown_referrer: "Unrecognized site",
};
export function sourceLabel(bucket) {
  return (bucket && SOURCE_LABELS[bucket]) || "Other";
}

// Render the source-breakdown rows ([[bucket, n], ...]) for the embed.
// null (query failed/unknown) and [] (genuine zero) render differently so a
// telemetry outage never masquerades as a true zero-source week.
export function formatSourceBreakdown(rows) {
  if (rows == null || !Array.isArray(rows)) return "Sources unavailable";
  if (rows.length === 0) return "No off-site downloads yet";
  return rows
    .map(([bucket, n]) => `${sourceLabel(bucket)}: ${Number(n).toLocaleString()}`)
    .join("\n");
}

// ── Discord Embed ─────────────────────────────────────────────

export function buildEmbed(weekStart, weekEnd, cf, gh, ph) {
  const topCountriesStr = cf.topCountries
    .map(([name, count]) => `${name}: ${count.toLocaleString()}`)
    .join("\n") || "No data";

  const sourcesStr = formatSourceBreakdown(ph.downloadSources);

  return {
    embeds: [
      {
        title: `📊 EnviousWispr Weekly Digest`,
        description: `**${weekStart}** to **${weekEnd}**`,
        color: 0x7c3aed, // brand purple
        fields: [
          {
            name: "🌐 Website (Cloudflare)",
            value: [
              `**Unique Visitors:** ${cf.totalUniques.toLocaleString()}`,
              `**Page Views:** ${cf.totalPageViews.toLocaleString()}`,
              `**Total Requests:** ${cf.totalRequests.toLocaleString()}`,
            ].join("\n"),
            inline: true,
          },
          {
            name: "🌐 Website (PostHog)",
            value: [
              `**Tracked Visitors:** ${ph.websiteVisitors ?? "—"}`,
              `**Tracked Page Views:** ${ph.websitePageViews ?? "—"}`,
              `**Download Intents (7d):** ${ph.downloadIntents ?? "—"}`,
            ].join("\n"),
            inline: true,
          },
          {
            name: "\u200b",
            value: "\u200b",
            inline: false,
          },
          {
            name: "⬇️ Downloads",
            value: [
              `**All-Time DMG Downloads:** ${gh.totalDownloads.toLocaleString()}`,
              `**Latest Release:** ${gh.latestVersion}`,
            ].join("\n"),
            inline: true,
          },
          {
            name: "📱 App Usage (PostHog)",
            value: [
              `**Active Installs (7d):** ${ph.weeklyActiveUsers}`,
              `**New Users This Week:** ${ph.newUsers}`,
            ].join("\n"),
            inline: true,
          },
          {
            name: "\u200b",
            value: "\u200b",
            inline: false,
          },
          {
            name: "⬇️ Download Sources (7d)",
            value: `\`\`\`\n${sourcesStr}\n\`\`\`\nOff-site bots excluded: ${ph.botExcluded ?? "—"}`,
            inline: true,
          },
          {
            name: "🌍 Top Countries",
            value: `\`\`\`\n${topCountriesStr}\n\`\`\``,
            inline: true,
          },
        ],
        footer: {
          text: "EnviousWispr Weekly Digest • Cloudflare Worker",
        },
        timestamp: new Date().toISOString(),
      },
    ],
  };
}

// ── Discord Post ──────────────────────────────────────────────

async function postToDiscord(webhookUrl, payload) {
  await fetch(webhookUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
}
