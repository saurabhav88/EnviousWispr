---
name: seo-geo-blog-writer
description: Create blog posts optimized for traditional search engines (SEO) and generative AI citations (GEO). Supports two modes - keyword-driven (user provides target keyword) or topic expansion (automated keyword research). Complete workflow from keyword research through schema markup generation.
---

# SEO-GEO Blog Writer

## Purpose
Create high-performing blog posts optimized for both traditional search engines (SEO) and generative AI citations (GEO) through a structured four-phase workflow: Research → Outline → Draft → Optimize.

## Astro Output Format

This skill outputs for an Astro 6 SSG content collection. All posts must use this exact frontmatter:

    ---
    title: "Keyword-Rich Title Under 60 Characters"
    description: "Meta description 150-160 characters for search results."
    pubDate: YYYY-MM-DD
    tags: ["lowercase", "relevant", "seo-aware"]
    draft: false
    ---

**Output paths:**
- During drafting: `pipeline/drafts/{slug}.md`
- When publishing: `../website/src/content/blog/{slug}.md`

**Slug convention:** Lowercase, hyphen-separated, no dates in filename, max ~60 chars. Same slug used across all pipeline stages.

**Before writing:** Always read `context/brand-voice.md` and the relevant `context/personas/*.md` file.

## When to Use This Skill

Activate when user requests blog content creation. Two modes supported:

**Mode A - Keyword-Driven:**
- "Write a blog post targeting 'best CRM for small business'"
- "Create an article optimized for 'React hooks tutorial'"
- "I need a post ranking for 'email marketing automation tools'"

**Mode B - Topic Expansion:**
- "Write a blog post about email marketing"
- "Create an article on React development"
- "I need content about CRM systems"

Both modes follow the same four-phase workflow after keyword selection.

## Workflow Overview

Execute in seven phases:

1. **Research**: Gather requirements, conduct keyword research, analyze search intent, identify citation-worthy sources
2. **Outline**: Select content pattern, create structured outline with SEO-optimized headers and GEO-friendly sections
3. **Draft**: Write comprehensive content following E-E-A-T principles with proper keyword placement
4. **Optimize**: Initial content optimization and refinement
5. **Auto Internal Linking** (NEW v2.2): Discover and insert high-confidence internal links from local content directory
6. **Image Generation** (Coming Week 3): Auto-generate and insert images using AI
7. **Final Validation**: Iterative validation with auto-fix for FAQ, author bio, schema, title

## Example Usage

### Example 1: Mode B (Topic Expansion with Keyword Research)

**User Request:**
"Write a blog post about empath boundaries"

**Execution Flow:**
1. **Detect Mode B** (general topic, no specific keyword)
2. **Execute keyword research:**
   ```bash
   python scripts/keyword_research.py "empath boundaries" --limit 5 --format markdown
   ```
3. **Present options to user:**
   ```
   Top keywords researched:
   1. healthy boundaries for empaths (Vol: 2,400, Diff: 45, Score: 95)
   2. how to set boundaries as an empath (Vol: 3,100, Diff: 52, Score: 92)
   3. empath boundary setting tips (Vol: 1,200, Diff: 38, Score: 88)
   
   Which would you like to target? (or 'auto' for best match)
   ```
4. **User selects:** "Let's use #1" → Keyword confirmed: "healthy boundaries for empaths"
5. **Gather remaining requirements:** audience, author details, word count (2,000 words recommended for Diff: 45)
6. Load `references/content-patterns.md` → Select "How-To Guide" pattern
7. Create outline with keyword optimization
8. Write draft following E-E-A-T guidelines
9. Execute validation and deliver complete package

**Output:** 2,000-word how-to guide optimized for "healthy boundaries for empaths" with FAQ schema, validation report, and meta tags

### Example 2: Mode A (Keyword-Driven)

**User Request:**
"Write a blog post about best email marketing tools for Shopify stores"

