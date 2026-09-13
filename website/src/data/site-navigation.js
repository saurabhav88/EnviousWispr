// One catalog for the site's navigation and the features launch (#2816).
//
// Every consumer derives from this file: the shared header and footer, the
// features directory cards, the ItemList structured data, the sitemap's
// FEATURE_DATES map in astro.config.mjs, and scripts/check-features.mjs.
// A page's `updated` date is bumped by hand with any content change to that
// page or the data module it renders; the sitemap never falls back to file
// times for these URLs (a fresh checkout or the daily rebuild would otherwise
// publish a false freshness signal).

export const githubUrl = 'https://github.com/saurabhav88/EnviousWispr';
export const downloadUrl = `${githubUrl}/releases/latest/download/EnviousWispr.dmg`;

export const catalog = [
  {
    slug: 'features',
    path: '/features/',
    name: 'Features',
    updated: '2026-09-12',
    menuFoot: 'Explore all features',
  },
  {
    slug: 'dictation',
    path: '/features/dictation/',
    name: 'AI Polished Dictation',
    menuTagline: 'Tuned for accurate, polished writing.',
    cardBenefit: 'Keep your meaning. Lose the verbal clutter.',
    heroTagline: 'Voice to finished writing',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'file-transcription',
    path: '/features/file-transcription/',
    name: 'File Transcription',
    menuTagline: 'Long recordings. Readable text.',
    cardBenefit: 'Your audio and video files, transcribed and polished.',
    heroTagline: 'A transcript is only the beginning',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'dictionary',
    path: '/features/dictionary/',
    name: 'Dictionary',
    menuTagline: 'Your vocabulary, spelled your way.',
    cardBenefit: 'Your names and specialist words, spelled your way.',
    heroTagline: 'Get your words right',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'snippets',
    path: '/features/snippets/',
    name: 'Snippets',
    menuTagline: 'Saved text, a spoken phrase away.',
    cardBenefit: 'Your saved text, a short spoken phrase away.',
    heroTagline: 'Say less. Reuse more.',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'live-preview',
    path: '/features/live-preview/',
    name: 'Live Preview',
    menuTagline: 'See your words as you speak.',
    cardBenefit: 'Keep your thought in view as you speak.',
    heroTagline: 'Keep your thought in view',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'history',
    path: '/features/history/',
    name: 'History',
    menuTagline: 'Read, copy and recover transcripts.',
    cardBenefit: 'Read, copy and recover your transcripts.',
    heroTagline: 'Your words, kept close',
    updated: '2026-09-12',
    menuProduct: true,
  },
  {
    slug: 'privacy',
    path: '/why-offline/',
    name: 'Why Offline?',
    updated: '2026-09-12',
    headerLink: true,
  },
  {
    slug: 'customization',
    path: '/customization/',
    name: 'Make it yours',
    updated: '2026-09-12',
    menuFoot: 'Make it yours',
  },
];

export const menuProducts = catalog.filter((entry) => entry.menuProduct);
export const menuFoot = catalog.filter((entry) => entry.menuFoot);
export const headerLinks = catalog.filter((entry) => entry.headerLink);
export const itemList = catalog.filter((entry) => entry.slug !== 'features');

export const resources = [
  ['Blog', '/blog/'],
  ['Help', '/help/'],
  ['Contact', '/contact/'],
];

export const footerLinks = catalog
  .filter((entry) => entry.slug === 'features' || entry.headerLink || entry.slug === 'customization')
  .map((entry) => [entry.name, entry.path]);

export function byPath(pathname) {
  return catalog.find((entry) => entry.path === pathname);
}
