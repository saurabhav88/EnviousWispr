# Content Engine Design

Integrate seomachine workspace + seo-geo-blog-writer skill + marketingskills plugin into a unified `content-engine/` directory at project root. Full marketing engine for blog, social, email, and content production.

## Architecture

### Directory Structure

```
content-engine/
├── CLAUDE.md                     # Self-contained marketing brain
├── context/                      # Brand + product knowledge
│   ├── brand-voice.md            # Voice pillars, tone, do's/don'ts (BLOCKER)
│   ├── style-guide.md            # Grammar, formatting standards
│   ├── seo-guidelines.md         # Keyword and structure rules
│   ├── features.md               # Product capabilities
│   ├── internal-links-map.md     # Site pages for internal linking
│   ├── target-keywords.md        # Tracked keywords
│   ├── competitor-analysis.md    # Competitive intelligence
│   ├── cro-best-practices.md     # Conversion optimization
│   └── personas/                 # One file per target audience
│       ├── writer.md
│       ├── parent.md
│       ├── coder.md
│       ├── exec.md
│       ├── student.md
│       ├── podcaster.md
│       ├── accessibility.md
│       └── remote-worker.md
├── pipeline/                     # Content lifecycle (slug-based naming)
│   ├── topics/                   # Ideas and briefs
│   ├── research/                 # Keyword research, competitor analysis
│   └── drafts/                   # Work-in-progress posts
├── skills/
│   ├── seo-geo-blog-writer/      # SEO+GEO blog post skill (Astro-customized)
│   └── marketing/                # Full marketingskills plugin (all 32 skills)
├── scripts/                      # From seo-geo-blog-writer
│   ├── keyword_research.py
│   ├── validate_structure.py
│   └── ...
├── references/                   # SEO/GEO reference docs
│   ├── content-patterns.md
│   ├── eeat-guidelines.md
│   ├── geo-optimization.md
│   └── seo-checklist.md
└── SKILL-ROUTER.md               # Which skill handles what
```

### Source Repos

| Source | What we take | What we drop |
|--------|-------------|-------------|
| TheCraigHewitt/seomachine | `context/` templates, pipeline folder structure, CLAUDE.md patterns, agents | WordPress integration, Python analytics pipeline (GA4/GSC/DataForSEO) |
| weipanux/seo-geo-blog-writer | SKILL.md, `scripts/`, `references/`, `assets/` | Sanity CMS linking, `.code-workspace` |
| coreyhaines31/marketingskills | All 32 skills, AGENTS.md, tools/ | GitHub workflows, plugin marketplace metadata |

## Boundary Rules

### Rule 1: Main project does not load content context

The main `CLAUDE.md` gets ONE pointer line:

```markdown
## Content Engine
Marketing, blog, SEO, and content work lives in `content-engine/`. Navigate there for content tasks. Do not load content-engine context into dev sessions.
```

No marketing skills, brand voice, SEO rules, or content-engine context loads into Swift/app/website dev sessions. The main project's 40+ dev skills remain uncontaminated.

### Rule 2: Content sessions treat website as publish target only

Content sessions work FROM `content-engine/`. The only interaction with `../website/` is copying a finished post to `../website/src/content/blog/{slug}.md`. Content sessions do not modify website layouts, components, styles, or config.

### Rule 3: No dual sources of truth

`website/src/content/blog/*.md` is the ONLY canonical published source. There is no `pipeline/published/` directory. The pipeline is:

```
pipeline/topics/ → pipeline/research/ → pipeline/drafts/ → website/src/content/blog/
```

Once a draft is finalized and copied to the website blog directory, it is published. The draft in `pipeline/drafts/` may be kept as working history but is NOT authoritative — the website copy is the single source of truth.

## Naming Convention

Slug-based naming across the entire pipeline. The same slug identifies a piece of content at every stage:

```
pipeline/topics/dictation-for-pr-descriptions.md
pipeline/research/dictation-for-pr-descriptions.md
pipeline/drafts/dictation-for-pr-descriptions.md
website/src/content/blog/dictation-for-pr-descriptions.md
```

Slug rules:
- Lowercase, hyphen-separated
- No dates in filename (pubDate lives in frontmatter)
- Descriptive, keyword-aware
- Max ~60 characters

