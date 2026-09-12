import { getImage } from "astro:assets";
import type { ImageMetadata } from "astro";
import type { CollectionEntry } from "astro:content";
import { readingMinutes } from "./blog-core.js";
import { topicLabel } from "../data/blog-topics.js";
const sources = import.meta.glob<ImageMetadata>("../assets/blog/*.jpg", {
  eager: true,
  import: "default",
});
const cache = new Map<string, Promise<BlogArtwork | null>>();
interface BlogArtwork {
  src: string;
  srcset: string;
  width: number;
  height: number;
  social: string;
}
export function blogArtwork(slug: string): Promise<BlogArtwork | null> {
  if (!cache.has(slug)) {
    const source = sources[`../assets/blog/${slug}.jpg`];
    cache.set(
      slug,
      source
        ? (async () => {
            const widths = [480, 960, 1440];
            const images = await Promise.all(
              widths.map((width) =>
                getImage({ src: source, width, format: "webp", quality: 80 }),
              ),
            );
            const social = await getImage({
              src: source,
              width: 1200,
              height: 630,
              fit: "cover",
              format: "jpeg",
              quality: 82,
            });
            return {
              src: images[1].src,
              srcset: images
                .map((image, index) => `${image.src} ${widths[index]}w`)
                .join(", "),
              width: 1440,
              height: 960,
              social: social.src,
            };
          })()
        : Promise.resolve(null),
    );
  }
  return cache.get(slug)!;
}
export async function presentPost(post: CollectionEntry<"blog">) {
  return {
    slug: post.id,
    url: `/blog/${post.id}/`,
    title: post.data.title,
    description: post.data.description,
    topic: post.data.topic ?? "",
    topicLabel: topicLabel(post.data.topic),
    tags: post.data.tags,
    minutes: readingMinutes(post.body),
    artwork: await blogArtwork(post.id),
  };
}
export type BlogCardData = Awaited<ReturnType<typeof presentPost>>;
