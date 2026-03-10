# EnviousWispr Homepage Copy

All copy for the homepage, organized by section. Two hero options provided.

---

## 1. Hero Section

### Option A: "Talk naturally. Paste perfectly."

**Badge:** macOS App

**Headline:** Talk naturally. Paste perfectly.

**Subheadline:** On-device AI dictation for macOS. Record your voice, get polished text — grammar-fixed, filler-free, pasted into any app in under 2 seconds.

**CTA Primary:** Download for macOS
**CTA Secondary:** View on GitHub

---

### Option B: "Speak. Polish. Paste."

**Badge:** macOS App

**Headline:** Speak. Polish. Paste.

**Subheadline:** AI dictation that runs entirely on your Mac. Talk naturally, get clean text — grammar fixed, filler words removed, auto-pasted wherever you're typing.

**CTA Primary:** Download for macOS
**CTA Secondary:** View on GitHub

---

## 2. Pipeline Section — "How It Works"

**Section label:** How It Works
**Section headline:** Four steps. Under two seconds.
**Section subheadline:** A streaming pipeline that starts transcribing while you're still talking.

### Step 1: Record
**Icon suggestion:** Microphone
**Headline:** Record
**Description:** Press your hotkey. Talk naturally. Push-to-talk or toggle — your choice. A floating overlay shows your waveform in real time.

### Step 2: Transcribe
**Icon suggestion:** Waveform / Brain
**Headline:** Transcribe
**Description:** Parakeet v3 runs on Apple's Neural Engine at 110x real-time speed. Streaming ASR begins transcribing while you're still speaking.

### Step 3: Polish
**Icon suggestion:** Sparkle / Magic wand
**Headline:** Polish
**Description:** An LLM removes filler words, fixes grammar, and cleans up punctuation. Choose from OpenAI, Gemini, Ollama, or Apple Intelligence.

### Step 4: Paste
**Icon suggestion:** Clipboard / Arrow into document
**Headline:** Paste
**Description:** Polished text lands on your clipboard and auto-pastes into the app you were using. Your previous clipboard is preserved.

---

## 3. Speed Section

**Section label:** Speed
**Section headline:** 1.6 seconds from silence to paste.
**Section subheadline:** Most dictation apps wait until you stop talking to start working. EnviousWispr doesn't.

### The streaming pipeline story

**Block 1 — Streaming ASR**
**Stat:** 110x real-time
**Description:** Transcription starts the moment you begin speaking. Parakeet v3 processes audio on Apple's Neural Engine while you're still talking — not after.

**Block 2 — LLM Pre-warm**
**Stat:** 0ms cold start
**Description:** HTTP/2 connections to your LLM provider are pre-warmed at recording start. When transcription finishes, the polish request fires instantly.

**Block 3 — SSE Streaming**
**Stat:** First token in ~200ms
**Description:** Polished text streams back word-by-word via Server-Sent Events. You see the result forming before the LLM finishes generating.

**Block 4 — Auto-paste**
**Stat:** 1.6s total
**Description:** From the moment you release the hotkey to polished text appearing in your app. Record, release, done.

---

## 4. Features Grid

**Section label:** Features
**Section headline:** Everything you need. Nothing you don't.
**Section subheadline:** Built for people who think faster than they type.

### Card 1: On-Device Transcription
**Icon suggestion:** Chip / CPU
**Headline:** On-device transcription
**Description:** Parakeet v3 and WhisperKit run entirely on your Mac. No internet required. No audio uploaded. Ever.

### Card 2: Smart Polish
**Icon suggestion:** Sparkle
**Headline:** Smart polish
**Description:** LLM-powered cleanup removes filler words, fixes grammar, and formats your text. Editable prompts with presets for Clean Up, Formal, and Casual styles.

### Card 3: Voice Activity Detection
**Icon suggestion:** Sound wave
**Headline:** Voice activity detection
**Description:** Silero VAD with smoothed probability tracking, 512ms prebuffer for word onset capture, and configurable silence timeout. Records only what matters.

### Card 4: Works Everywhere
**Icon suggestion:** Grid of app icons
**Headline:** Works in any app
**Description:** Auto-pastes into whatever app you were using — Slack, VS Code, Gmail, Notes, Terminal. Your previous clipboard contents are saved and restored.

