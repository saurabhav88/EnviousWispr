import { getCollection } from 'astro:content';

/**
 * Get today's date string (YYYY-MM-DD) in America/New_York timezone.
 * Posts go live at midnight Eastern, regardless of server timezone.
 */
function getTodayET(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/New_York',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

/**
 * Extract the calendar date (YYYY-MM-DD) from a pubDate.
 * YAML dates like `pubDate: 2026-03-15` parse as midnight UTC.
 * We use UTC components to recover the original calendar date.
 */
function pubDateToCalendarDate(date: Date): string {
  const y = date.getUTCFullYear();
  const m = String(date.getUTCMonth() + 1).padStart(2, '0');
  const d = String(date.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** A post is visible if it is not a draft AND its pubDate <= today in ET. */
export function isPublishedPost(data: { draft?: boolean; pubDate: Date }): boolean {
  if (data.draft) return false;
  return pubDateToCalendarDate(data.pubDate) <= getTodayET();
}

/** Get all published, non-future posts sorted newest first. */
export async function getPublishedPosts() {
  const posts = await getCollection('blog', ({ data }) => isPublishedPost(data));
  return posts.sort((a, b) => b.data.pubDate.valueOf() - a.data.pubDate.valueOf());
}
