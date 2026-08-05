import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';
import { HELP_CATEGORY_SLUGS } from './data/help-categories';

const blog = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/blog' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    tags: z.array(z.string()).default([]),
    draft: z.boolean().default(false),
    author: z.string().default('Envious Labs'),
    authorUrl: z.string().url().optional(),
    image: z.string().optional(),
    keywords: z.array(z.string()).optional(),
    faqs: z
      .array(
        z.object({
          question: z.string(),
          answer: z.string(),
        }),
      )
      .optional(),
  }),
});

// Help-centre articles. `category` is a closed enum derived from
// help-categories.ts, so a typo fails the build naming the file rather than
// creating a ghost category nothing renders.
//
// Fields split by provenance. `title`, `description`, `category` and `section`
// are derived from the retired Crisp source and are checked against it by
// scripts/check-help-frontmatter.mjs; the rest are migration-authored.
const help = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/help' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    category: z.enum(HELP_CATEGORY_SLUGS),
    section: z.string(),
    /** Position within the category. Uniqueness is asserted in getStaticPaths. */
    order: z.number().int().positive(),
    /** Words a person actually types. This is what makes search find things. */
    keywords: z.array(z.string()).default([]),
    /** Cross-category article slugs. Validated against the collection at build. */
    related: z.array(z.string()).default([]),
    /** Blog slug for an article with a long-form twin. Validated at build. */
    seeAlso: z.string().optional(),
    /** Drives sitemap lastmod and the visible "last checked" line. */
    updated: z.coerce.date(),
  }),
});

export const collections = { blog, help };
