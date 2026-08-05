import type { APIRoute } from 'astro';
import { getHelpArticles, categoryOf } from '../utils/help';
import type { HelpDoc } from '../utils/help-search';

/**
 * Build-time search corpus. A static asset, fetched once when a reader first
 * opens search, so every query is evaluated in their browser and no query text
 * ever leaves it.
 *
 * Documents are shipped rather than a pre-serialized MiniSearch index: at this
 * corpus size building in the browser costs a couple of milliseconds, the
 * payload is smaller, and nothing couples a stored format to a library version.
 */
export const GET: APIRoute = async () => {
  const articles = await getHelpArticles();

  const docs: HelpDoc[] = articles.map((a) => {
    const category = categoryOf(a);
    return {
      id: a.id,
      title: a.data.title,
      description: a.data.description,
      category: category.slug,
      categoryLabel: category.label,
      section: a.data.section,
      // Space-joined so MiniSearch tokenises synonyms the same way it does prose.
      keywords: a.data.keywords.join(' '),
      headings: headingsOf(a.body ?? ''),
      body: plainText(a.body ?? ''),
    };
  });

  return new Response(JSON.stringify(docs), {
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
};

/** `### Heading` lines, joined. Boosted above body text in ranking. */
function headingsOf(markdown: string): string {
  return (markdown.match(/^#{2,4}\s+(.*)$/gm) ?? [])
    .map((h) => h.replace(/^#{2,4}\s+/, ''))
    .join(' ');
}

/** Inline Markdown syntax, matched in one alternation so a single pass can
 *  decide what each construct becomes. Order matters: the escape alternative
 *  is first, so `\_` is consumed as a literal underscore before the emphasis
 *  rule can see the underscore at all. */
const INLINE = new RegExp(
  [
    '\\\\([\\\\`*_\\[\\]<>|#+.-])', // 1: an escaped literal
    '\\[([^\\]]*)\\]\\([^)]*\\)', // 2: a link, keep its text
    '(`+)([^`]*)\\3', // 3/4: a code span, keep its contents
    '\\*\\*', // bold markers
    '(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])', // emphasis markers
  ].join('|'),
  'g'
);

/**
 * Markdown reduced to plain text for indexing and snippets.
 *
 * Two traps, both learned the expensive way while building the conversion gate:
 *
 * At most ONE leading block marker is removed per line. Stripping headings and
 * then numbers globally eats the literal "1." out of a heading that reads
 * "### 1. Get closer to the microphone".
 *
 * Escapes are resolved in the SAME left-to-right pass as the marker stripping,
 * not before or after it. Unescaping first lets the emphasis rule eat a real
 * underscore; unescaping last lets it eat the backslash and leave the
 * underscore. An earlier draft parked escapes behind a numeric sentinel, which
 * works but can collide with the digits this corpus is full of. One pass has no
 * sentinel and so no collision surface.
 */
function plainText(markdown: string): string {
  const text = markdown
    .split('\n')
    .filter((l) => !/^\s*\|[\s|:-]+\|\s*$/.test(l))
    .map((l) => l.replace(/^\s*(?:#{2,4}\s+|[-+]\s+|\d+\.\s+)/, ''))
    .join('\n')
    .replace(INLINE, (_match, escaped?: string, linkText?: string, _fence?: string, code?: string) => {
      if (escaped !== undefined) return escaped;
      if (linkText !== undefined) return linkText;
      if (code !== undefined) return code;
      return '';
    })
    .replace(/\|/g, ' ')
    .replace(/&#124;/g, '|');

  return text.replace(/\s+/g, ' ').trim();
}
