import { getCollection, type CollectionEntry } from 'astro:content';
import { HELP_CATEGORIES, helpCategory, type HelpCategory } from '../data/help-categories';
import { getPublishedPosts } from './posts';

export type HelpArticle = CollectionEntry<'help'>;

const SITE = 'https://enviouswispr.com';

/**
 * All help articles, sorted by category order then `order` within the category.
 *
 * Also the single place the collection's cross-references are validated, so a
 * dead `related` or `seeAlso` slug fails the build rather than shipping a link
 * to nowhere. Called from getStaticPaths, which runs before any page renders.
 */
export async function getHelpArticles(): Promise<HelpArticle[]> {
  const articles = await getCollection('help');
  const catIndex = new Map(HELP_CATEGORIES.map((c, i) => [c.slug, i]));

  const slugs = new Set(articles.map((a) => a.id));

  // `order` must be unique within a category, or prev/next and the rendered
  // sequence depend on an arbitrary tiebreak that nothing declares.
  const seen = new Map<string, string>();
  for (const a of articles) {
    const key = `${a.data.category}#${a.data.order}`;
    const prior = seen.get(key);
    if (prior) {
      throw new Error(
        `help: duplicate order ${a.data.order} in category "${a.data.category}" — ${prior} and ${a.id}`
      );
    }
    seen.set(key, a.id);
    for (const r of a.data.related) {
      if (!slugs.has(r)) throw new Error(`help: ${a.id} has a related slug that does not exist: ${r}`);
      if (r === a.id) throw new Error(`help: ${a.id} lists itself as related`);
    }
  }

  // A category with no articles would render an empty page and a dead nav row.
  for (const c of HELP_CATEGORIES) {
    if (!articles.some((a) => a.data.category === c.slug)) {
      throw new Error(`help: category "${c.slug}" has no articles`);
    }
  }

  return articles.sort((a, b) => {
    const byCat = (catIndex.get(a.data.category) ?? 0) - (catIndex.get(b.data.category) ?? 0);
    return byCat !== 0 ? byCat : a.data.order - b.data.order;
  });
}

/** Validates every `seeAlso` against the blog posts that are actually PUBLISHED.
 *
 *  Separate because it reaches into a second collection and only the article
 *  route needs it.
 *
 *  It asks `getPublishedPosts()` rather than `getCollection('blog')` because
 *  that is the exact set the blog route emits: a draft or future-dated post
 *  exists in the collection but has no page, so validating against the
 *  collection would approve a link that 404s. The check has to use the route's
 *  own definition of "exists", not a looser one that happens to be nearby.
 *
 *  Nothing else would catch it: the post-build link scan only follows /help/
 *  hrefs, so a dead /blog/ link leaves no trace in either check. */
export async function validateSeeAlso(articles: HelpArticle[]): Promise<void> {
  const withSeeAlso = articles.filter((a) => a.data.seeAlso);
  if (withSeeAlso.length === 0) return;
  const published = new Set((await getPublishedPosts()).map((p) => p.id));
  for (const a of withSeeAlso) {
    if (!published.has(a.data.seeAlso!)) {
      throw new Error(
        `help: ${a.id} seeAlso points at a blog post that is not published: ${a.data.seeAlso}. ` +
        `It must exist AND be non-draft with a pubDate that has arrived, or the link 404s.`
      );
    }
  }
}

export function articlesInCategory(articles: HelpArticle[], slug: string): HelpArticle[] {
  return articles.filter((a) => a.data.category === slug);
}

/** Articles grouped by their section label, preserving `order`. */
export function groupBySection(articles: HelpArticle[]): { section: string; articles: HelpArticle[] }[] {
  const groups: { section: string; articles: HelpArticle[] }[] = [];
  for (const a of articles) {
    const last = groups[groups.length - 1];
    if (last && last.section === a.data.section) last.articles.push(a);
    else groups.push({ section: a.data.section, articles: [a] });
  }
  return groups;
}

/** Previous and next within the article's own category. */
export function neighbours(articles: HelpArticle[], article: HelpArticle) {
  const siblings = articlesInCategory(articles, article.data.category);
  const i = siblings.findIndex((a) => a.id === article.id);
  return { prev: i > 0 ? siblings[i - 1] : null, next: i >= 0 && i < siblings.length - 1 ? siblings[i + 1] : null };
}

/**
 * Up to three related articles: hand-authored cross-category links first, then
 * same-section siblings, then same-category. Hand-authored links are the ones
 * that cross a category boundary, which derivation cannot find.
 */
export function related(articles: HelpArticle[], article: HelpArticle, limit = 3): HelpArticle[] {
  const byId = new Map(articles.map((a) => [a.id, a]));
  const out: HelpArticle[] = [];
  const push = (a: HelpArticle | undefined) => {
    if (a && a.id !== article.id && !out.some((x) => x.id === a.id) && out.length < limit) out.push(a);
  };
  for (const slug of article.data.related) push(byId.get(slug));
  for (const a of articles) {
    if (a.data.category === article.data.category && a.data.section === article.data.section) push(a);
  }
  for (const a of articlesInCategory(articles, article.data.category)) push(a);
  return out;
}

export function categoryOf(article: HelpArticle): HelpCategory {
  const c = helpCategory(article.data.category);
  // Unreachable while the Zod enum and HELP_CATEGORIES share a source, but the
  // throw is what makes that coupling load-bearing rather than assumed.
  if (!c) throw new Error(`help: ${article.id} has unknown category "${article.data.category}"`);
  return c;
}

export const helpUrl = (slug: string) => `${SITE}/help/${slug}/`;
export const helpIndexUrl = `${SITE}/help/`;

/** ISO date (YYYY-MM-DD) for a Date, in UTC, matching the blog's convention. */
export const isoDate = (d: Date) => d.toISOString().slice(0, 10);