**Execution Flow:**
1. **Detect Mode A** (specific long-tail keyword provided)
2. **Confirm keyword:** "I'll optimize for 'best email marketing tools for Shopify stores'. Confirm?"
3. **Gather requirements:** audience (Shopify store owners), word count (2,500), author details
4. Load `references/content-patterns.md` → Select "Comparison Article" pattern
5. Load `references/seo-checklist.md` → Extract keyword strategy
6. Generate outline using `assets/blog-template.md` structure
7. Write draft following E-E-A-T guidelines from `references/eeat-guidelines.md`
8. Execute `scripts/validate_structure.py` on draft
9. Generate schema markup using `assets/structured-data-examples.json`
10. Deliver: blog post + schema markup + SEO checklist

**Output:** 2,500-word comparison article with FAQ schema, meta tags, and validation report

## Implementation Instructions

### Phase 1: Gather Requirements & Keyword Research

This skill supports two modes based on user input:

**Mode A: Keyword-Driven** (User provides specific target keyword)
**Mode B: Topic Expansion** (User provides general topic, needs keyword research)

#### Step 1: Detect Mode

Analyze user request to determine mode:

```
IF request contains specific keyword phrase in quotes → Mode A
   Example: "Write post targeting 'healthy boundaries for empaths'"
   
ELSE IF request mentions specific long-tail keyword → Mode A
   Example: "Write about best email marketing tools for Shopify stores"
   
ELSE IF request is general topic → Mode B
   Example: "Write post about empath boundaries"
   Example: "Create article on email marketing"
```

#### Step 2: Execute Mode-Specific Workflow

**MODE A: Keyword-Driven Workflow**

User has already identified target keyword. Proceed directly to validation:

1. Confirm keyword with user: "I'll optimize this post for '[keyword]'. Confirm?"
2. Collect remaining requirements:
   - Target Audience
   - Content Goal  
   - Author Details (name, credentials, bio, photo URL - critical for E-E-A-T)
   - Word Count Target (1,500-3,000 words)
3. Continue to Phase 2 (Research & Pattern Selection)

**MODE B: Topic Expansion Workflow**

User needs keyword research assistance. Execute keyword research:

1. **Run keyword research script (with credential handling):**

   The script automatically tries multiple credential methods in order:
   1. Command line argument (`--api-key`)
   2. Environment variable (`DATAFORSEO_API_KEY`)
   3. Config file (`~/.dataforseo-skill/config.json`)
   4. Fallback to heuristic mode (no API needed)

   **IMPORTANT FOR CLAUDE CODE ENVIRONMENT:**

   **Option A: Ask user for API key (if they want real data):**
   ```
   Claude: "Would you like to use the DataForSEO API for real keyword data?
           If yes, please provide your API key in format: login:password
           If no, I'll use fallback mode with intelligent estimates."

   IF user provides key:
     python scripts/keyword_research.py "user topic" --limit 5 --format markdown --api-key "user_provided_key"
   ELSE:
     python scripts/keyword_research.py "user topic" --limit 5 --format markdown
   ```

   **Option B: Use fallback mode directly (faster, no credentials needed):**
   ```bash
   # Fallback mode works without any credentials
   python scripts/keyword_research.py "user topic" --limit 5 --format markdown
   ```

   **DO NOT use `--interactive` flag** - it doesn't work in Claude Code's non-TTY environment.

   **Note:** The script automatically falls back to heuristic mode if:
   - No credentials found
   - API call fails (invalid credentials, rate limit, etc.)
   - Script provides intelligent keyword suggestions without API

3. **Present options to user:**
   
   Display top 3-5 keywords with metrics:
   - Search volume (monthly searches)
   - Keyword difficulty (0-100, lower = easier to rank)
   - Relevance score (0-100, higher = better match)
   
   Example output:
   ```
   I've researched keywords for "empath boundaries". Top options:
   
   1. healthy boundaries for empaths (Vol: 2,400, Diff: 45, Score: 95)
   2. empath boundary setting tips (Vol: 1,200, Diff: 38, Score: 88)  
   3. how to set boundaries as an empath (Vol: 3,100, Diff: 52, Score: 92)
   
   Which keyword would you like to target? (or type 'auto' for best match)
   ```

