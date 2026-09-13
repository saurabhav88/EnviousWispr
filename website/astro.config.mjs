// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { catalog } from "./src/data/site-navigation.js";
import { updated as comparisonUpdated } from "./src/data/compare.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE = "https://enviouswispr.com";

// Walk the blog frontmatter and pick max(updatedDate, pubDate) for each post.
const BLOG_POST_DATES = (() => {
  const blogDir = path.join(__dirname, "src/content/blog");
  const map = {};
  let latest = null;
  if (!fs.existsSync(blogDir)) return { map, latest };
  for (const file of fs.readdirSync(blogDir)) {
    if (!file.endsWith(".md") && !file.endsWith(".mdx")) continue;
    const content = fs.readFileSync(path.join(blogDir, file), "utf8");
    const pub = content.match(/^pubDate:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m);
    const upd = content.match(/^updatedDate:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m);
    const date = upd ? upd[1] : pub ? pub[1] : null;
    if (!date) continue;
    const slug = file.replace(/\.mdx?$/, "");
    map[`${SITE}/blog/${slug}/`] = date;
    if (!latest || date > latest) latest = date;
  }
  return { map, latest };
})();

// Help dates for EVERY help URL, not only articles.
//
// The failure this exists to prevent: a help URL without a mapped date used
// to fall through to a today's-date fallback. Articles carry `updated`, but the index and all twelve
// category pages have no date of their own — so thirteen pages would have
// claimed "modified today" on EVERY build, and deploy-blog.yml rebuilds the
// site on a daily cron. A daily false freshness signal teaches search engines
// to ignore our lastmod entirely.
//
// Categories take the latest `updated` among their own articles; the index
// takes the latest across all of them.
const HELP_DATES = (() => {
  const helpDir = path.join(__dirname, "src/content/help");
  const map = {};
  if (!fs.existsSync(helpDir)) return map;
  const perCategory = {};
  let latest = null;
  for (const file of fs.readdirSync(helpDir)) {
    if (!file.endsWith(".md")) continue;
    const content = fs.readFileSync(path.join(helpDir, file), "utf8");
    const cat = content.match(/^category:\s*["']?([a-z-]+)["']?/m)?.[1];
    const upd = content.match(
      /^updated:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m,
    )?.[1];
    if (!cat || !upd)
      throw new Error(`sitemap: ${file} is missing category or updated`);
    map[`${SITE}/help/${file.replace(/\.md$/, "")}/`] = upd;
    if (!perCategory[cat] || upd > perCategory[cat]) perCategory[cat] = upd;
    if (!latest || upd > latest) latest = upd;
  }
  for (const [cat, date] of Object.entries(perCategory))
    map[`${SITE}/help/${cat}/`] = date;
  if (latest) map[`${SITE}/help/`] = latest;
  return map;
})();

// Feature-launch dates (#2816): the nine catalog URLs carry an explicit
// `updated` date in src/data/site-navigation.js (imported, never parsed as
// text), the same discipline as help articles. They never fall through to mtime: a fresh checkout or the daily
// rebuild would otherwise publish today's date for pages nobody touched.
const FEATURE_DATES = Object.fromEntries(
  catalog.map((entry) => [`${SITE}${entry.path}`, entry.updated]),
);
if (Object.keys(FEATURE_DATES).length === 0)
  throw new Error("sitemap: no feature dates in site-navigation.js");
const isFeatureUrl = (url) =>
  url === `${SITE}/features/` ||
  url.startsWith(`${SITE}/features/`) ||
  url === `${SITE}/why-offline/` ||
  url === `${SITE}/customization/`;

export default defineConfig({
  site: SITE,
  output: "static",
  trailingSlash: "always",
  // Astro 7 ships Vite 8, which switched the default CSS minifier to Lightning
  // CSS. Lightning CSS prunes vendor prefixes against browser targets, and it
  // silently dropped two that this site's stylesheets ship on purpose:
  //
  //   -webkit-background-clip: text  Unprefixed `background-clip: text` only
  //     landed in Safari 18. EnviousWispr supports macOS 14, which ships
  //     Safari 17. Because `-webkit-text-fill-color: transparent` was KEPT,
  //     losing the prefix renders every gradient heading completely INVISIBLE
  //     on exactly the Macs we target.
  //
  //   backdrop-filter  It kept only the `-webkit-` form and dropped the
  //     standard property, which is the one Firefox implements, so the nav
  //     blur disappeared there.
  //
  // Declaring `browserslist` did not reach the minifier, and neither did
  // `css.lightningcss.targets` (Vite reads those only for the transformer, not
  // for `cssMinify`). Pinning the minifier back to esbuild — the pre-Vite-8
  // default, and what Astro 6 used — restores byte-identical prefix output:
  // verified 13 `-webkit-background-clip`, 1 standard `backdrop-filter`, and
  // 1 `-webkit-backdrop-filter`, matching the Astro 6 baseline exactly.
  //
  // Revisit if Lightning CSS target plumbing lands properly in Astro/Vite; it
  // minifies ~1% smaller. Correctness first.
  vite: {
    build: { cssMinify: "esbuild" },
  },
  integrations: [
    sitemap({
      serialize(item) {
        // Paginated archives have no reliable content-modification timestamp.
        if (/^https:\/\/enviouswispr\.com\/blog\/page\/\d+\/$/.test(item.url)) {
          delete item.lastmod;
          return item;
        }
        // A checkout or daily build must not turn mtime into a content update.
        if (
          [`${SITE}/compare/`, `${SITE}/compare/macwhisper/`].includes(item.url)
        ) {
          item.lastmod = comparisonUpdated;
          return item;
        }
        // Help: every help URL has a derived date. THROW rather than fall
        // through — a help URL reaching the today's-date fallback would
        // publish a false freshness signal on every daily rebuild, silently.
        if (
          item.url === `${SITE}/help/` ||
          item.url.startsWith(`${SITE}/help/`)
        ) {
          const helpDate = HELP_DATES[item.url];
          if (!helpDate) {
            throw new Error(
              `sitemap: help URL has no mapped lastmod: ${item.url}`,
            );
          }
          item.lastmod = helpDate;
          return item;
        }
        // Features launch pages: explicit catalog dates, fail closed.
        if (isFeatureUrl(item.url)) {
          const featureDate = FEATURE_DATES[item.url];
          if (!featureDate) {
            throw new Error(
              `sitemap: feature URL has no mapped lastmod: ${item.url}`,
            );
          }
          item.lastmod = featureDate;
          return item;
        }
        // Blog posts: use the frontmatter-driven date map.
        const blogDate = BLOG_POST_DATES.map[item.url];
        if (blogDate) {
          item.lastmod = blogDate;
          return item;
        }
        // Blog index: max of all post dates.
        if (item.url === `${SITE}/blog/`) {
          if (BLOG_POST_DATES.latest) {
            item.lastmod = BLOG_POST_DATES.latest;
            return item;
          }
        }
        // Everything else (legal, contact, compare pages without their own
        // date, authors): NO lastmod. The previous fallback was the source
        // file's mtime, and a CI checkout stamps every file with clone time,
        // so the daily rebuild published "modified today" for 27 unchanged
        // pages on every run. A wrong date is worse than none: search
        // engines that catch one bad lastmod stop trusting all of them,
        // including the real blog and help dates above.
        delete item.lastmod;
        return item;
      },
    }),
  ],
});