### Card 5: Push-to-Talk & Toggle
**Icon suggestion:** Keyboard
**Headline:** Push-to-talk & toggle
**Description:** Hold a key to record, or press once to start and again to stop. Customizable hotkeys. Cancel anytime with Escape.

### Card 6: Multiple LLM Providers
**Icon suggestion:** Plug / Connection
**Headline:** Four LLM providers
**Description:** OpenAI, Google Gemini, Ollama (local), and Apple Intelligence. API keys stored in macOS Keychain. Switch providers without losing credentials.

### Card 7: Custom Word Correction
**Icon suggestion:** Dictionary / Spell check
**Headline:** Custom word correction
**Description:** Teach it your jargon. Add names, acronyms, and technical terms to a personal dictionary. Phonetic and edit-distance matching handles misheard words.

### Card 8: Native macOS
**Icon suggestion:** macOS logo / Swift bird
**Headline:** Native macOS app
**Description:** Built in Swift 6 with SwiftUI. Lives in your menu bar. No Electron. No WebView. Feels like it belongs on your Mac because it does.

---

## 5. Privacy Section

**Section label:** Privacy
**Section headline:** Your voice never leaves your Mac.
**Section subheadline:** On-device transcription means your audio stays on your hardware. No cloud ASR. No recordings stored on remote servers. No telemetry.

### Point 1
**Headline:** On-device ASR
**Description:** Both speech engines — Parakeet v3 and WhisperKit — run locally on Apple Silicon. Audio is processed in-memory and never written to disk.

### Point 2
**Headline:** Keychain-secured credentials
**Description:** API keys for LLM providers are stored in macOS Keychain, not config files. The same security that protects your passwords protects your keys.

### Point 3
**Headline:** Optional LLM polish
**Description:** The only network call is the optional LLM polish step — and you control the provider. Use Ollama for fully offline operation. Or skip polish entirely.

### Point 4
**Headline:** Source available
**Description:** Every line of code is on GitHub. Audit the source. Verify the claims. No trust required.

---

## 6. Stats / Numbers Section

**Section label:** By the Numbers
**Section headline:** Built different.

| Stat | Label |
|------|-------|
| 110x | Real-time transcription speed |
| 1.6s | Silence to paste |
| 2 | ASR engines |
| 4 | LLM providers |
| 0 | Audio bytes uploaded |
| 60+ | Swift source files |

---

## 7. Source Available CTA

**Section headline:** Source available. Open roadmap.
**Section subheadline:** EnviousWispr is built in the open. Read the code, file issues, suggest features, or contribute directly. Licensed under BSL 1.1.

**CTA button:** View on GitHub
**CTA link:** https://github.com/saurabhav88/EnviousWispr

**Supporting text:** Contributions welcome. Built with Swift 6, SwiftUI, and Apple's Neural Engine APIs.

---

## 8. Download / Getting Started

**Section headline:** Start dictating in 30 seconds.

### Step 1
**Label:** Download
**Description:** Grab the latest DMG from GitHub Releases. Drag to Applications.

### Step 2
**Label:** Grant permissions
**Description:** Microphone access for recording. Accessibility for auto-paste. A guided setup walks you through both.

### Step 3
**Label:** Press your hotkey
**Description:** Control+Space to toggle. Option+Space to push-to-talk. Talk naturally. Release. Done.

**CTA button:** Download for macOS

---

## 9. Footer

**Left column:**
EnviousWispr
AI dictation for macOS. By Envious Labs.

**Links column 1 — Product:**
- Download
- GitHub
- Releases
- Changelog

**Links column 2 — Resources:**
- Documentation
- Feature Requests
- Report a Bug

**Bottom bar:**
Built with Swift and SwiftUI on macOS. Source available on GitHub.

---

## Microcopy & Incidentals

**Menu bar tooltip:** EnviousWispr — AI Dictation

**404 page headline:** Nothing to transcribe here.
**404 subtext:** This page doesn't exist. But your voice does — go back and dictate something.

**Loading state:** Warming up the Neural Engine...

**Empty state (no transcripts):** Press your hotkey and start talking. Your first transcript will appear here.
