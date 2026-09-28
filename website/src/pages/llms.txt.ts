// /llms.txt (llmstxt.org), built from the site's own sources so it cannot fall
// behind them. The hand-kept public/llms.txt it replaces listed 8 of 70 help
// articles, missed 7 blog posts and one guide page, and carried a Last-updated
// date two weeks older than its last edit. Features come from the catalog in
// data/site-navigation.js, help articles from the help collection in category
// order, blog posts from getPublishedPosts (so a future-dated post appears on the
// day it publishes), and Last-updated is the newest content date among them
// plus the comparison set's date (data/compare.js, the same date the sitemap
// uses). The homepage, the speech-to-text guide, the per-competitor pages and
// the legal pages carry no content date anywhere (seo-operations.md FACT:
// sitemap-and-robots), so they cannot move it.
// Only the summary, the comparison list and the fixed links are written by hand.
import { getCollection } from 'astro:content';
import { catalog } from '../data/site-navigation.js';
import { HELP_CATEGORIES } from '../data/help-categories';
import { BLOG_TOPICS } from '../data/blog-topics.js';
import { getPublishedPosts } from '../utils/posts';
import { updated as comparisonUpdated } from '../data/compare.js';

const SITE = 'https://enviouswispr.com';

// Pages whose catalog entry has no card line of its own.
const CATALOG_NOTES: Record<string, string> = {
  features: 'Every feature of the free Mac app, each on its own page.',
  privacy: 'What cloud dictation sends away, what EnviousWispr keeps local, and what goes out only if you choose cloud text polish.',
  customization: 'Record key, start and stop sounds, how text lands, and the overlay position.',
};

const COMPARISONS: [string, string, string][] = [
  ['best-dictation-apps-for-mac', 'Best dictation apps for Mac', 'A practical 2026 guide to seven Mac dictation options, with honest picks by workflow.'],
  ['wisprflow-alternatives', 'Wispr Flow alternatives', 'Nine alternatives ranked by price, privacy and offline support.'],
  ['wisprflow', 'vs Wispr Flow', 'Free and on-device versus a paid cloud subscription.'],
  ['superwhisper', 'vs Superwhisper', 'Both on-device, with different defaults and model coverage.'],
  ['apple-dictation', 'vs Apple Dictation', 'How EnviousWispr extends the dictation built into macOS.'],
  ['macwhisper', 'vs MacWhisper', 'Dictation and file transcription, with differences in AI cleanup, pricing and export.'],
  ['voiceink', 'vs VoiceInk', 'Two Mac dictation apps, head to head.'],
  ['fluidvoice', 'vs FluidVoice', 'Two Mac dictation apps compared on engines, languages and cleanup.'],
  ['handy', 'vs Handy', 'Two open-source dictation apps compared.'],
  ['spokenly', 'vs Spokenly', 'Two Mac dictation apps compared.'],
  ['typewhisper', 'vs TypeWhisper', 'Two Mac dictation apps compared on engines and cleanup.'],
  ['vox', 'vs Vox', 'Two Mac dictation apps compared.'],
  ['juno', 'vs Juno', 'Two Mac dictation apps compared.'],
  ['willow-voice', 'vs Willow Voice', 'A free on-device alternative to a cloud-first subscription.'],
  ['otter-ai', 'vs Otter.ai', 'Personal dictation versus meeting transcription.'],
  ['notta', 'vs Notta', 'Personal on-device dictation versus a cloud transcription service.'],
  ['dragon', 'vs Dragon', 'A modern on-device alternative to legacy desktop dictation.'],
  ['google-docs-voice-typing', 'vs Google Docs voice typing', 'System-wide dictation versus Docs-only voice typing.'],
  ['whisper-cpp', 'vs whisper.cpp', 'A finished Mac app versus a command-line library.'],
];

