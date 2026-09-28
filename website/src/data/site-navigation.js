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
// #2953: every on-site download goes through the /download doorway, which
// records the download server-side (with the visitor's own cookie id and the
// page it came from) and then redirects to the latest GitHub DMG. The raw DMG
// URL is no longer a click target anywhere on the site; the JSON-LD in
// StructuredData.astro keeps it as the schema's downloadUrl.
export const downloadUrl = '/download?source=onsite';

export const catalog = [
  {
    slug: 'features',
    path: '/features/',
    name: 'Features',
    updated: '2026-09-28',
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
    updated: '2026-09-27',
    menuProduct: true,
  },
  {
    slug: 'self-learning-dictionary',
    path: '/features/self-learning-dictionary/',
    name: 'Self-Learning Dictionary',
    menuTagline: 'Learns from the words you fix.',
    cardBenefit: 'Correct a misheard word once, and later dictations can use your spelling.',
    heroTagline: 'Learns from your fixes',
    updated: '2026-09-27',
    menuProduct: true,
  },
  {
    slug: 'snippets',
    path: '/features/snippets/',
    name: 'Snippets',
    menuTagline: 'Saved text, a spoken phrase away.',
    cardBenefit: 'Your saved text, a short spoken phrase away.',
    heroTagline: 'Say less. Reuse more.',
    updated: '2026-09-27',
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
    slug: 'paste-last-dictation',
    path: '/features/paste-last-dictation/',
    name: 'Paste Last Dictation',
    menuTagline: 'Missed the text box? Paste it again.',
    cardBenefit: 'Missed the text box? Paste your last dictation again with one shortcut.',
    heroTagline: 'Never say it twice',
    updated: '2026-09-28',
    menuProduct: true,
  },
  {
    slug: 'smart-formatting',
    path: '/features/smart-formatting/',
    name: 'Smart Formatting',
    menuTagline: 'Numbers, links and code, written out.',
    cardBenefit: 'Versions, addresses, dates and slash commands, written the way you type them.',
    heroTagline: 'Say it, get it formatted',
    updated: '2026-09-28',
    menuProduct: true,
  },
  {
    slug: 'languages',
    path: '/features/languages/',
    name: 'Languages',
    menuTagline: 'Dictate in your language.',
    cardBenefit: 'Dictate in 25 languages with Parakeet or 99+ with WhisperKit, with British spelling too.',
    heroTagline: 'Your language, your spelling',
    updated: '2026-09-28',
    menuProduct: true,
  },
  {
    slug: 'privacy',
    path: '/why-offline/',
    name: 'Why Offline?',
    updated: '2026-09-28',
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
