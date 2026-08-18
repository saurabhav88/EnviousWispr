// Single authority for help-centre category identity, order and display text.
//
// Category metadata lives here rather than being repeated across 52 frontmatter
// blocks: with 52 copies and no validator, a typo produces a thirteenth ghost
// category and nothing complains. The Zod enum below derives from this list, so
// a bad `category` value fails the build naming the file.
//
// Order is the order they appear on /help/. Troubleshooting is second because
// the most common visitor to a help centre already has a problem.

export interface HelpCategory {
  /** URL segment: /help/<slug>/ */
  slug: string;
  /** Display name. */
  label: string;
  /** One line under the label on the index and category pages. */
  blurb: string;
}

export const HELP_CATEGORIES: readonly HelpCategory[] = [
  {
    slug: 'getting-started',
    label: 'Getting Started',
    blurb: 'Install it, allow it, and get your first words on screen.',
  },
  {
    slug: 'troubleshooting',
    label: 'Troubleshooting',
    blurb: 'Something is not working. Start here.',
  },
  {
    slug: 'recording-and-keybinds',
    label: 'Recording and Keybinds',
    blurb: 'Hold, tap, or go hands-free. Pick how you start and stop, and change the key.',
  },
  {
    slug: 'speech-engines',
    label: 'Speech Engines',
    blurb: 'What turns your voice into words, and which languages each one covers.',
  },
  {
    slug: 'ai-polish',
    label: 'AI Polish',
    blurb: 'The optional step that tidies up what you said, including how to turn it off.',
  },
  {
    slug: 'pasting-your-text',
    label: 'Pasting Your Text',
    blurb: 'How your words reach the app you were typing in, and what to do when they do not.',
  },
  {
    slug: 'audio-and-microphone',
    label: 'Audio and Microphone',
    blurb: 'Choosing a mic, AirPods and Bluetooth, background noise, and when it stops listening.',
  },
  {
    slug: 'custom-words',
    label: 'Custom Words',
    blurb: 'Teach it names, jargon, and anything it keeps getting wrong.',
  },
  {
    slug: 'features',
    label: 'Features',
    blurb: 'History, filler words, spoken punctuation, numbers and dates, sounds and appearance.',
  },
  {
    slug: 'privacy-and-security',
    label: 'Privacy and Security',
    blurb: 'What stays on your Mac, what does not, and who can see it.',
  },
  {
    slug: 'updates-and-source',
    label: 'Updates and Source',
    blurb: 'Staying current, and the code itself.',
  },
  {
    slug: 'pricing',
    label: 'Pricing',
    blurb: 'What it costs. The short answer is nothing.',
  },
] as const;

/** Tuple form for `z.enum`, which needs at least one literal. */
export const HELP_CATEGORY_SLUGS = HELP_CATEGORIES.map((c) => c.slug) as [string, ...string[]];

export function helpCategory(slug: string): HelpCategory | undefined {
  return HELP_CATEGORIES.find((c) => c.slug === slug);
}