4. **Handle user selection:**

   **Option 1: User selects specific keyword**
   ```
   User: "Let's use #2"
   → Proceed with selected keyword
   ```
   
   **Option 2: User requests auto-selection**
   ```
   User: "auto" or "pick the best one"
   → Select highest relevance score
   → Inform user: "Auto-selected: [keyword] (best relevance score)"
   ```

5. **Collect remaining requirements** (same as Mode A)

6. **Continue to Phase 2**

#### Step 3: Validation & Optimization Notes

For **Mode B** keywords (researched via script):
- Note search volume in outline planning (high volume = more comprehensive content needed)
- Adjust word count based on keyword difficulty:
  - Difficulty 0-30: 1,500-2,000 words sufficient
  - Difficulty 31-60: 2,000-2,500 words recommended
  - Difficulty 61-100: 2,500-3,000+ words required

#### Fallback Handling

If `scripts/keyword_research.py` fails or is unavailable:

1. Inform user: "Keyword research tool unavailable. Using heuristic analysis."
2. Generate 3-5 variations manually using common patterns:
   - "best [topic]"
   - "how to [topic]"  
   - "[topic] guide"
   - "[topic] tips"
   - "[topic] for beginners"
3. Present options with estimated competitiveness
4. Continue workflow normally

### Phase 2: Research and Pattern Selection

**Research Steps:**
1. Identify search intent: Informational, commercial, transactional, or navigational
2. Load `references/seo-checklist.md` → Extract keyword strategy and meta optimization tactics
3. Analyze top-ranking content patterns
4. Gather citation-worthy sources: statistics, studies, expert quotes

**Pattern Selection:**
Load `references/content-patterns.md` and select appropriate structure:
- **Ultimate Guide**: Comprehensive topics (2,000+ words)
- **How-To Guide**: Process-oriented content (1,500-2,500 words)
- **Comparison/Review**: Product comparisons (2,000-3,000 words)
- **Listicle**: Roundups and curated lists (1,000-2,500 words)
- **Data-Driven Research**: Original research posts (2,000-4,000 words)

### Phase 3: Create Outline

Generate structure including:
- SEO-optimized title (primary keyword within first 60 characters)
- Introduction with hook and primary keyword in first 100 words
- 4-8 H2 sections with keyword variations
- FAQ section (4-8 questions minimum)
- Conclusion with clear CTA
- Author bio section

Use `assets/blog-template.md` as structural reference.

### Phase 4: Write Draft

Load `references/eeat-guidelines.md` and apply E-E-A-T principles:

**Experience signals:**
- Include first-hand experiences, testing results, or case studies
- Use specific examples and real scenarios
- Add screenshots, data, or proof when applicable

**Expertise signals:**
- Cite authoritative sources with proper attribution
- Include expert quotes or interviews
- Reference recent studies and statistics (with dates)
- Use precise, accurate terminology

**Authoritativeness signals:**
- Link to authoritative external sources (2-4 per article)
- Build topical clusters with internal links (3-5 per article)
- Demonstrate comprehensive topic coverage

**Trustworthiness signals:**
- Add author bio with credentials
- Include last updated date
- Provide accurate, verifiable information
- Add disclosures where relevant (affiliate links, sponsorships)

**GEO Optimization:**
Load `references/geo-optimization.md` for AI citation formatting:
- Start sections with clear, quotable statements
- Use "According to [Source]" attribution format
- Include statistics with sources and dates
- Structure data in easily extractable formats (tables, lists)
- Provide direct, concise answers in FAQ (40-60 word paragraphs)
- Include "what, why, how" question variations

### Phase 5: Auto Internal Linking (NEW v2.2)

**Automated internal link discovery and insertion:**

1. **Discover existing content from configured sources:**
   ```bash
   # Test content discovery first
   python scripts/content_sources.py \
     --local-content ../website/src/content/blog
   ```

   **Content source priority:**
   1. Sitemap XML (if configured)
   2. Local content directory (`../website/src/content/blog/`)
   3. Fallback to empty (no links inserted)

