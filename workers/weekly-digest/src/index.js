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

  // Separate query for referrers — uses httpRequestsAdaptiveGroups
  const refQuery = `query {
    viewer {
      zones(filter: {zoneTag: "${env.CF_ZONE_ID}"}) {
        httpRequestsAdaptiveGroups(
          limit: 10
          filter: {
            date_geq: "${dateFrom}"
            date_leq: "${dateTo}"
            requestSource: "eyeball"
          }
          orderBy: [count_DESC]
        ) {
          count
          dimensions { refererHost }
        }
      }
    }
  }`;

  const opts = {
    method: "POST",
    headers: {
      "X-Auth-Email": env.CF_EMAIL,
      "X-Auth-Key": env.CF_API_KEY,
      "Content-Type": "application/json",
    },
  };

  const [mainRes, refRes] = await Promise.all([
    fetch("https://api.cloudflare.com/client/v4/graphql", {
      ...opts,
      body: JSON.stringify({ query }),
    }).then((r) => r.json()),
    fetch("https://api.cloudflare.com/client/v4/graphql", {
      ...opts,
      body: JSON.stringify({ query: refQuery }),
    }).then((r) => r.json()),
  ]);

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

  // Top referrers
  const refZone = refRes?.data?.viewer?.zones?.[0];
  const refGroups = refZone?.httpRequestsAdaptiveGroups || [];
  const referrers = refGroups
    .filter((r) => r.dimensions?.refererHost && r.dimensions.refererHost !== "enviouswispr.com")
    .slice(0, 5)
    .map((r) => ({ host: r.dimensions.refererHost, count: r.count }));

  const topCountries = Object.entries(countries)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 5);

  return { totalRequests, totalPageViews, totalUniques, topCountries, referrers };
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
  if (!apiKey) return { weeklyActiveUsers: "?", newUsers: "?", downloadClicks: "?" };

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

  // Download button clicks on website (autocaptured link clicks to DMG)
  const clickQuery = {
    kind: "TrendsQuery",
    dateRange: { date_from: dateFrom, date_to: dateTo },
    interval: "week",
    series: [
      {
        kind: "EventsNode",
        event: "download_clicked",
        math: "total",
        custom_name: "Download clicks",
      },
    ],
  };

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

  const [wauRes, clickRes, pvRes] = await Promise.all([
    fetch(queryUrl, { method: "POST", headers, body: JSON.stringify({ query: wauQuery }) })
      .then((r) => r.json())
      .catch(() => null),
    fetch(queryUrl, { method: "POST", headers, body: JSON.stringify({ query: clickQuery }) })
      .then((r) => r.json())
      .catch(() => null),
    fetch(queryUrl, { method: "POST", headers, body: JSON.stringify({ query: pvQuery }) })
      .then((r) => r.json())
      .catch(() => null),
  ]);

  const extractTotal = (res, seriesIdx = 0) => {
    try {
      const series = res?.results?.[seriesIdx];
      if (!series) return "?";
      // aggregated_value can be null for weekly intervals; sum the data array instead
      if (series.aggregated_value != null) return series.aggregated_value;
      if (Array.isArray(series.data)) return series.data.reduce((a, b) => a + b, 0);
      return "?";
    } catch {
      return "?";
    }
  };

  return {
    weeklyActiveUsers: extractTotal(wauRes, 0),
    newUsers: extractTotal(wauRes, 1),
    downloadClicks: extractTotal(clickRes, 0),
    websitePageViews: extractTotal(pvRes, 0),
    websiteVisitors: extractTotal(pvRes, 1),
  };
}

// ── Discord Embed ─────────────────────────────────────────────

function buildEmbed(weekStart, weekEnd, cf, gh, ph) {
  const topCountriesStr = cf.topCountries
    .map(([name, count]) => `${name}: ${count.toLocaleString()}`)
    .join("\n") || "No data";

  const referrersStr = cf.referrers
    .map((r) => `${r.host}: ${r.count.toLocaleString()}`)
    .join("\n") || "Direct / none tracked";

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
              `**Download Clicks:** ${ph.downloadClicks ?? "—"}`,
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
            name: "🔗 Top Referrers",
            value: `\`\`\`\n${referrersStr}\n\`\`\``,
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
