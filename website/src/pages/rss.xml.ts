import rss from '@astrojs/rss';
import { getPublishedPosts } from '../utils/posts';
import type { APIContext } from 'astro';

export async function GET(context: APIContext) {
  const sorted = await getPublishedPosts();

  return rss({
    title: 'EnviousWispr Blog',
    description:
      'Updates, release notes, and deep dives from the EnviousWispr team — private AI dictation for macOS.',
    site: context.site ?? 'https://enviouswispr.com',
    items: sorted.map(post => ({
      title: post.data.title,
      description: post.data.description,
      pubDate: post.data.pubDate,
      link: `/blog/${post.id}/`,
      categories: post.data.tags,
    })),
    customData: `<language>en-us</language>`,
    stylesheet: false,
  });
}