2. **Auto-insert internal links into draft:**
   ```bash
   python scripts/auto_internal_linking.py /tmp/blog_draft.md \
     --local-content ../website/src/content/blog \
     --min-confidence 90 \
     --max-links 5 \
     --output /tmp/blog_draft_linked.md
   ```

3. **Link insertion process:**
   The script automatically:
   - Discovers existing blog posts from configured sources
   - Analyzes relevance between draft and existing content
   - Identifies high-confidence linking opportunities (≥90 relevance)
   - Inserts markdown links for first keyword occurrence
   - Avoids over-linking (max 5 links by default)

   **Example output:**
   ```
   ✓ Found 50 existing pages for internal linking
   ✓ Found 8 total suggestions
     → 5 high-confidence (≥90)

   ✓ Successfully inserted 5 links:

   1. Email marketing → /blog/email-marketing-guide (95)
   2. Marketing automation → /blog/automation-best-practices (92)
   3. Customer segmentation → /blog/segmentation-strategies (91)
   4. Email campaigns → /blog/campaign-optimization (90)
   5. ROI tracking → /blog/marketing-metrics (90)
   ```

4. **Configuration options:**

   **Via command line:**
   ```bash
   # Local content directory (recommended)
   python scripts/auto_internal_linking.py draft.md \
     --local-content ../website/src/content/blog

   # With sitemap
   python scripts/auto_internal_linking.py draft.md \
     --sitemap-url https://yourdomain.com/sitemap.xml

   # Adjust confidence threshold
   python scripts/auto_internal_linking.py draft.md \
     --local-content ../website/src/content/blog \
     --min-confidence 85  # Lower threshold for more links
   ```

   **Via config file:** `.seo-geo-config.json`
   ```json
   {
     "content_sources": {
       "local_markdown_dir": "../website/src/content/blog"
     },
     "internal_linking": {
       "min_confidence_auto_insert": 90,
       "max_links_per_post": 5
     }
   }
   ```

5. **Continue to Phase 6** (Image Generation) or **Phase 7** (Final Validation)

### Phase 6: Image Generation (NEW v2.2)

**Automated image generation and insertion using AI APIs:**

Generate professional blog post images automatically using Google Imagen or OpenAI DALL-E 3. The system extracts image placeholders, classifies image types, generates appropriate images, and inserts them into your draft.

**1. Add image placeholders to your draft (optional):**

   During Phase 4 (drafting), add placeholders where you want images:
   ```markdown
   ![Email marketing dashboard showing analytics](placeholder)
   ![Workflow diagram showing email automation steps](placeholder)
   ```

   **Note:** Featured/hero image is auto-generated if not present.

**2. Generate images:**

   **Option A - OpenAI DALL-E 3 (easiest setup):**
   ```bash
   export OPENAI_API_KEY=sk-...

   python scripts/image_generation.py /tmp/blog_draft.md \
     --output /tmp/blog_draft_with_images.md \
     --max-images 5
   ```

   **Option B - Google Imagen (requires Google Cloud):**
   ```bash
   export GOOGLE_API_KEY=...
   export GOOGLE_PROJECT_ID=my-project

   python scripts/image_generation.py /tmp/blog_draft.md \
     --output /tmp/blog_draft_with_images.md \
     --max-images 5
   ```

   **Option C - Use configuration file:**
   ```bash
   # Configure in .seo-geo-config.json:
   {
     "image_generation": {
       "enabled": true,
       "google_api_key": "...",
       "google_project_id": "...",
       "openai_api_key": "sk-...",
       "max_images_per_post": 5,
       "output_dir": "./generated_images"
     }
   }

   python scripts/image_generation.py /tmp/blog_draft.md \
     --output /tmp/blog_draft_with_images.md
   ```

