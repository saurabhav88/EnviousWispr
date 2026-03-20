// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import cloudflare from '@astrojs/cloudflare';

const isDevServer = process.argv.includes('dev');

// Static lastmod dates for core pages (update when content changes significantly)
const CORE_PAGE_DATES = {
  'https://enviouswispr.com/': '2026-03-18',
  'https://enviouswispr.com/how-it-works/': '2026-03-18',
  'https://enviouswispr.com/blog/': '2026-03-18',
};

export default defineConfig({
  site: 'https://enviouswispr.com',
  output: 'static',
  adapter: isDevServer ? undefined : cloudflare(),
  integrations: [
    sitemap({
      serialize(item) {
        // Use static dates for core pages; for blog posts, Astro's sitemap
        // integration will pass the page URL — we use the static fallback.
        // Blog post pubDates are embedded in their JSON-LD; sitemap uses the
        // core date as a baseline until per-post date injection is wired up.
        const staticDate = CORE_PAGE_DATES[item.url];
        if (staticDate) {
          item.lastmod = staticDate;
        } else {
          // For blog posts: use a stable baseline rather than ever-changing build time
          item.lastmod = '2026-03-18';
        }
        return item;
      },
    }),
  ],
});