## Skill Router

`SKILL-ROUTER.md` maps tasks to skills to prevent overlap and noisy routing.

### Blog Production
| Task | Skill | When |
|------|-------|------|
| Plan what to write | `marketing/content-strategy` | Before any writing — topic selection, editorial calendar |
| Write a blog post | `seo-geo-blog-writer` | Primary blog creation skill (SEO+GEO optimized) |
| Edit/polish a draft | `marketing/copy-editing` | After draft exists — seven-sweep editing pass |
| Improve weak copy | `marketing/copywriting` | When specific sections need stronger persuasion/CTAs |

### SEO & Technical
| Task | Skill | When |
|------|-------|------|
| SEO audit | `marketing/seo-audit` | Audit existing content or site structure |
| Schema markup | `marketing/schema-markup` | Add structured data to posts |
| AI search optimization | `marketing/ai-seo` | Optimize for AI citations (GEO) |
| Site architecture | `marketing/site-architecture` | Plan URL structure, topic clusters |

### Social & Distribution
| Task | Skill | When |
|------|-------|------|
| Social media posts | `marketing/social-content` | Create social content from blog posts |
| Email sequences | `marketing/email-sequence` | Drip campaigns, onboarding emails |
| Cold outreach | `marketing/cold-email` | Outbound marketing emails |

### Growth & Conversion
| Task | Skill | When |
|------|-------|------|
| Landing pages | `marketing/copywriting` | Write landing page copy |
| Pricing strategy | `marketing/pricing-strategy` | Plan pricing tiers |
| Launch planning | `marketing/launch-strategy` | Product launch campaigns |
| A/B testing | `marketing/ab-test-setup` | Test copy/design variants |
| Competitor analysis | `marketing/competitor-alternatives` | Compare against competitors |

### Meta Rule
When in doubt: `content-strategy` decides WHAT to write, `seo-geo-blog-writer` writes blog posts, `copywriting` writes everything else, `copy-editing` improves anything that already exists.

## Blog Post Workflow

### Step 1: Persona + Topic
Select persona from `context/personas/`. Load persona file + `context/brand-voice.md` + `context/features.md`.

### Step 2: Keyword Research
```bash
python scripts/keyword_research.py "target topic" --limit 5 --format markdown
```
Save brief to `pipeline/research/{slug}.md`.

### Step 3: Outline
Blog-writer skill generates outline using `references/content-patterns.md`. User approves.

### Step 4: Draft
Written to `pipeline/drafts/{slug}.md`. Applies brand voice, SEO structure, GEO optimization, E-E-A-T signals, internal links.

### Step 5: Edit
`skills/marketing/copy-editing/` — seven sweeps (clarity, specificity, conversion, etc.)

### Step 6: Validate
```bash
python scripts/validate_structure.py pipeline/drafts/{slug}.md
```

### Step 7: Publish
Copy to `website/src/content/blog/{slug}.md` with Astro frontmatter:
```yaml
---
title: "Keyword-Rich Title Under 60 Characters"
description: "Meta description 150-160 characters for search results."
pubDate: 2026-03-10
tags: ["lowercase", "relevant", "seo-aware"]
draft: false
---
```

### Step 8: Commit
```bash
git add website/src/content/blog/{slug}.md
git commit -m "blog: add {slug}"
git push
```

## Brand Voice (BLOCKER)

`context/brand-voice.md` must be filled in BEFORE scaling post creation. The template from seomachine provides the structure (voice pillars, tone variations, messaging framework, terminology, examples). We fill it with EnviousWispr's identity:

- Privacy-first, developer-friendly, no-BS, open source pride
- Conversational but authoritative
- Shows real workflows, not hype
- Per-persona tone shifts

This is the FIRST task after scaffolding the content-engine directory.

## What We Drop

| Dropped | Why |
|---------|-----|
| Seomachine WordPress integration | We use Astro SSG |
| Seomachine Python analytics (GA4/GSC/DataForSEO) | Add later when we have traffic data |
| Blog-writer Sanity CMS linking | We use local markdown |
| `pipeline/published/` directory | Website blog dir is single source of truth |
| Marketingskills GitHub CI/plugin metadata | Not needed as embedded skills |
