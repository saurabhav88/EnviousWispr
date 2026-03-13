// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import cloudflare from '@astrojs/cloudflare';

const isDevServer = process.argv.includes('dev');

export default defineConfig({
  site: 'https://enviouswispr.com',
  output: 'static',
  adapter: isDevServer ? undefined : cloudflare(),
  integrations: [
    sitemap(),
  ],
});
