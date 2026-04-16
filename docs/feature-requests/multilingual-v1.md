# Multilingual v1: 99-language auto-detect with hidden Lock language

Status: planning. Date: 2026-04-12.

## North Star

Ship all 99 Whisper-supported languages, auto-detect by default, no primary picker. Hidden "Lock language" escape hatch for short clips, close-language collisions, and bilingual daily users. Positioning: 99 languages, fully on-device, always free, no weekly caps, works offline.

## Why now

Competitive recon (2026-04-12) confirmed all three major competitors are cloud-based: WisprFlow (Supabase + Stripe, Electron, no on-device ASR), SuperWhisper (`sw-ultra-cloud-v1-east`, empty local models dir), Edge Eloquent (Google Firebase, Flutter, Mac Catalyst). Their "99 languages" claim is a server-side capability + UX smoothing, not manual native-speaker parity. EnviousWispr is genuinely on-device. The on-device 99-language story is MORE defensible, not less.

Council pressure-tested by GPT-5.4 and Gemini 2.5-Flash (2026-04-12). Both converged on: autodetect default is right, hidden manual lock is mandatory, `large-v3-v20240930_turbo` is the right model, multi-layer autodetect is the real engineering lever, prompt injection must split formatting from lexical and go language-aware.

Supersedes existing issue #165.

## Scope

### In

1. UI: replace en/de/ta segmented picker with `Auto` toggle and hidden "Lock language" sheet listing all 99 languages with search and recents.
2. Autodetect stack: voiced-duration gate, multi-window `detectLanguage()`, confidence + margin thresholds with abstain, session language memory with anti-flap, script-mismatch guardrail. Top-2 fallback decode deferred to v2 pending real-world LID failure data.
3. Prompt injection rearchitecture: formatting-only vs lexical split, per-language vocabulary map, confidence-tiered injection (Tier A locked/high-confidence, Tier B medium, Tier C low).
4. Model swap: default to `openai_whisper-large-v3-v20240930_turbo`. 24-hour feature flag for rollout safety. Cache migration for existing users.
5. Eval harness: FLEURS + Mozilla Common Voice downloaders, scorer for WER (Latin/Cyrillic/Indic/Arabic) and CER (ja/zh/ko, plus whitespace-WER for Korean). 30 clips per language weekly, 100 clips for top 20. Reuses existing `scripts/multilingual-eval/` runner + scorer.
6. Telemetry: PostHog events for `language_detected`, `language_confidence`, `duration_bucket`, `manual_lock_used`, `language_flip`, `correction_after_insert`, `session_stability`. Sentry breadcrumbs for LID aborts and script-guardrail rejections.

### Out (v2 or later)

- Top-2 fallback decode (expensive, adds only if v1 data shows 5%+ LID failure rate).
- ElevenLabs synthetic speech (paid tool rejected, zero revenue context).
- Per-language prompt template packs beyond formatting-only plus English custom vocab.
- Translation mode (`task: .translate`) as a user-facing feature.
- Hindi/Tamil/Gujarati numeric normalization post-ASR (tracked separately if benchmark shows impact).
- Per-app context catalog (SuperWhisper-style `bundled_app_info.json`). Tracked as separate future feature after v1 ships.

## Architecture

### Tier classification

LARGE. Touches ASR backend, Pipeline, Services, UI. Requires Architecture DoD, council review (done), Periphery scan, both backends validation (Parakeet is unaffected but Pipeline wiring touched), GPT sign-off on final code.

### Heart and limbs