**3. Test extraction without API keys (dry-run):**
   ```bash
   python scripts/image_generation.py /tmp/blog_draft.md --dry-run

   # Output shows:
   # - Number of images that would be generated
   # - Image type and style classification
   # - Alt text and context for each image
   ```

**How it works:**

1. **Extract Image Needs:**
   - Finds all `![alt text](placeholder)` patterns
   - Auto-adds featured/hero image if none exists
   - Classifies image type (featured, section, diagram)
   - Determines appropriate style (photorealistic, illustration, diagram)

2. **Generate Images:**
   - Priority 1: Google Imagen ($0.02/image, $2000 startup credit)
   - Priority 2: OpenAI DALL-E 3 ($0.04-$0.08/image, Microsoft credits)
   - Optimized prompts for each style and image type
   - Downloads and saves images locally

3. **Insert Into Draft:**
   - Replaces `(placeholder)` with actual image paths
   - Updates alt text for SEO
   - Preserves markdown formatting

**Image Classification:**

- **Featured/Hero Images:** Photorealistic style, 1792x1024px
  - Trigger: First image or auto-generated from title
  - Example: "Professional email marketing dashboard"

- **Section Images:** Illustration style, 1024x1024px
  - Trigger: Images within content sections
  - Example: "Email list building strategy"

- **Diagrams/Infographics:** Technical diagram style, 1024x1024px
  - Trigger: Keywords like "diagram", "flowchart", "workflow", "infographic"
  - Example: "Email automation workflow diagram"

**Cost tracking:**
The script shows total generation cost and per-image pricing for budget management.

**Generated output structure:**
```
/tmp/blog_draft_with_images.md    ← Updated draft with images
./generated_images/                ← Image directory
  ├── image_abc123.png             ← Featured image
  ├── image_def456.png             ← Section image 1
  └── image_ghi789.png             ← Diagram
```

### Phase 7: Final Validation and Auto-Fix

**Validation Protocol (ALWAYS EXECUTE):**

1. **Write draft to temporary file:**
   ```bash
   # Save draft to /tmp/blog_draft.md
   ```

2. **Execute iterative validation with auto-fix:**
   ```bash
   python scripts/iterative_validation.py /tmp/blog_draft.md \
     --max-iterations 3 \
     --target-score 80 \
     --output /tmp/blog_draft_final.md
   ```

3. **Iterative validation process:**
   The script automatically:
   - Validates current draft state
   - Auto-fixes common issues (FAQ, author bio, schema templates, title length)
   - Re-validates after fixes
   - Stops when: score ≥80 OR max 3 iterations OR no more auto-fixable issues

   **Auto-fixable items:**
   - Missing FAQ section → Generates 4-6 questions from H2 headings
   - Missing author bio → Adds template (user fills details later)
   - Short title (<50 chars) → Expands with year or descriptive phrases
   - Missing schema → Adds BlogPosting and FAQPage templates

   **Non-auto-fixable items** (require manual attention):
   - Low word count → Note thin sections for expansion
   - Missing internal/external links → Needs content research
   - Missing images → Needs image sourcing or generation
   - Low readability score → Needs content restructuring

4. **Interpret results:**
   ```
   Final Score: 88/100

   Fixes Applied (4):
     ✓ Added FAQ section with 6 questions
     ✓ Added author bio template (requires user completion)
     ✓ Expanded title: 'Tips' → 'Complete Tips Guide 2025'
     ✓ Added schema markup templates (requires completion)

   ✓ PASSED (8 checks): Title optimal, Word count good, FAQ present...
   ⚠ WARNINGS (3 items): Internal links low, Images needed...
   ```

   - Score ≥80: Excellent, proceed to delivery
   - Score 60-79: Review warnings, address critical ones
   - Score <60: Fix FAILED checks manually, re-run validation

5. **Complete placeholders in auto-generated content:**
   - **Author bio**: Replace `[Author Name]`, `[job title]`, `[X years]` with real details
   - **Schema markup**: Fill in `[YYYY-MM-DD]`, `[Meta description]`, `[Featured image URL]`
   - **FAQ answers**: Expand auto-generated summaries if needed

