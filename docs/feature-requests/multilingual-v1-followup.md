# Multilingual v1 Follow-up Plan

Date: 2026-04-12. Parent: [multilingual-v1.md](multilingual-v1.md). Epic: #242.

## What shipped in this PR (feat/multilingual-v1)

All six workstreams landed end-to-end with build clean + 251 tests passing.

- **W1 UI**: Auto toggle + hidden Lock language sheet with search + 99-lang catalog (native + English names). Replaces the old 3-lang segmented picker.
- **W2 LanguageDetector**: actor with voiced-duration gate, multi-window LID, confidence thresholds, session memory with anti-flap, script guardrail helper. Session-preferred memory persisted in UserDefaults with defensive filtering.
- **W3 Prompt rearchitecture**: PromptVocabulary with global + per-language lists, confidence-tiered injection (Locked/HighAuto/MediumAuto/LowAuto), explicit backend field so Parakeet and WhisperKit dispatch to correct paths.
- **W4 Model swap**: default WhisperKit variant changed to `openai_whisper-large-v3-v20240930_turbo` with `useRefreshedWhisperKitModel` flag for emergency rollback, and a first-launch migration that upgrades legacy persisted values.
- **W5 Eval harness**: FLEURS + Common Voice downloaders, eval_all.sh orchestrator, score.py with tier assignment and Korean dual metric (CER + whitespace-WER). Polish-QA harness with polisher-runner Swift CLI for mutation flag analysis.
- **W6 Telemetry**: Six PostHog events (language_detected, manual_lock_used, language_flip, correction_after_insert, lid_abstained, transcription_latency) with vendor containment intact (no PostHog imports in ASR/Core).

End-to-end UAT runtime verification:

- Parakeet English dictation with Gemini polish: no regression
- WhisperKit with Japanese locked: heart path works, ASR decoded correctly as Japanese, polish skipped by pre-existing CJK word-count heuristic
- WhisperKit with Auto + Spanish TTS: detected as Spanish, ASR correct, Gemini polish ran cleanly

## What is broken or incomplete

### Critical: LanguageDetector accuracy on non-English audio

**Symptom**: In auto mode, WhisperKit's `detectLangauge` call (wrapped by our `LanguageDetector`) returns `lang=en` with confidence 1.00 and margin 1.00 for clearly non-English audio (French, Italian, Japanese, Korean, Chinese, Tamil, Gujarati). The downstream `transcribe` call rescues most cases because the audio signal is unambiguous, but Italian and Tamil both hallucinated into complete English garbage.

**Likely root cause**: the `softmaxFromLogProbs` transform in `LanguageDetector.swift` misinterprets WhisperKit's `langProbs` output. Either the field is already probabilities (not log-probs), in which case our exp+normalize squashes the distribution into near-uniform and lets Whisper's English bias dominate, or the field shape is not what we assumed.

**Fix direction**: bypass the custom softmax entirely. Use `result.language` from `detectLangauge` directly (WhisperKit already did the argmax). Multi-window aggregation becomes majority-vote on the winning language across windows. Confidence becomes the mean of the winning language's probability across windows. This eliminates the softmax as a source of error.

**Validation after fix**: rerun the 7-language TTS matrix (fr, it, hi, gu, ta, zh, ko) and require the detector to identify each correctly with high confidence for at least 6 of 7.

### Major: LLM polish `<4 words` short-circuit fires on long CJK transcripts

**Symptom**: Polish was skipped on a 31-character Japanese utterance because the word-count check treats it as 2 words (Japanese has no spaces).

**Root cause**: pre-existing heuristic in `LLMPolishStep`, not introduced by this PR. Surfaced by multilingual support.

**Fix direction**: language-aware minimum. For CJK and Thai/Lao, use character count (minimum ~10 chars). For Latin/Cyrillic/Indic/Arabic, keep word count (minimum 4). Consider using `LanguageTypes.isNonLatinScript(_:)` as the branch.

### Major: Detector confuses Hindi and Gujarati

**Symptom**: Gujarati audio was detected as Hindi, producing output in Devanagari script instead of Gujarati script.

**Root cause**: Whisper is known to confuse closely-related Indic languages on short clips. The fix-LID work above may partially mitigate (better confidence signal), but the underlying model limitation remains.

**Fix direction**: script-specific post-processing could detect Gujarati script and correct the lang tag. Or: prompt injection can bias the decoder. Or: accept the limitation and document it.

### Major: Hindi / Tamil / Gujarati confidence is low (0.50 / lowAuto tier)

Even when correctly identified, Indic languages scored 0.50 confidence with narrow or zero margin. Under our tier policy, that puts them in `lowAuto` which skips lexical prompt injection entirely. They still transcribe but lose the benefit of custom vocabulary.

### Major: Pre-existing XPC service UserDefaults domain issue

The XPC ASR service runs in a separate process with its own `UserDefaults.standard` domain. The `useRefreshedWhisperKitModel` flag is set by the app in `com.enviouswispr.app` defaults, invisible to the service. The service's fallback now hardcodes the refreshed variant (`openai_whisper-large-v3-v20240930_turbo`); rollback requires the app to explicitly push the variant through the XPC interface.

This was flagged by codex audit pass 4 and reverted to hardcoded default. Pre-existing limitation, not a new regression.

### Minor: passive chip UI is callback-only, no banner

`LanguageDetector` emits `PassiveChipTrigger` events (flip-flop and consecutive-low-confidence). `AppState.pendingPassiveChip` holds the latest trigger, but no UI banner consumes it yet. Users will not see the "Detected X. Lock it?" or "Language unstable. Lock language?" CTAs the spec describes.

