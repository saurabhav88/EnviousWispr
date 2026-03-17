# 020 — Settings UI Refresh for Consumer Readiness

**Status:** In Progress (ew-byi)
**Priority:** P1
**Type:** Feature

## Goal

Redesign all settings pages to be consumer-friendly. Remove developer jargon, write for someone who just wants dictation to work. Apply brand design system consistently. Approve each page via HTML mockup before implementing in Swift.

## Approach

Page-by-page: mockup → approve → implement in Swift → build validate → next page.

## Priority Order (highest impact first)

1. **Speech Engine** — Most jargon-heavy, biggest UX win (VAD presets, etc.)
2. **AI Polish** — Complex, overwhelming for new users
3. **Memory** — Quick win, jargon removal
4. **Diagnostics** — Hide behind debug mode, clean up
5. **Audio** — Minor copy tweaks
6. **Shortcuts** — Minor polish
7. **Custom Words** — Minor copy
8. **Clipboard** — Minor copy
9. **Permissions** — Already fine

## Page-by-Page Rewrite Plan

---

### 1. Speech Engine (MAJOR REWORK)

**Current sections:** ASR Backend, WhisperKit Quality, Voice Activity Detection, Post-Processing

**Proposed restructure:**

#### Section: "Transcription Engine"
- Segmented picker: keep but rename options
  - "Fast (English)" instead of "Parakeet v3 (Primary)"
  - "Multi-Language" instead of "WhisperKit (Fallback)"
- Helper text: same content, friendlier copy

#### Section: "Multi-Language Options" (conditional, replaces "WhisperKit Quality")
- "Auto-detect language" toggle — keep, copy is fine
- "Accuracy" slider (replaces "Temperature") — "Lower = more consistent, higher = more creative"
- "Speech filter" slider (replaces "No-speech threshold") — "How aggressively to filter silence"

#### Section: "Recording Environment" (replaces "Voice Activity Detection")
- **3 preset cards** replacing VAD Sensitivity slider:
  - Quiet — "Library, bedroom, quiet office"
  - Normal — "Home, private office" (default)
  - Noisy — "Open office, café, outdoors"
- "Stop recording on silence" toggle (replaces "Auto-stop on silence")
  - "Pause duration" slider when enabled (replaces "Silence timeout")
- Energy pre-gate: REMOVE from UI, auto-enable in code

#### Section: "Cleanup" (replaces "Post-Processing")
- "Remove filler words (um, uh, hmm...)" — keep as-is, copy is fine

---

### 2. AI Polish (MAJOR REWORK)

**Current sections:** LLM Provider, Model Guide, Advanced, API Key sections, Ollama setup, Apple Intelligence

**Proposed restructure:**

#### Section: "AI Enhancement"
- Provider picker — rename options:
  - "Off" instead of "None"
  - "OpenAI" — keep
  - "Google Gemini" — keep
  - "Local (Ollama)" instead of "Ollama (Local)"
  - "Apple Intelligence" — keep
- Helper when Off: "Turn on AI enhancement to automatically fix grammar, punctuation, and formatting."

#### Section: "Model" (conditional)
- Model picker — keep
- Model guide — simplify to just recommended badge, remove "Overkill" label (feels judgmental)
  - Use "Best value" / "Also great" / "Premium" / "Budget"
- System prompt — rename to "Custom instructions"
  - "Using default instructions" / "Custom instructions active"
  - Button: "Edit Instructions" instead of "Edit Prompt"

#### Section: "API Key" (conditional, per provider)
- Same structure, cleaner copy
- "Get your free API key" (link) — emphasize "free" for new users
- Validation feedback — keep

#### Section: "Ollama Setup" (conditional)
- Keep the step-by-step wizard, but friendlier copy
- "Ollama runs AI models on your Mac — no internet or API key needed."

#### Section: "Advanced" (conditional)
- "Extended thinking" toggle — rename to "Deep reasoning"
- Helper: "Takes longer but handles complex formatting instructions better."

---

### 3. Memory (QUICK WIN)

**Current:** "Unload model after" picker

**Proposed:**

#### Section: "Performance"
- "Free memory when idle" picker — rename options to:
  - "Never" → "Keep model loaded (fastest)"
  - "After 5 min" → "After 5 minutes idle"
  - "Immediately" → "After each recording (saves memory)"
- Helper: "The speech model uses ~200-500 MB of RAM. Unloading frees memory but the next recording takes a few seconds to reload."

---

### 4. Diagnostics (MODERATE)

**Proposed:** Move ALL diagnostic content behind the debug mode toggle. When debug mode is off, show only:

#### Section: "Troubleshooting"
- "Enable debug mode" toggle
- Helper: "Shows advanced diagnostic tools and detailed logging."

When debug mode is on, show current content with minor copy tweaks.

---

### 5-9. Minor Pages

**Audio:** "Input Device" → "Microphone", helper copy is already good. "Noise suppression" → "Reduce background noise".

**Shortcuts:** Mostly fine. "Push to Talk" / "Toggle" descriptions are clear.

**Custom Words:** "Custom Word List" section title → "Your Words". Helper copy is fine.

**Clipboard:** Already clean. Maybe rename "Restore clipboard after paste" → "Keep your clipboard intact".

**Permissions:** Already fine, no changes needed.

## Sidebar Navigation Rename

| Current | Proposed |
|---------|----------|
| APP > History | APP > History (keep) |
| RECORD > Speech Engine | RECORD > Transcription |
| RECORD > Audio | RECORD > Microphone |
| RECORD > Shortcuts | RECORD > Shortcuts (keep) |
| PROCESS > AI Polish | PROCESS > AI Enhancement |
| PROCESS > Custom Words | PROCESS > Your Words |
| OUTPUT > Clipboard | OUTPUT > Clipboard (keep) |
| SYSTEM > Memory | SYSTEM > Performance |
| SYSTEM > Permissions | SYSTEM > Permissions (keep) |
| SYSTEM > Diagnostics | SYSTEM > Diagnostics (keep) |

## Mockup Location

All mockups saved to `docs/mockups/settings-refresh/` with naming: `{page-name}.html`

## Implementation Notes

- Each page implemented as a Swift PR after mockup approval
- Build validate after each page (`wispr-run-smoke-test`)
- Full UI verification after all pages done (`wispr-eyes`)
- Brand accent purple (#7c3aed) replaces default blue in SwiftUI `.tint()` modifier