Heart: `Hotkey → Audio → WhisperKit transcribe → text → clipboard`. Still completes if LID abstains (falls back to session-locked language or the user's current Lock language). Still completes if prompt injection fails (transcribes without lexical bias).

Limb: language-aware prompt injection, session memory, script guardrail, telemetry. All must fail open.

### Module placement

- `EnviousWisprASR`: new `LanguageDetector` actor (wraps WhisperKit's `detectLanguage` with multi-window aggregation, confidence + margin logic, script guardrail). Lives alongside `WhisperKitBackend`.
- `EnviousWisprCore`: new types `LanguageDetectionResult`, `LanguageConfidenceTier` (`.locked`, `.highAuto`, `.mediumAuto`, `.lowAuto`, `.abstain`), `SessionLanguageMemory`.
- `EnviousWisprServices`: `SettingsManager` gains `languageMode: LanguageMode` (`.auto` or `.locked(code)`). `whisperKitLanguage` kept for migration, deprecated. Telemetry events added to `TelemetryService`.
- `EnviousWisprLLM`: `CustomVocabularyFormatter` extended to be language-aware. Prompt builders consume per-language vocab + confidence tier.
- `EnviousWisprPipeline`: `WhisperKitPipeline` consults `LanguageDetector` before `transcribe()`. `transcriptionOptions.language` populated from detector result (nil if abstaining, which lets WhisperKit's own detection proceed).
- `EnviousWispr` (app): `SpeechEngineSettingsView` replaces segmented picker with `Auto` toggle and "Lock language" sheet.

### Dependency direction

No lower module imports upward. `LanguageDetector` depends on `EnviousWisprCore` only. `WhisperKitPipeline` owns the detector call site.

## Languages (all 99)

Whisper-supported ISO codes. The picker UI will show native-script names.

```
af am ar as az ba be bg bn bo br bs ca cs cy da de el en es et eu
fa fi fo fr gl gu ha haw he hi hr ht hu hy id is it ja jw ka kk
km kn ko la lb ln lo lt lv mg mi mk ml mn mr ms mt my ne nl nn
no oc pa pl ps pt ro ru sa sd si sk sl sn so sq sr su sv sw ta te
tg th tk tl tr tt uk ur uz vi yi yo yue zh
```

## Autodetect stack (detailed spec)

### Layer 1: speech gate

Before calling `detectLanguage`, ensure the clip has enough voiced speech.

- Required: voicedDuration greater than or equal to 1.0s for provisional LID, greater than or equal to 2.5s for confident LID. Derived from existing `SilenceDetector` speech segments (already computed post-recording).
- Short-clip policy: less than 1.0s voiced means no LID call; use session-locked or sticky language or fall through to WhisperKit's internal LID without our gating.

### Layer 2: multi-window LID

On audio greater than or equal to 2.5s, run `detectLanguage` on up to 4 overlapping windows: 0 to 3s, 1 to 4s, 2 to 6s, full voiced segment capped at 12s. Aggregate via arithmetic mean of probabilities per language.

Accept top-1 result only if:
- top-1 probability greater than or equal to 0.65 AND
- top-1 minus top-2 margin greater than or equal to 0.20

For voiced duration less than 2.5s: stricter thresholds (top-1 greater than or equal to 0.80, margin greater than or equal to 0.25). If stricter thresholds fail, abstain and fall back to sticky or session-locked language.

### Layer 3: session memory

`SessionLanguageMemory` holds:
- Recency-weighted last 10 accepted languages for the session.
- Last 24-hour usage per language (persisted in UserDefaults).
- Last manual Lock language value (highest priority when set).

Anti-flap rules:
- If the same language is accepted with high confidence twice in a row, mark as session-preferred and boost by +0.10 in later low-confidence decisions.
- Only switch away from session-preferred if the new language shows probability greater than or equal to 0.85 AND margin greater than or equal to 0.25 on two consecutive utterances.

Session timeout: 10 minutes of inactivity clears session-preferred; 24-hour cache persists.

### Layer 4: script-mismatch guardrail

If the detected language has a non-Latin script (ar, bg, bn, el, gu, he, hi, ja, ka, km, kn, ko, lo, ml, mr, my, ne, pa, ru, sa, si, sr, ta, te, th, uk, ur, yi, yue, zh), and a proposed prompt token string contains Latin characters tagged as `global`, allow it. If the same is ungated (not `global`), strip before passing to the decoder.

### Layer 5: UX fallback

Never modal. Show passive chip "Detected: Japanese. Lock it?" only when LID flip-flops twice in five minutes OR two low-confidence detections in a session OR a user correction follows a likely bad transcript.

## Prompt injection rearchitecture

### Prompt storage shape

```swift
struct PromptVocabulary {
    var global: [String]          // True cross-lingual entities: product names, URLs
    var perLanguage: [String: [String]] // lang code -> terms specific to that language
}
```

`global` is always safe to inject. `perLanguage` only injects when detected language matches the key AND confidence tier is Locked or HighAuto.

### Confidence-tiered injection

| Tier | When | Inject |
|---|---|---|
| Locked | User selected Lock language | Full lexicon for that language + global |
| HighAuto | Top-1 greater than or equal to 0.80 AND margin greater than or equal to 0.25 AND matches session prior | Full lexicon for detected + global |
| MediumAuto | Top-1 greater than or equal to 0.65 AND margin greater than or equal to 0.20 | Formatting-only + global |
| LowAuto | All else | No lexical prompt. Formatting-only. |

Formatting-only prompt is language-neutral: punctuation, capitalization, line-break style. No lexical content.

### Migration of existing custom-words

Existing `CustomWordsManager` entries are untagged. Migration: treat all as `global` on first launch after upgrade (safe default since most are product names and proper nouns). Ship a per-entry language tag in the UI as a v2 enhancement.

## Model swap

### From and to

From: `openai_whisper-large-v3_turbo` (current default in `WhisperKitBackend.init`, `SettingsManager`, `ASRServiceHandler`, `WhisperKitSetupService`).

To: `openai_whisper-large-v3-v20240930_turbo`. OpenAI's 2024-09-30 multilingual refresh, turbo decoder speed.

Argmax-published. Available at `argmaxinc/whisperkit-coreml` (confirmed via HuggingFace API 2026-04-12).

### Rollout

- Day 1: ship new model as default with `whisperKitModelVariant` settings key (new), defaulting to the new model. Existing users' `whisperKitModel` key preserved for 2 releases as fallback if the new model download fails.
- Feature flag `useRefreshedWhisperKitModel` (defaults true) for emergency rollback via defaults write.
- Cache migration: both old and new variants live in the same HF cache directory. `WhisperKitSetupService.getLocalModelPath` already uses fuzzy matching; no cache migration code needed.
- Blast radius floor: no regression on en, de, or ta beyond 0.5 absolute WER points (measured pre-merge via eval harness).

## Eval harness (reusing existing work)

Build on the existing `scripts/multilingual-eval/` work:
- `tts_generate.py` (already written) for synthetic regression tests
- `runner/` Swift CLI (already written) for WhisperKit batch transcription
- `score.py` (already written) for WER/CER scoring

New additions:
- `fleurs_download.py`: pull FLEURS dev-set clips + transcripts for all 99 languages (Common Voice overlap)
- `commonvoice_download.py`: pull Common Voice validated clips (fallback where FLEURS thin)
- `eval_all.sh`: orchestrate download -> transcribe -> score across all 99
- Update `score.py` to emit per-language tier assignment (Ship/Strong/Acceptable/Do-not-expose) and cross-model comparison tables
- Korean CER + whitespace-WER dual metric

Target cadence: weekly automated run, results committed to `benchmark-results/multilingual-weekly/YYYY-MM-DD/`.

## Telemetry

New PostHog events (filter by `environment=production`):

| Event | When | Properties |
|---|---|---|
| `language_detected` | After LID completes | `lang`, `confidence`, `margin`, `duration_bucket` (1-2.5s, 2.5-5s, 5-10s, 10-15s, 15s+), `abstained` (bool), `session_preferred_lang`, `used_sticky` (bool) |
| `manual_lock_used` | User selects Lock language | `from_lang`, `to_lang`, `reason` (first_time, after_bad_detect, preference) |
| `language_flip` | Two different langs accepted in same session within 5 min | `from_lang`, `to_lang`, `confidence_both` |
| `correction_after_insert` | User deletes more than 50% of pasted text within 5s | `lang`, `confidence`, `char_count` |
| `lid_abstained` | Detector returned nil | `voiced_duration`, `top1_prob`, `top1_lang`, `reason` (too_short, low_confidence, narrow_margin) |
| `transcription_latency` | Per transcription | `lang`, `model`, `duration_s`, `ms_per_audio_s` (real-time factor) |

Sentry breadcrumbs on every LID call (category: `language.detect`).

## Build sequence (parallel workstreams)

All streams target today. Dependencies explicit.

| Stream | Owner | Depends on | Tier |
|---|---|---|---|
| W1: UI replacement | SwiftUI agent | W2 interface contract only | MEDIUM |
| W2: Autodetect stack | ASR agent | none | LARGE |
| W3: Prompt rearchitecture | LLM/prompt agent | W2 interface | MEDIUM |
| W4: Model swap | Config agent | none | MEDIUM |
| W5: Eval harness extension | Eval agent | W4 (model available for testing) | SMALL |
| W6: Telemetry | Observability agent | W2 events defined | SMALL |

Shared interface (W2 produces, W1 and W3 consume):

```swift
public struct LanguageDetectionResult: Sendable {
    public let lang: String?         // ISO 639-1, nil if abstaining
    public let confidence: Double    // top-1 prob, 0 if abstained
    public let margin: Double        // top-1 minus top-2
    public let tier: LanguageConfidenceTier
    public let voicedDuration: TimeInterval
    public let abstained: Bool
    public let usedSessionPrior: Bool
}

public enum LanguageConfidenceTier: Sendable {
    case locked      // user set Lock language
    case highAuto    // prob >= 0.80 AND margin >= 0.25
    case mediumAuto  // prob >= 0.65 AND margin >= 0.20
    case lowAuto     // below medium thresholds
    case abstain     // below short-clip thresholds or no voiced speech
}

public enum LanguageMode: Codable, Sendable {
    case auto
    case locked(String)  // ISO 639-1 code
}
```

## Validation

### Per stream

Each stream closes its own child issue with: logic tests passing, `/wispr-rebuild-and-relaunch` clean, `/wispr-eyes` verification on any UI change, and for MEDIUM+ streams the edge-case enumeration filled in on the issue body.

### Epic-level closeout

Before closing the epic:
1. `swift build -c release` exit 0
2. `swift build --build-tests` exit 0
3. `scripts/swift-test.sh` passes
4. `/wispr-rebuild-and-relaunch` produces a usable app
5. `/wispr-eyes "verify multilingual v1 settings flow + auto detect"` VERIFIED
6. Eval harness shows no regression on en/de/ta versus pre-merge baseline (less than 0.5 absolute WER drop)
7. `/ask-gpt` sign-off on the full PR stack
8. `/periphery` scan clean
9. Architecture closeout in epic closing comment (module placement, heart protection, anti-god-object check, boundary integrity)

## Council references

- Gemini 2.5-Flash review (2026-04-12): picker as escape hatch with recents + search; phased public messaging from "multiple languages" to "50+" to "99".
- GPT-5.4 review (2026-04-12): multi-window LID, top-2 fallback deferred, session memory, formatting vs lexical prompt split, script guardrail, weak-supervision from edit behavior, `large-v3-v20240930_turbo` right choice, FLEURS + Common Voice + user feedback as the three pillars of QA.

## Rules and gotchas to respect

- `@preconcurrency import WhisperKit` required wherever the module is used
- No em-dashes or en-dashes in code comments, docs, or UI copy
- `nonisolated(unsafe)` for cross-actor audio buffers
- `.contentShape(Rectangle())` on any new plain-style buttons
- `SettingsManager` uses per-key `didSet` + `onChange?(.key)` pattern
- XPC boundary: language setting is passed through `TranscriptionOptions.language`; detector call site is host-process (`WhisperKitPipeline`), not the XPC service process, because detection needs audio samples that live on the host side
- Never log API keys, Bluetooth-specific audio paths need `AVCaptureSessionSource` (unaffected here but keep in mind for testing)
- Every `swift build -c release` + bundle step after code edits; never test via `.build/debug` alone

---

## Resolution footer (2026-04-16)

The `useRefreshedWhisperKitModel` rollback flag and the `whisperKitModel` setting it controlled were removed entirely in the variant-swap cleanup PR for #256. Rationale: no UI exposes a WhisperKit model picker, the flag had a latent defect (XPC cold-start sync gap), and the product decision is to ship a single canonical model rather than maintain variant-choice plumbing. Single source of truth is now `WhisperKitBackend.defaultModelVariant()`. Future model swaps update one literal and notify users via the What's New flow.
