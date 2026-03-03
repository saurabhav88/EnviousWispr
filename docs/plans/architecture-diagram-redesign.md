# Architecture Diagram Redesign Plan

**Date:** 2026-03-01
**File:** `docs/architecture-diagram.html`
**Served at:** `http://localhost:8765/architecture-diagram.html`

## Problem Summary

- Green ellipse artifact stuck behind Pipeline card (line 1060)
- Code members/functions meaningless to non-developers
- Fonts too small, layout too sprawling (2400x1600)
- Technical language instead of plain English
- Target audience: layman users, potential customers, investors

## Key Changes

### 1. Consolidate 17 modules → 9 modules

| New Module | Merged From | Layman Description |
|---|---|---|
| **Core App** | AppState, AppDelegate, MenuBarIconAnimator | Manages the app's main functions, menu bar icon, and updates |
| **Microphone Input** | AudioCaptureManager, AudioDeviceManager | Listens for your voice using the selected microphone |
| **Silence Detector** | SilenceDetector | Detects when you start and stop speaking for clean recordings |
| **Speech-to-Text Engine** | ASRManager, ParakeetBackend, WhisperKitBackend | Converts your spoken words into raw text |
| **Transcription Pipeline** | TranscriptionPipeline | Orchestrates the entire journey from voice to finished text |
| **AI Text Polishing** | TextProcessingStep, LLM Connectors, PostProcessing | Corrects errors, adds punctuation, and refines grammar using AI |
| **System Integration** | Services | Handles pasting text, permissions, and global hotkeys |
| **Transcription History** | TranscriptStore | Stores all your past transcriptions on-device |
| **User Interface** | Views | Settings windows, history lists, and controls you interact with |
| ~~Models~~ | *Removed* | Pure developer concept — no value for layman audience |

### 2. Layout: Left-to-right "Product Journey"

4 columns telling the story: **Capture → Transcribe → Refine → Finalize**

```
        CAPTURE          TRANSCRIBE           REFINE            FINALIZE
                       ┌─────────────┐
                       │  Core App   │
                       └─────────────┘
┌─────────────┐   ┌─────────────────┐   ┌──────────────┐   ┌──────────────────┐
│  Microphone │ → │ Speech-to-Text  │ → │  AI Text     │ → │ System           │
│  Input      │   │ Engine          │   │  Polishing   │   │ Integration      │
└─────────────┘   └─────────────────┘   └──────────────┘   └──────────────────┘
                  ┌─────────────────┐   ┌──────────────┐   ┌──────────────────┐
                  │ Silence         │   │ Transcription│   │ Transcription    │
                  │ Detector        │   │ Pipeline     │   │ History          │
                  └─────────────────┘   └──────────────┘   └──────────────────┘
                                        ┌──────────────┐
                                        │ User         │
                                        │ Interface    │
                                        └──────────────┘
```

### 3. Canvas & Card Sizing

- **Canvas:** 1440x720 (down from 2400x1600 — 75% reduction)
- **Cards:** 240x110px (down from 300-380 x 200-260)
- **Title font:** 18px semi-bold (up from 14px)
- **Description font:** 14px regular (up from 11px)
- **Card border radius:** 12px
- **Accent bar:** 4px colored left border
- **Horizontal gaps:** 100px between columns
- **Vertical gaps:** 60px between rows
- **Outer margins:** 80px

### 4. Remove entirely

- All `var`, `func`, `struct`, `enum` member listings
- All Swift type annotations (`@MainActor @Observable class`)
- The green ellipse glow behind Pipeline (line 1060)
- The `Models` card
- Separator lines inside cards

### 5. Keep & enhance

- Dark theme + category colors (rainbow palette)
- Card-based layout with colored accent bars
- Manhattan-routed connection lines (simplified to ~8-10 key connections)
- Data flow animation dots
  - Primary flow: thicker (2px), brighter, prominent animation
  - Secondary/control: thinner (1px), dimmer, subtle or no animation
- Search bar
- Legend
- Pan/zoom
- Detail panel (rewritten with benefit-oriented content)
- Dot-grid background
- Bottom flow summary → `Hotkey Press → Microphone Input → Speech-to-Text → AI Polishing → Paste to App`

### 6. New additions

- **Icons** next to each module name (SF Symbols / emoji style):
  - Core App → app badge
  - Microphone Input → mic
  - Silence Detector → waveform
  - Speech-to-Text Engine → brain/cpu
  - Transcription Pipeline → flow arrows
  - AI Text Polishing → sparkles
  - System Integration → keyboard
  - Transcription History → books
  - User Interface → window
- **Column headers** ("Capture", "Transcribe", "Refine", "Finalize") as large muted labels (24px, 700 weight, 40% opacity)
- **Detail panel redesign:**
  - Large icon (48x48)
  - Module title
  - "What it Does" — benefit-oriented paragraph
  - "Key Responsibilities" — bulleted checklist
  - "Connects To" — plain English connection list

### 7. Connection Map (simplified)

Primary flow (thick, animated):
1. Microphone Input → Speech-to-Text Engine (audio data)
2. Speech-to-Text Engine → AI Text Polishing (raw transcript)
3. AI Text Polishing → System Integration (polished text)

Secondary connections (thin, subtle):
4. Core App → Microphone Input (controls recording)
5. Core App → System Integration (hotkey registration)
6. Silence Detector → Speech-to-Text Engine (speech boundaries)
7. Transcription Pipeline → Speech-to-Text Engine (triggers transcription)
8. Transcription Pipeline → AI Text Polishing (triggers polishing)
9. System Integration → Transcription History (stores result)
10. User Interface → Core App (settings & controls)

### 8. Bottom Flow Summary

**Old:** `Hotkey → AudioCapture → [VAD] → ASR → Pipeline → [LLM Polish] → [WordCorrection] → Store → Clipboard → Paste`

**New:** `Hotkey Press → Microphone Input → Speech-to-Text → AI Polishing → Paste to App`

## Gemini Design Feedback (2026-03-01)

- Consolidation from 17→9 modules is essential for layman audience
- Left-to-right narrative layout > grid layout — tells the product story
- Canvas 1440x720 is optimal for the reduced module count
- Connection hierarchy (primary thick/bright vs secondary thin/dim) guides the eye
- Detail panel should be a "mini feature page" not a code reference
- Icons add professional polish without clutter if kept consistent
- Column headers reinforce the Record→Transcribe→Polish→Paste narrative
- Remove Models card entirely — pure developer concept
