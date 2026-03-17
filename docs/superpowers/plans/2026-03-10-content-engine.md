# Content Engine Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold `content-engine/` at project root by integrating seomachine workspace structure, seo-geo-blog-writer skill, and full marketingskills plugin into a unified marketing engine.

**Architecture:** Seomachine provides context templates, agents, and commands. Marketingskills provides the full 32-skill suite (superset of seomachine's bundled skills). Seo-geo-blog-writer provides the blog creation skill, scripts, and references. All merged into one self-contained directory with its own CLAUDE.md.

**Tech Stack:** Astro 6 SSG, Cloudflare Pages, Python 3 (keyword research/validation scripts), Markdown content collections.

**Spec:** `docs/superpowers/specs/2026-03-10-content-engine-design.md`

---

## Chunk 1: Scaffold Directory and Import Sources

### Task 1: Create content-engine directory skeleton

**Files:**
- Create: `content-engine/` and all subdirectories

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p content-engine/{context/personas,pipeline/{topics,research,drafts},skills,scripts,references,agents,commands}
```

- [ ] **Step 2: Verify structure**

```bash
find content-engine -type d | sort
```

Expected:
```
content-engine
content-engine/agents
content-engine/commands
content-engine/context
content-engine/context/personas
content-engine/pipeline
content-engine/drafts
content-engine/pipeline/research
content-engine/pipeline/topics
content-engine/references
content-engine/scripts
content-engine/skills
```

- [ ] **Step 3: Add .gitkeep to empty pipeline dirs**

```bash
touch content-engine/pipeline/topics/.gitkeep
touch content-engine/pipeline/research/.gitkeep
touch content-engine/pipeline/drafts/.gitkeep
```

- [ ] **Step 4: Commit skeleton**

```bash
git add content-engine/
git commit -m "chore: scaffold content-engine directory structure"
```

### Task 2: Import seomachine context templates

Source: `/tmp/seomachine/context/`

We take the template files and adapt them. These are fill-in-the-blank templates — we keep the structure but the content will be EnviousWispr-specific.

**Files:**
- Copy: `brand-voice.md`, `style-guide.md`, `seo-guidelines.md`, `features.md`, `internal-links-map.md`, `target-keywords.md`, `competitor-analysis.md`, `cro-best-practices.md`
- Skip: `writing-examples.md` (seomachine-specific podcast examples)

- [ ] **Step 1: Copy context templates**

```bash
cp /tmp/seomachine/context/brand-voice.md content-engine/context/
cp /tmp/seomachine/context/style-guide.md content-engine/context/
cp /tmp/seomachine/context/seo-guidelines.md content-engine/context/
cp /tmp/seomachine/context/features.md content-engine/context/
cp /tmp/seomachine/context/internal-links-map.md content-engine/context/
cp /tmp/seomachine/context/target-keywords.md content-engine/context/
cp /tmp/seomachine/context/competitor-analysis.md content-engine/context/
cp /tmp/seomachine/context/cro-best-practices.md content-engine/context/
```

- [ ] **Step 2: Verify all 8 files copied**

```bash
ls content-engine/context/*.md | wc -l
```

Expected: `8`

- [ ] **Step 3: Commit imported templates**

```bash
git add content-engine/context/
git commit -m "chore: import seomachine context templates"
```

### Task 3: Import seomachine agents and commands

Source: `/tmp/seomachine/.claude/agents/` and `/tmp/seomachine/.claude/commands/`

Agents are specialized roles (SEO optimizer, meta creator, internal linker, etc.) that get invoked by commands. Commands orchestrate workflows (`/write`, `/research`, `/optimize`, etc.). We take all of them — they work together as a system.

**Files:**
- Copy: all 11 agents from `.claude/agents/`
- Copy: all 22 commands from `.claude/commands/`
- Skip: `publish-draft.md` command (WordPress-specific)

- [ ] **Step 1: Copy agents**

```bash
cp /tmp/seomachine/.claude/agents/*.md content-engine/agents/
```

- [ ] **Step 2: Copy commands (skip WordPress publish)**

```bash
for f in /tmp/seomachine/.claude/commands/*.md; do
  basename=$(basename "$f")
  if [ "$basename" != "publish-draft.md" ]; then
    cp "$f" content-engine/commands/
  fi
done
```

- [ ] **Step 3: Verify counts**

```bash
echo "Agents: $(ls content-engine/agents/*.md | wc -l)"
echo "Commands: $(ls content-engine/commands/*.md | wc -l)"
```

Expected: Agents: 11, Commands: 21

- [ ] **Step 4: Commit agents and commands**

```bash
git add content-engine/agents/ content-engine/commands/
git commit -m "chore: import seomachine agents and commands"
```

### Task 4: Import seo-geo-blog-writer skill, scripts, and references

Source: `/tmp/seo-geo-blog-writer/`

The blog-writer skill is the primary blog creation engine. Its scripts handle keyword research and validation. References provide SEO/GEO/E-E-A-T guidelines.

**Files:**
- Copy: `SKILL.md` + `assets/` into `skills/seo-geo-blog-writer/`
- Copy: `scripts/*.py` into `scripts/`
- Copy: `references/*.md` into `references/`
- Skip: `planning/`, `requirements.txt` (handle deps separately), `.code-workspace`

- [ ] **Step 1: Copy blog-writer skill**

```bash
mkdir -p content-engine/skills/seo-geo-blog-writer/assets
cp /tmp/seo-geo-blog-writer/SKILL.md content-engine/skills/seo-geo-blog-writer/
cp /tmp/seo-geo-blog-writer/assets/* content-engine/skills/seo-geo-blog-writer/assets/
```

- [ ] **Step 2: Copy scripts**

```bash
cp /tmp/seo-geo-blog-writer/scripts/*.py content-engine/scripts/
```

- [ ] **Step 3: Copy references**

```bash
cp /tmp/seo-geo-blog-writer/references/*.md content-engine/references/
```

- [ ] **Step 4: Copy requirements.txt for Python deps**

```bash
cp /tmp/seo-geo-blog-writer/requirements.txt content-engine/requirements.txt
```

- [ ] **Step 5: Verify file counts**

```bash
echo "Skill files: $(find content-engine/skills/seo-geo-blog-writer -type f | wc -l)"
echo "Scripts: $(ls content-engine/scripts/*.py | wc -l)"
echo "References: $(ls content-engine/references/*.md | wc -l)"
```

Expected: Skill files: 3 (SKILL.md + 2 assets), Scripts: 10, References: 4

- [ ] **Step 6: Commit blog-writer skill**

```bash
git add content-engine/skills/seo-geo-blog-writer/ content-engine/scripts/ content-engine/references/ content-engine/requirements.txt
git commit -m "chore: import seo-geo-blog-writer skill, scripts, and references"
```

### Task 5: Import full marketingskills suite

Source: `/tmp/marketingskills/skills/` and `/tmp/marketingskills/tools/`

All 32 skills plus the tools/integrations directory. This is the canonical skills source (superset of seomachine's bundled skills).

**Files:**
- Copy: all 32 skill directories into `skills/marketing/`
- Copy: `tools/` directory into `skills/marketing/tools/`
- Copy: `AGENTS.md` into `skills/marketing/`
- Skip: `.claude-plugin/`, `.github/`, `validate-skills*.sh`, `CONTRIBUTING.md`, `VERSIONS.md`

- [ ] **Step 1: Copy all 32 marketing skills**

```bash
cp -r /tmp/marketingskills/skills/* content-engine/skills/marketing/
```

- [ ] **Step 2: Copy tools directory**

```bash
cp -r /tmp/marketingskills/tools content-engine/skills/marketing/tools
```

- [ ] **Step 3: Copy AGENTS.md**

```bash
cp /tmp/marketingskills/AGENTS.md content-engine/skills/marketing/
```

- [ ] **Step 4: Verify skill count**

```bash
ls -d content-engine/skills/marketing/*/ | wc -l
```

Expected: 32 (directories) + tools

- [ ] **Step 5: Commit marketing skills**

```bash
git add content-engine/skills/marketing/
git commit -m "chore: import full marketingskills suite (32 skills)"
```

---

## Chunk 2: Configuration Files

### Task 6: Write content-engine CLAUDE.md

The self-contained marketing brain. This is what Claude reads when working in content-engine context.

**Files:**
- Create: `content-engine/CLAUDE.md`

- [ ] **Step 1: Write CLAUDE.md**

Write `content-engine/CLAUDE.md` with the following content:

```markdown
# EnviousWispr Content Engine

Marketing workspace for blog, social, email, SEO, and content production.

## Boundary Rules

1. **This workspace is self-contained.** Do not read or modify files outside `content-engine/` except to publish finished content to `../website/src/content/blog/`.
2. **Do not modify website layouts, components, styles, or config.** The website is a publish target only.
3. **Single source of truth.** `../website/src/content/blog/*.md` is the only canonical published source. `pipeline/drafts/` is working history, not authoritative.

## Product

EnviousWispr — private on-device AI dictation for macOS. Open source, free.
Hold hotkey, speak, release. Polished text lands on clipboard or pastes directly. Runs entirely on-device — no cloud, no account, no subscription.

## Website Stack

- Astro 6 SSG deployed on Cloudflare Pages
- Blog: `../website/src/content/blog/*.md` (Astro content collection)
- Frontmatter schema: `title`, `description`, `pubDate`, `tags[]`, `draft` (boolean)
- No CMS, no database — markdown committed to git

## Context Files (Read Before Writing)

- `context/brand-voice.md` — tone, voice pillars, do's/don'ts
- `context/style-guide.md` — grammar, formatting
- `context/seo-guidelines.md` — keyword rules, structure
- `context/features.md` — product capabilities
- `context/internal-links-map.md` — pages to link to
- `context/target-keywords.md` — tracked keywords
- `context/competitor-analysis.md` — competitive intelligence
- `context/cro-best-practices.md` — conversion optimization
- `context/personas/*.md` — audience profiles (one per persona)

## Content Pipeline

```
pipeline/topics/{slug}.md → pipeline/research/{slug}.md → pipeline/drafts/{slug}.md → ../website/src/content/blog/{slug}.md
```

Same slug at every stage. Lowercase, hyphen-separated, no dates in filename, max ~60 chars.

## Astro Frontmatter Template

Every published post must have this exact frontmatter:

    ---
    title: "Keyword-Rich Title Under 60 Characters"
    description: "Meta description 150-160 characters for search results."
    pubDate: YYYY-MM-DD
    tags: ["lowercase", "relevant", "seo-aware"]
    draft: false
    ---

## Skills

See `SKILL-ROUTER.md` for which skill handles which task.

- `skills/seo-geo-blog-writer/` — primary blog post creation (SEO+GEO)
- `skills/marketing/` — full marketing suite (32 skills: copywriting, content-strategy, social-content, email-sequence, seo-audit, schema-markup, and more)

## Agents

Agents in `agents/` are specialized roles invoked by commands:
`content-analyzer`, `seo-optimizer`, `meta-creator`, `internal-linker`, `keyword-mapper`, `editor`, `headline-generator`, `cro-analyst`, `performance`, `cluster-strategist`, `landing-page-optimizer`

## Commands

Commands in `commands/` orchestrate workflows:
`/write`, `/research`, `/rewrite`, `/optimize`, `/analyze-existing`, `/article`, `/cluster`, `/priorities`, and specialized research/landing commands.

## Scripts

- `scripts/keyword_research.py` — keyword research (DataForSEO API or heuristic fallback)
- `scripts/validate_structure.py` — post validation scoring
- `scripts/auto_internal_linking.py` — auto-insert internal links
- `scripts/iterative_validation.py` — iterative validation with auto-fix
- Other helper scripts in `scripts/`

Install dependencies: `pip install -r requirements.txt`
```

- [ ] **Step 2: Commit CLAUDE.md**

```bash
git add content-engine/CLAUDE.md
git commit -m "chore: add content-engine CLAUDE.md"
```

### Task 7: Write SKILL-ROUTER.md

**Files:**
- Create: `content-engine/SKILL-ROUTER.md`

- [ ] **Step 1: Write the skill router**

Write `content-engine/SKILL-ROUTER.md` with the full routing table from the design spec (Blog Production, SEO & Technical, Social & Distribution, Growth & Conversion sections, plus the meta rule).

Content is already defined in the design doc section "Skill Router" — copy it verbatim.

- [ ] **Step 2: Commit**

```bash
git add content-engine/SKILL-ROUTER.md
git commit -m "chore: add content-engine skill router"
```

### Task 8: Add pointer to main CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (project root)

- [ ] **Step 1: Add content engine pointer**

Append to the main `CLAUDE.md` before the `## Reference` section:

```markdown
## Content Engine

Marketing, blog, SEO, and content work lives in `content-engine/`. Navigate there for content tasks. Do not load content-engine context into dev sessions.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "chore: add content-engine pointer to main CLAUDE.md"
```

---

## Chunk 3: Persona Files and Brand Voice Blocker

### Task 9: Create persona files

**Files:**
- Create: 8 files in `content-engine/context/personas/`

Each persona file follows this structure:

```markdown
# [Persona Name]

## Who they are
[1-2 sentences describing this person]

## Pain points
- [Pain point 1]
- [Pain point 2]
- [Pain point 3]

## How they'd use EnviousWispr
- [Use case 1]
- [Use case 2]
- [Use case 3]

## Keywords they search for
- [Search term 1]
- [Search term 2]
- [Search term 3]

## Tone shift
[How our brand voice adapts for this persona — more technical, more casual, etc.]
```

- [ ] **Step 1: Create all 8 persona files**

Create placeholder persona files for: `writer.md`, `parent.md`, `coder.md`, `exec.md`, `student.md`, `podcaster.md`, `accessibility.md`, `remote-worker.md`.

Each gets the template structure above with placeholder content to be refined during brand voice workshop.

- [ ] **Step 2: Commit personas**

```bash
git add content-engine/context/personas/
git commit -m "chore: add persona file templates"
```

### Task 10: Fill in brand-voice.md (BLOCKER — requires human input)

This is the critical blocker before any blog post production. The template from seomachine is already in `content-engine/context/brand-voice.md`. It needs to be filled with EnviousWispr's voice identity.

**Approach:** Run a buddies-assisted brand voice workshop. Use the existing welcome blog post (`website/src/content/blog/welcome-to-enviouswispr.md`) as the "this is what we sound like" anchor.

**Files:**
- Modify: `content-engine/context/brand-voice.md`

- [ ] **Step 1: Kick off buddies brainstorm for brand voice**

Send GPT and Gemini the welcome blog post + product description. Ask them to:
- Identify 4-5 voice pillars from the existing writing
- Draft the full brand-voice.md using seomachine's template
- Include do's/don'ts, terminology preferences, and voice examples

- [ ] **Step 2: Present draft to user for review and iteration**

- [ ] **Step 3: Finalize and write brand-voice.md**

- [ ] **Step 4: Commit finalized brand voice**

```bash
git add content-engine/context/brand-voice.md
git commit -m "feat: define EnviousWispr brand voice"
```

### Task 11: Fill in features.md and internal-links-map.md

These two context files can be populated from existing project knowledge without human brainstorming.

**Files:**
- Modify: `content-engine/context/features.md`
- Modify: `content-engine/context/internal-links-map.md`

- [ ] **Step 1: Write features.md**

Populate with EnviousWispr's actual features:
- On-device transcription (WhisperKit/Parakeet)
- Push-to-talk + hands-free mode
- LLM post-processing (polish, translate, reformat)
- Per-app presets
- Privacy by design (no cloud, no account)
- Open source

- [ ] **Step 2: Write internal-links-map.md**

Map the current website pages:
- `/` — Homepage
- `/how-it-works/` — Pipeline deep-dive
- `/blog/` — Blog index
- GitHub releases page (download)
- GitHub repo (source)

- [ ] **Step 3: Commit**

```bash
git add content-engine/context/features.md content-engine/context/internal-links-map.md
git commit -m "chore: populate features and internal links context"
```

---

## Chunk 4: Customization and Cleanup

### Task 12: Customize seo-geo-blog-writer for Astro output

The blog-writer skill currently targets generic markdown. We need to customize it for Astro content collection format.

**Files:**
- Modify: `content-engine/skills/seo-geo-blog-writer/SKILL.md`
- Modify: `content-engine/skills/seo-geo-blog-writer/assets/blog-template.md`

- [ ] **Step 1: Update SKILL.md**

Add an "Output Format" section that specifies:
- Astro frontmatter schema (title, description, pubDate, tags, draft)
- Output path: `pipeline/drafts/{slug}.md` during drafting, `../website/src/content/blog/{slug}.md` when publishing
- Slug naming convention (lowercase, hyphen-separated, no dates)
- Read `context/brand-voice.md` before writing any content

- [ ] **Step 2: Update blog-template.md**

Replace the generic template header with Astro frontmatter:

```yaml
---
title: "{title}"
description: "{description}"
pubDate: {date}
tags: [{tags}]
draft: false
---
```

- [ ] **Step 3: Commit customizations**

```bash
git add content-engine/skills/seo-geo-blog-writer/
git commit -m "feat: customize blog-writer skill for Astro output"
```

### Task 13: Remove WordPress/Sanity references from imported files

Clean up references to WordPress publishing and Sanity CMS that won't apply.

**Files:**
- Modify: various files in `content-engine/agents/`, `content-engine/commands/`

- [ ] **Step 1: Search for WordPress references**

```bash
grep -rl "wordpress\|WordPress\|Yoast\|yoast" content-engine/ | grep -v node_modules
```

- [ ] **Step 2: Remove or update WordPress-specific content**

For each file found, remove WordPress-specific instructions and replace with Astro publish instructions where relevant.

- [ ] **Step 3: Search for Sanity references**

```bash
grep -rl "sanity\|Sanity\|SANITY" content-engine/ | grep -v node_modules
```

- [ ] **Step 4: Remove Sanity-specific content**

Replace Sanity CMS linking with local content directory references (`../website/src/content/blog/`).

- [ ] **Step 5: Commit cleanup**

```bash
git add content-engine/
git commit -m "chore: remove WordPress/Sanity references, adapt for Astro"
```

### Task 14: Update .gitignore for content-engine

**Files:**
- Modify: `.gitignore` (project root)

- [ ] **Step 1: Add content-engine-specific ignores**

Append to `.gitignore`:

```
# Content Engine
content-engine/scripts/__pycache__/
content-engine/.seo-geo-config.json
content-engine/generated_images/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add content-engine entries to .gitignore"
```

### Task 15: Final verification

- [ ] **Step 1: Verify complete directory structure**

```bash
find content-engine -type f | wc -l
find content-engine -type d | sort
```

- [ ] **Step 2: Verify no content-engine context leaks into main CLAUDE.md**

```bash
grep -c "content-engine" CLAUDE.md
```

Expected: 2 (the pointer section only — heading + instruction line)

- [ ] **Step 3: Verify SKILL-ROUTER.md exists and covers all skills**

```bash
cat content-engine/SKILL-ROUTER.md | head -5
ls content-engine/skills/marketing/ | wc -l
```

- [ ] **Step 4: Final commit with all loose files**

```bash
git status
# Stage any remaining files
git add content-engine/
git commit -m "feat: content-engine scaffold complete"
```

---

## Execution Order Summary

1. **Tasks 1-5** (Chunk 1): Scaffold + import all three sources. Pure file operations, no decisions needed.
2. **Tasks 6-8** (Chunk 2): Write CLAUDE.md, skill router, main project pointer. Configuration.
3. **Tasks 9-11** (Chunk 3): Personas + brand voice (Task 10 is the human-input blocker). Features/links from existing knowledge.
4. **Tasks 12-15** (Chunk 4): Customize for Astro, clean up WordPress/Sanity, verify.

Tasks 1-9, 11-15 can be executed by agents without human input. Task 10 (brand voice) requires a buddies-assisted workshop with the user.
