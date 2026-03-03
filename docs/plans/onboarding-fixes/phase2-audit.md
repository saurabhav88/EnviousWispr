# Phase 2 Audit — UI Polish (Gemini Review)

## Issue 1: API Key Placeholder — DYNAMIC PER PROVIDER

### Key audit findings:
1. "Enter API key here" is verbose and not idiomatic macOS
2. Primary action is PASTING, not typing
3. Should be dynamic per provider

### Revised recommendation:
- **Placeholder:** "Paste your [Provider] API key" (e.g., "Paste your OpenAI API key")
- **Caption below:** "Your key should start with `sk-...`" (monospaced prefix)
- Caption stays visible even when typing (unlike placeholder)
- If key doesn't match prefix, show inline error in caption area

---

## Issue 2: Fonts — CRITICAL ACCESSIBILITY FIX

### Major finding: Fixed point sizes ignore Dynamic Type
- `.system(size: 24, ...)` does NOT scale with accessibility settings
- Must use semantic Font.TextStyle for accessibility compliance

### Revised font scale:
| Category | Recommended | Notes |
|----------|------------|-------|
| Display Heading | `Font.title.bold()` | Use .rounded ONLY here |
| Heading | `Font.title2.bold()` | Standard design, not rounded |
| Subheading | `Font.headline` | Semantic, not weighted body |
| Body | `Font.body` | Scales with Dynamic Type |
| Caption | `Font.caption` | Accessible |
| Monospaced | `Font.body.monospaced()` | Scales with body |

### .rounded usage:
- Only for display heading, not all headings
- Can look less crisp at non-integer scaling on some displays

### Heading size decision:
- Keep 22pt (via .title style) — matches macOS convention
- Don't bump to 24pt

---

## Issue 3: Colors — KEEP BRAND, USE SEMANTIC FOR TEXT

### Key audit findings:
1. Hardcoded colors violate accessibility (Dynamic Type, Increased Contrast, Dark Mode)
2. BUT: completely replacing with system colors loses brand personality
3. **Strategy:** semantic colors for TEXT, brand purple for INTERACTIVE elements only

### Revised color plan:
- `obTextPrimary` → `Color.primary`
- `obTextSecondary` → `Color(NSColor.secondaryLabelColor)`
- `obTextTertiary` → `Color(NSColor.tertiaryLabelColor)`
- `obAccent` → KEEP for buttons, links, focus rings, progress indicators
- `obBg`, `obSurface`, `obCardBg` → Keep as-is (background branding is fine)

### Dark Mode consideration:
- Current palette is light-only — OK for now since onboarding is light-themed
- But text using Color.primary will auto-adapt if Dark Mode support is added later