6. **Handle script failure:**
   If script unavailable, use manual validation with `references/seo-checklist.md`:
   - Primary keyword in title, H1, first 100 words, URL slug, meta description
   - 2-3 H2 headings with keyword variations
   - Internal links (3-5) and external authority links (2-4)
   - Images with optimized alt text
   - FAQ section with schema markup
   - Author bio with credentials
   - Meta title (50-60 chars) and description (145-155 chars)

7. **Deliver final package:**
   - Complete blog post with auto-fixes applied (`/tmp/blog_draft_final.md`)
   - Validation report showing score and fixes applied
   - Schema markup code blocks (with placeholders to complete)
   - SEO checklist with verification status
   - Image suggestions with alt text
   - Internal linking recommendations

## Resource Loading Strategy

### When to Load Each Reference

**Requirements Phase (Load if needed):**
- Execute `scripts/keyword_research.py` → When Mode B detected (topic expansion needs keyword research)

**Planning Phase (Always load):**
- Read `references/content-patterns.md` → Select appropriate pattern based on topic and search intent

**Research Phase (Load if needed):**
- Read `references/seo-checklist.md` → When conducting keyword research or meta optimization
- Read `references/geo-optimization.md` → When planning citation-worthy formatting

**Draft Phase (Load selectively):**
- Read `references/eeat-guidelines.md` → When writing sections requiring credibility signals
- Use `assets/blog-template.md` → As structural reference for section organization

**Validation Phase (Always execute):**
- Execute `scripts/validate_structure.py` → After completing draft
- Read `assets/structured-data-examples.json` → When generating schema markup

### Token Efficiency for Large Files

`references/content-patterns.md` is 758 lines. For targeted reading:
```bash
# Read only specific pattern instead of entire file
grep -A 100 "## Pattern 2: How-To Guide" references/content-patterns.md
```
This approach: ~400 tokens vs ~3,000 tokens for full file.

## Output Deliverables

Provide complete package:
1. Blog post in markdown (using `assets/blog-template.md` structure)
2. SEO checklist with verification status for each item
3. Schema markup code blocks (BlogPosting + FAQPage)
4. Image suggestions with optimized alt text
5. Internal linking recommendations with anchor text
6. Validation report from script execution

## Critical Requirements (What NOT to Do)

Avoid these quality-damaging practices:
- Thin content (<1,000 words for competitive topics)
- Keyword stuffing (maintain natural readability)
- Unverifiable claims or missing citations
- Missing author credibility (E-E-A-T critical for rankings)
- Poor mobile readability (short paragraphs required)
- Clickbait tactics (damages trustworthiness signals)
- Copying competitor content (use as pattern inspiration only)
- Skipping FAQ section (critical for GEO optimization)
- Missing schema markup (required for rich results)
- No author bio (damages E-E-A-T scoring)

## Quality Targets

Target these metrics for optimal performance:
- Readability score: 60-70 (Flesch Reading Ease)
- Keyword density: 1-2% for primary keyword
- Heading hierarchy: Proper H1 → H2 → H3 structure
- FAQ section: 4-8 questions with schema markup
- Internal links: 3-5 with descriptive anchor text
- External links: 2-4 to authoritative sources
- Images: 5-8 with optimized alt text
- Word count: 1,500-3,000 (adjust for competition)
- E-E-A-T signals: Author bio, citations, first-hand experience
- Schema markup: BlogPosting + FAQPage minimum

## Optimization Factors for Best Results

**Input Quality:**
- Specific topic details improve output precision
- Real author credentials significantly improve E-E-A-T scoring
- Existing case studies or data enhance content quality
- Clear target audience definition enables better targeting

**Process Optimization:**
- Request outline approval before full draft to ensure direction alignment
- Execute validation script to catch structural issues early
- Plan content refresh every 6-12 months for freshness signals

## Related Skills

- **blog-optimizer**: Improve existing posts (different workflow from creation)
- **content-repurposer**: Convert blog posts to other formats (separate use case)