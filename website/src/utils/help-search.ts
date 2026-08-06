import MiniSearch, { type SearchResult } from 'minisearch';

/**
 * Sole owner of the help-search document shape, field weights, query handling
 * and result ordering.
 *
 * It is a separate module from the component for a validation reason rather
 * than a tidiness one: if the component owned the configuration, the assertion
 * suites would have to rebuild the boosts to test them, which tests a copy of
 * the search instead of the search.
 */
export interface HelpDoc {
  id: string;
  title: string;
  description: string;
  category: string;
  categoryLabel: string;
  section: string;
  keywords: string;
  headings: string;
  body: string;
}

const FIELDS = ['title', 'keywords', 'headings', 'description', 'body'];
const BOOST = { title: 5, keywords: 4, headings: 3, description: 2, body: 1 };

/** Fields whose content is curated by hand. Only these unlock the fallback. */
const CURATED = new Set(['title', 'keywords', 'headings']);

const FALLBACK_LIMIT = 5;

// Ordinary English stopwords. A closed linguistic set, not a prediction about
// our users, so it does not fall foul of the generalisation gate: strict AND
// over a raw query returns ZERO for "change my hotkey", because "my" appears
// nowhere in the corpus, and people write sentences.
const STOP = new Set(
  ('a about after all also am an and any are as at be because been before being between both but by can ' +
   'cant cannot could did do does doing dont down during each few for from further had has have having he ' +
   'her here hers him his how i if in into is it its just me more most my no nor not now of off on once ' +
   'only or other our out over own same she should so some such than that the their them then there these ' +
   'they this those through to too under until up very was we were what when where which while who whom ' +
   'why will with would you your').split(' ')
);

export type MatchKind = 'exact' | 'closest' | 'none';

export interface HelpSearchResult {
  matchKind: MatchKind;
  results: SearchResult[];
}

export function buildHelpIndex(docs: HelpDoc[]): MiniSearch<HelpDoc> {
  const mini = new MiniSearch<HelpDoc>({
    fields: FIELDS,
    storeFields: ['id', 'title', 'category', 'categoryLabel', 'description', 'body'],
    searchOptions: { boost: BOOST, prefix: true, fuzzy: 0.2 },
  });
  mini.addAll(docs);
  return mini;
}

export function normalizeQuery(raw: string): string {
  const tokens = raw.toLowerCase().replace(/[^\p{L}\p{N}\s]/gu, ' ').split(/\s+/).filter(Boolean);
  const kept = tokens.filter((t) => !STOP.has(t));
  // A query that is entirely stopwords ("how do i") keeps its words rather than
  // searching for nothing at all.
  return (kept.length ? kept : tokens).join(' ');
}

/**
 * Fallback eligibility, decided PER DOCUMENT on that document's own evidence,
 * and requiring an EXACT complete-token match in a curated field.
 *
 * Not a prefix, not an edit-distance neighbour. Both still influence MiniSearch
 * ranking; neither unlocks the fallback. The reason is that the fallback can
 * only run when some query token matched nothing at all, so admitting a fuzzy
 * or prefix match means answering while ignoring part of what the user typed —
 * and the same mechanism that would rescue a misspelling lets an accidental
 * neighbour return a confident-looking wrong article. An honest "no exact
 * match" with category links beats a guess.
 *
 * Ordinary misspellings are unaffected: they resolve through the strict pass,
 * where fuzzy matching applies inside the AND.
 */
function exactCuratedToken(r: SearchResult, tokens: string[]): boolean {
  return Object.entries(r.match ?? {}).some(
    ([term, fields]) => tokens.includes(term) && (fields as string[]).some((f) => CURATED.has(f))
  );
}

export function searchHelp(mini: MiniSearch<HelpDoc>, raw: string): HelpSearchResult {
  const q = normalizeQuery(raw);
  if (!q) return { matchKind: 'none', results: [] };
  const tokens = q.split(' ');

  // Tier 1: every term matched together. Fuzzy applies, so typos land here.
  const strict = mini.search(q, { combineWith: 'AND' });
  if (strict.length) return { matchKind: 'exact', results: strict };

  // Tier 2: at least one query token exactly equals a complete curated token.
  const loose = mini.search(q, { combineWith: 'OR' }).filter((r) => exactCuratedToken(r, tokens));
  return loose.length
    ? { matchKind: 'closest', results: loose.slice(0, FALLBACK_LIMIT) }
    : { matchKind: 'none', results: [] };
}

/**
 * A short excerpt around the first matching term, for the result row. Falls
 * back to the description, which is always present and always sensible.
 */
export function snippet(result: SearchResult, raw: string, max = 150): string {
  const body: string = (result as unknown as HelpDoc).body ?? '';
  const description: string = (result as unknown as HelpDoc).description ?? '';
  const tokens = normalizeQuery(raw).split(' ').filter(Boolean);
  if (!body || !tokens.length) return description;

  const lower = body.toLowerCase();
  let at = -1;
  for (const t of tokens) {
    const i = lower.indexOf(t);
    if (i !== -1 && (at === -1 || i < at)) at = i;
  }
  if (at === -1) return description;

  const start = Math.max(0, at - 60);
  const raw_excerpt = body.slice(start, start + max).trim();
  return (start > 0 ? '…' : '') + raw_excerpt + (start + max < body.length ? '…' : '');
}
