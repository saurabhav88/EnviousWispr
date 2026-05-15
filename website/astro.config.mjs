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
  // Author pages: /authors/<slug>/ → dynamic route, no single source file. Skip.
  if (p.startsWith('/authors/')) return null;
  // Tag pages: /tags/<slug>/ → dynamic route. Skip.
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
  integrations: [
    sitemap({
      serialize(item) {
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