### Minor: `correction_after_insert` telemetry is a stub

W6 deferred implementing this event because it requires either an AX observer on the focused text field or a clipboard-diff heuristic that filters our own restore-clipboard writes.

### Minor: 99 vs 100 languages mismatch

`LanguageTypes.whisperSupportedLanguages` contains 100 codes. Spec says 99. The extra code is `yue` (Cantonese), which Whisper treats separately from `zh`. Fix is to either update the spec marketing copy or remove `yue` from the catalog.

### Minor: pre-existing Parakeet characterization test is weak

The "byte-identical" Parakeet characterization test in `LanguageAwarePromptInjectionTests.swift` compares `.parakeet` backend with nil-backend, both of which legacy-pass-through. Does not prove parity with pre-W3 behavior. Proper fix needs a golden-output capture from before the W3 changes landed, which was not done.

## Follow-up issues to file

- **LID accuracy fix** (P1): replace `softmaxFromLogProbs` with argmax on `result.language` per window, majority-vote aggregation. Validate via 7-language TTS matrix. Required before ship.
- **CJK polish word-count** (P1): language-aware minimum on `LLMPolishStep` short-circuit. Affects all CJK users immediately.
- **Indic language accuracy** (P2): investigate whether prompt injection of script-specific priming sentences improves Indic confidence and correctness. Also consider whether large-v3 (non-turbo) would help. The benchmark harness (W5) can measure this.
- **Hindi vs Gujarati disambiguation** (P2): script detection post-processing, prompt priming, or accept limitation and document.
- **Passive chip UI banner** (P2): wire a SettingsSpeechEngineView banner bound to `AppState.pendingPassiveChip` with "Lock" and "Dismiss" actions.
- **Correction-after-insert telemetry** (P2): design and implement the AX observer or clipboard-diff approach.
- **Parakeet golden-output characterization test** (P3): capture pre-W3 prompt output for Parakeet English flows, add as a fixture, compare in tests.
- **XPC defaults domain sync for rollback flag** (P3): either pass the flag through the XPC interface or have the app always push `whisperKitModel` before the first `loadModel` call.
- **99 vs 100 language code reconciliation** (P3): update spec or catalog.
- **XPC crash routing cleanup** (P3): pre-existing issue codex surfaced where ASR XPC crashes are routed into WhisperKitPipeline regardless of backend; investigate scoping.

## Native-speaker TTS for multilingual test corpus

The current eval corpus uses OpenAI TTS with a single voice across all languages, which produces an American-accented rendering of every language. For French, Italian, and the Indic languages, this is far from a native speaker and is likely a source of the LID confusion we saw (Italian rendered by an American-accented TTS sounds closer to English than to native Italian).

Options for improving the multilingual TTS signal, ordered by cost and quality:

1. **OpenAI TTS with per-language voice selection**: OpenAI offers several voices (alloy, echo, fable, onyx, nova, shimmer). Some sound more natural for specific languages than others. Cheap, no new vendor. Quality gain: modest.

2. **macOS `say` with native voices per language**: macOS ships with language-native voices (Kyoko for Japanese, Yelda for Turkish, Lekha for Hindi, etc.). Free, local, actually-native speakers. Quality varies by language but is usually better than American-accented OpenAI. Already supported as a fallback in `tts_generate.py`.

3. **ElevenLabs Multilingual v3**: state of the art for multilingual TTS, voice cloning support, natural prosody. ~$22/month for starter. Quality gain: large. We flagged this earlier as "free-tools-only preferred" but it is worth a one-month trial to build a high-quality eval corpus.

4. **Mozilla Common Voice**: not TTS, but real human speech across 120+ languages with native speakers. Free, CC0, already on our integration list from W5. This is the highest-quality signal but requires more integration work.

5. **FLEURS (Google)**: research dataset with 102 languages, ~12 speakers per language. Free. Also on W5 integration list.

**Recommended for the next validation round**: use FLEURS + Common Voice as the primary signal (real native speech), fall back to macOS `say` with language-native voices for synthetic regression tests, and only use OpenAI TTS for sanity checks or languages where FLEURS/Common Voice is thin. Drop OpenAI TTS as the default multilingual corpus source.

## Plan for the next session

1. Read this document and the parent `multilingual-v1.md` spec.
2. Fix LID accuracy (the critical follow-up). Use `result.language` directly, majority-vote aggregation.
3. Rebuild, rerun the 7-language TTS matrix (ta, zh, ko, fr, it, hi, gu) to validate.
4. Fix CJK polish word-count. Rerun Japanese/Chinese/Korean dictation to verify polish fires.
5. Codex review pass of the fixes via `codex review --uncommitted` (direct CLI, never the plugin skill).
6. Wire the passive chip UI banner (small scope).
7. Use FLEURS for the full 99-language quality matrix once LID is fixed.
8. Council consultation on whether to reduce auto-detect confidence thresholds (currently 0.65 / 0.20) given the actual confidence values we see from the fixed LID.

## Process learnings logged to memory

- **No agents for code changes at LARGE/REFACTOR tier** (violated in this epic; direct cost was 13 codex findings + 2 rounds of self-introduced regressions). Memory: `feedback_refactor_discipline`.
- **Check all tool interfaces before use** (we hit codex:rescue plugin bugs that `codex review --uncommitted` would have avoided). Memory: `feedback_check_tool_layers`.
- **Validate automated review findings against actual code before acting** (applied correctly on codex pass 1 but required user reminder). Memory: `feedback_validate_review_findings`.
- **End-to-end runtime validation catches bugs static analysis misses** (LID accuracy bug only surfaced when we actually dictated Italian TTS through the running app).