const line = (name: string, path: string, note?: string) => `- [${name}](${SITE}${path})${note ? `: ${note}` : ''}`;
const iso = (d: Date) => d.toISOString().slice(0, 10);

export async function GET() {
  const help = await getCollection('help');
  const posts = await getPublishedPosts();

  const dates = [
    comparisonUpdated,
    ...catalog.map((e) => e.updated),
    ...help.map((a) => iso(a.data.updated)),
    ...posts.map((p) => iso(p.data.updatedDate ?? p.data.pubDate)),
  ].sort();
  const lastUpdated = dates[dates.length - 1];

  const out: string[] = [
    '# EnviousWispr',
    '',
    '> Free, private voice-to-text for macOS. Hold a keybind, speak, release. Polished text lands on your clipboard or pastes directly. Transcription runs on-device with Parakeet (25 European languages) or WhisperKit (99+ languages). Optional AI polish can stay on-device with EG-1, Apple Intelligence, or a local Ollama model; Ollama also offers hosted models that run on its servers, and OpenAI, Gemini and Claude are optional bring-your-own-key cloud providers. No account, no subscription. Free download.',
    '',
    'Maker: Envious Labs LLC (Connecticut, USA). Founder: Saurabh Vaish.',
    'License: GNU General Public License v3 (GPLv3, open source on GitHub).',
    'Platform: macOS 14 (Sonoma) or later, Apple Silicon only.',
    `Last-updated: ${lastUpdated}`,
    '',
    '## Product',
    '',
    line('Homepage', '/', 'Download, core value proposition, system requirements (Apple Silicon, macOS 14+).'),
    line('Local speech to text on Mac', '/speech-to-text-mac/', 'How on-device transcription works on Apple Silicon: models, latency, offline behaviour and limits.'),
    line('Compare to alternatives', '/compare/', 'Side-by-side price, privacy and AI cleanup comparisons, plus the full comparison directory.'),
    '',
    '## Features',
    '',
    ...catalog.map((e) => line(e.name, e.path, e.cardBenefit ?? CATALOG_NOTES[e.slug])),
    '',
    '## Help',
    '',
    line('Help centre', '/help/', 'The full support library, searchable.'),
  ];

  for (const category of HELP_CATEGORIES) {
    const articles = help.filter((a) => a.data.category === category.slug).sort((a, b) => a.data.order - b.data.order);
    if (!articles.length) continue;
    out.push('', `### ${category.label}`, '', line(`${category.label} (category)`, `/help/${category.slug}/`, category.blurb));
    for (const a of articles) out.push(line(a.data.title, `/help/${a.id}/`, a.data.description));
  }

  out.push('', '## Comparisons', '');
  for (const [slug, name, note] of COMPARISONS) out.push(line(name, `/compare/${slug}/`, note));

  out.push('', '## Blog', '', line('Blog', '/blog/', 'All articles, newest first.'));
  for (const topic of BLOG_TOPICS) {
    const inTopic = posts.filter((p) => p.data.topic === topic.id);
    if (!inTopic.length) continue;
    out.push('', `### ${topic.label}`, '');
    for (const p of inTopic) out.push(line(p.data.title, `/blog/${p.id}/`, p.data.description));
  }
  const untopiced = posts.filter((p) => !BLOG_TOPICS.some((t) => t.id === p.data.topic));
  if (untopiced.length) {
    out.push('', '### More articles', '');
    for (const p of untopiced) out.push(line(p.data.title, `/blog/${p.id}/`, p.data.description));
  }

  out.push(
    '',
    '## About',
    '',
    line('Saurabh Vaish, founder', '/authors/saurabh-vaish/'),
    line('Contact', '/contact/'),
    line('Privacy policy', '/privacy-policy/'),
    line('Terms of service', '/terms-of-service/'),
    '- [GitHub repository](https://github.com/saurabhav88/EnviousWispr): Open source under GPLv3.',
    '',
  );

  return new Response(out.join('\n'), { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}
