// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SITE = 'https://enviouswispr.com';

// Format a Date or YYYY-MM-DD string as an ISO date (YYYY-MM-DD).
function toIsoDate(d) {
  if (!d) return null;
  if (typeof d === 'string') {
    const m = d.match(/^(\d{4}-\d{2}-\d{2})/);
    return m ? m[1] : null;
  }
  return new Date(d).toISOString().slice(0, 10);
}

// Walk the blog frontmatter and pick max(updatedDate, pubDate) for each post.
const BLOG_POST_DATES = (() => {
  const blogDir = path.join(__dirname, 'src/content/blog');
  const map = {};
  let latest = null;
  if (!fs.existsSync(blogDir)) return { map, latest };
  for (const file of fs.readdirSync(blogDir)) {
    if (!file.endsWith('.md') && !file.endsWith('.mdx')) continue;
    const content = fs.readFileSync(path.join(blogDir, file), 'utf8');
    const pub = content.match(/^pubDate:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m);
    const upd = content.match(/^updatedDate:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m);
    const date = upd ? upd[1] : (pub ? pub[1] : null);
    if (!date) continue;
    const slug = file.replace(/\.mdx?$/, '');
    map[`${SITE}/blog/${slug}/`] = date;
    if (!latest || date > latest) latest = date;
  }
  return { map, latest };
})();

// Help dates for EVERY help URL, not only articles.
//
// The failure this exists to prevent: `sourceForUrl` returns null for /help/…,
// so any help URL without a mapped date falls through to serialize's final
// `new Date()` fallback. Articles carry `updated`, but the index and all twelve
// category pages have no date of their own — so thirteen pages would have
// claimed "modified today" on EVERY build, and deploy-blog.yml rebuilds the
// site on a daily cron. A daily false freshness signal teaches search engines
// to ignore our lastmod entirely.
//
// Categories take the latest `updated` among their own articles; the index
// takes the latest across all of them.
const HELP_DATES = (() => {
  const helpDir = path.join(__dirname, 'src/content/help');
  const map = {};
  if (!fs.existsSync(helpDir)) return map;
  const perCategory = {};
  let latest = null;
  for (const file of fs.readdirSync(helpDir)) {
    if (!file.endsWith('.md')) continue;
    const content = fs.readFileSync(path.join(helpDir, file), 'utf8');
    const cat = content.match(/^category:\s*["']?([a-z-]+)["']?/m)?.[1];
    const upd = content.match(/^updated:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m)?.[1];
    if (!cat || !upd) throw new Error(`sitemap: ${file} is missing category or updated`);
    map[`${SITE}/help/${file.replace(/\.md$/, '')}/`] = upd;
    if (!perCategory[cat] || upd > perCategory[cat]) perCategory[cat] = upd;
    if (!latest || upd > latest) latest = upd;
  }
  for (const [cat, date] of Object.entries(perCategory)) map[`${SITE}/help/${cat}/`] = date;
  if (latest) map[`${SITE}/help/`] = latest;
  return map;
})();

// File mtime → ISO date for any source path on disk.
function mtimeIso(absPath) {
  try {
    return fs.statSync(absPath).mtime.toISOString().slice(0, 10);
  } catch {
    return null;
  }
}

// Map a sitemap URL to its source .astro file path on disk.
function sourceForUrl(url) {
  // Strip site prefix and trailing slash.
  let p = url.replace(SITE, '').replace(/\/$/, '');
  if (p === '') p = '/index';
  // Author pages: /authors/<slug>/ → src/pages/authors/<slug>.astro (static file). Trailing slash already stripped at line 53.
  if (p.startsWith('/authors/')) {
    const slug = p.replace('/authors/', '');
    return path.join(__dirname, `src/pages/authors/${slug}.astro`);
  }
  // Tag pages: /tags/<slug>/ → no static source on disk today. Forward-compatible scaffolding.
  if (p.startsWith('/tags/')) return null;
  // /blog/<slug>/ → handled by BLOG_POST_DATES.
  if (p.startsWith('/blog/') && p !== '/blog') return null;
  // /blog/ index → src/pages/blog/index.astro
  if (p === '/blog') return path.join(__dirname, 'src/pages/blog/index.astro');
  // /compare/ index → src/pages/compare/index.astro
  if (p === '/compare') return path.join(__dirname, 'src/pages/compare/index.astro');
  // /compare/<slug>/ → src/pages/compare/<slug>.astro
  if (p.startsWith('/compare/')) {
    const slug = p.replace('/compare/', '');
    return path.join(__dirname, `src/pages/compare/${slug}.astro`);
  }
  // /solutions/ index → src/pages/solutions/index.astro
  if (p === '/solutions') return path.join(__dirname, 'src/pages/solutions/index.astro');
  // /solutions/<slug>/ → src/pages/solutions/<slug>.astro
  if (p.startsWith('/solutions/')) {
    const slug = p.replace('/solutions/', '');
    return path.join(__dirname, `src/pages/solutions/${slug}.astro`);
  }
  // /index → src/pages/index.astro
  if (p === '/index') return path.join(__dirname, 'src/pages/index.astro');
  // /<page>/ → src/pages/<page>.astro
  const slug = p.replace(/^\//, '');
  return path.join(__dirname, `src/pages/${slug}.astro`);
}

export default defineConfig({
  site: SITE,
  output: 'static',
  trailingSlash: 'always',
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
    build: { cssMinify: 'esbuild' },
  },
  integrations: [
    sitemap({
      serialize(item) {
        // Help: every help URL has a derived date. THROW rather than fall
        // through — a help URL reaching the today's-date fallback would
        // publish a false freshness signal on every daily rebuild, silently.
        if (item.url === `${SITE}/help/` || item.url.startsWith(`${SITE}/help/`)) {
          const helpDate = HELP_DATES[item.url];
          if (!helpDate) {
            throw new Error(`sitemap: help URL has no mapped lastmod: ${item.url}`);
          }
          item.lastmod = helpDate;
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
        // Static pages: use the source file mtime on disk.
        const src = sourceForUrl(item.url);
        if (src) {
          const mtime = mtimeIso(src);
          if (mtime) {
            item.lastmod = mtime;
            return item;
          }
        }
        // Final fallback: today's date.
        item.lastmod = new Date().toISOString().slice(0, 10);
        return item;
      },
    }),
  ],
});
