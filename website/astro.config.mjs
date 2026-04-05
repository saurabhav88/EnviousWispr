// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Static lastmod dates for core pages (update when content changes significantly)
const CORE_PAGE_DATES = {
  'https://enviouswispr.com/': '2026-03-18',
  'https://enviouswispr.com/how-it-works/': '2026-03-18',
  'https://enviouswispr.com/blog/': '2026-03-18',
};

// Build a URL→pubDate map by reading blog post frontmatter at config time.
// Regex-parses only the pubDate field — no external dep needed.
const BLOG_POST_DATES = (() => {
  const blogDir = path.join(__dirname, 'src/content/blog');
  const map = {};
  if (!fs.existsSync(blogDir)) return map;
  for (const file of fs.readdirSync(blogDir)) {
    if (!file.endsWith('.md') && !file.endsWith('.mdx')) continue;
    const content = fs.readFileSync(path.join(blogDir, file), 'utf8');
    const match = content.match(/^pubDate:\s*["']?(\d{4}-\d{2}-\d{2})["']?/m);
    if (!match) continue;
    const slug = file.replace(/\.mdx?$/, '');
    map[`https://enviouswispr.com/blog/${slug}/`] = match[1];
  }
  return map;
})();

export default defineConfig({
  site: 'https://enviouswispr.com',
  output: 'static',
  trailingSlash: 'always',
  integrations: [
    sitemap({
      serialize(item) {
        const staticDate = CORE_PAGE_DATES[item.url];
        if (staticDate) {
          item.lastmod = staticDate;
          return item;
        }
        const blogDate = BLOG_POST_DATES[item.url];
        if (blogDate) {
          item.lastmod = blogDate;
          return item;
        }
        // Fallback for any pages not covered above
        item.lastmod = '2026-03-18';
        return item;
      },
    }),
  ],
});
