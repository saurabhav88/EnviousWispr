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

---

## Next session quickstart (10/10 confidence handoff)

### 0. State at handoff (2026-04-12 end of session)

- Feature branch `feat/multilingual-v1` is pushed to origin. NOT merged to main.
- Worktree at `/Users/m4pro_sv/Desktop/EnviousWispr-multilingual-v1`, main repo at `/Users/m4pro_sv/Desktop/EnviousWispr`.
- Last commit on the branch contains everything listed in the "What shipped" section above. 251 tests pass, build clean.
- `main` is unchanged; multilingual work is isolated to the feature branch.
- Dev app (`EnviousWispr Local.app`) from the feature branch may still be running (PID was 46090 last we checked). Bundle id `com.enviouswispr.app.dev`.
- The `openai_whisper-large-v3-v20240930_turbo` model is cached on the dev machine under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`. Legacy `openai_whisper-large-v3_turbo` is also cached (from before the swap).
- UserDefaults at end of session: `languageMode={"mode":"auto"}`, `selectedBackend=whisperKit`, `llmProvider=gemini`, `llmModel=gemini-2.5-flash`.

### 1. Resume commands

```bash
# Attach to the feature branch worktree
cd /Users/m4pro_sv/Desktop/EnviousWispr-multilingual-v1

# Confirm you are on feat/multilingual-v1
git status

# If the dev app is still running and you just want to test:
ps aux | grep -c '[E]nviousWispr'   # expect >= 1

# If you need to rebuild after code changes:
find .build/arm64-apple-macosx/release/EnviousWispr.build/ -name "*.o" -delete 2>/dev/null
rm -rf .build/arm64-apple-macosx/release/Modules/EnviousWispr.swiftmodule
swift build -c release
# then follow the bundle-app.md recipe with PROJ_ROOT pointing at this worktree
# (the /wispr-rebuild-and-relaunch skill hardcodes main's path; override PROJ_ROOT inline)
```

### 2. Diagnostic to confirm the LID bug (do this BEFORE coding the fix)

The hypothesis is that `softmaxFromLogProbs` in `LanguageDetector.swift` misinterprets WhisperKit's `langProbs` output. To verify, add one-shot diagnostic logging that dumps the raw `result.langProbs` from `detectLangauge` for each window, then rerun one non-English TTS and inspect the log. Concrete approach:

In `Sources/EnviousWisprASR/LanguageDetector.swift` around line 406 (the `whisperKit.detectLangauge(audioArray: window)` call), add temporarily:

```swift
await log("LID window \(i) raw langProbs top-5: \(Array(result.langProbs.sorted { $0.value > $1.value }.prefix(5)))")
```

Then rebuild, run:
```python
# From /Users/m4pro_sv/Desktop/EnviousWispr
python3 -c "
import sys; sys.path.insert(0, 'Tests/UITests')
from wispr_eyes import connect, record_tts
connect('EnviousWispr')
record_tts(sentence='Manda un messaggio a Giulia per dirle che sarò in ritardo di circa dieci minuti per il traffico.', key='rcmd')
"
```

Then inspect `~/Library/Logs/EnviousWispr/app.log` for the raw values. If the top-5 shows Italian with a probability like 0.85 (already-softmaxed), the hypothesis is confirmed: remove the softmax, use values directly. If the top-5 shows Italian with a value like -0.16 (log-space), then softmax is probably correct and the bug is elsewhere (window slicing, API misuse, etc.). Remove the diagnostic log line after understanding the shape.

### 3. Exact fix pointers

**#249 LID accuracy:**
- Primary file: `Sources/EnviousWisprASR/LanguageDetector.swift`
- Suspect function: `softmaxFromLogProbs` around line 452
- Callers: `runMultiWindowLID` around line 372-423 — this is where the aggregation happens
- Alternative fix path if softmax is not the issue: bypass aggregation entirely, use `result.language` from a single full-audio call to `detectLangauge` and trust WhisperKit's argmax
- Tests to update: `Tests/EnviousWisprASRTests/LanguageDetectorTests.swift` — the tests use `evaluateForTesting(windowProbs:)` which bypasses the softmax. After the fix, tests should still pass because they feed in already-normalized probabilities.
- New test to add: an integration test that calls `detectLangauge` on a known Italian WAV (generate via OpenAI TTS once, commit as a fixture) and asserts `lidResult.lang == "it"`.

**#250 CJK polish word-count:**
- File: `Sources/EnviousWisprPipeline/LLMPolishStep.swift` — grep for the word-count short-circuit (the log message is `"LLM polish skipped: transcript too short"`).
- Fix: use `LanguageTypes.isNonLatinScript(lang)` (already exists in Core) to branch. For CJK/Thai/Lao, compute character count; for everything else, keep word count. Minimums: ~10 chars for CJK, 4 words otherwise.
- Tests: add @Test cases in `Tests/EnviousWisprTests/LLM/LanguageAwarePromptInjectionTests.swift` for the boundary conditions — a 10-char Japanese transcript triggers polish, a 9-char one short-circuits, etc.

### 4. 7-language regression matrix (rerun after the fix)

Exact sentences used in this session, with what the detector returned (WRONG in auto mode) and what it should return:

| Lang | Sentence | LID returned | Should be |
|---|---|---|---|
| fr | `Envoie un message à Camille pour dire que je serai en retard d'environ dix minutes à cause du métro.` | en (1.00/1.00 mediumAuto) | fr |
| it | `Manda un messaggio a Giulia per dirle che sarò in ritardo di circa dieci minuti per il traffico.` | en (1.00/1.00 highAuto) | it |
| hi | `सारा को मैसेज भेजो कि मुझे ट्रैफिक की वजह से पहुँचने में करीब दस मिनट की देरी हो जाएगी।` | hi (0.50/0.25 lowAuto) | hi with higher confidence |
| gu | `સારાને મેસેજ મોકલ કે ટ્રાફિકને કારણે મને પહોંચતાં લગભગ દસ મિનિટ મોડું થશે.` | hi (0.50/0.00 lowAuto) | gu |
| ta | `போக்குவரத்து நெரிசலால் நான் சுமார் பத்து நிமிடம் தாமதமாக வருவேன் என்று சாராவுக்கு செய்தி அனுப்பு.` | en (1.00/1.00 highAuto) | ta |
| zh | `给莎拉发条消息，告诉她我路上堵车，大概要晚十分钟才能到。` | en (1.00/1.00 mediumAuto) | zh |
| ko | `사라한테 메시지 보내줘, 길이 막혀서 한 십 분 정도 늦을 것 같다고 전해줘.` | en (1.00/1.00 mediumAuto) | ko |

Ship criteria for the LID fix: correct detection for at least 6 of 7, with confidence varying meaningfully (not all 1.00). Use the reference sentences above as the test set.

### 5. Codex usage (burned in)

- Never use the `codex:rescue` plugin skill. The plugin's `codex-companion.mjs` has zombie-process and interrupt-leak bugs.
- Use `codex review --uncommitted` directly from Bash (no arguments — default prompt works fine).
- If you need a custom prompt, the CLI currently rejects `--uncommitted [PROMPT]`. Either pipe via stdin after checking the current CLI version, or use `codex exec` subcommand with your prompt.
- Each review pass costs ~0 direct dollars because you are on ChatGPT Plus/Pro subscription (not API-metered). Consumes your Plus cap.
- Validate every codex finding against the actual code before acting. Do not dispatch fix agents; fix directly (LARGE tier rule).

### 6. Native-speaker TTS for the next validation round

- Default corpus source should be FLEURS (primary) and Mozilla Common Voice (fallback). Downloaders already shipped in `scripts/multilingual-eval/fleurs_download.py` and `commonvoice_download.py`. Common Voice requires a one-time `huggingface-cli login` plus accepting terms at `mozilla-foundation/common_voice_17_0`.
- For synthetic regression tests, use macOS `say` with language-native voices: Kyoko (ja), Yelda (tr), Lekha (hi), Milena (ru), Monica (es), Anna (de), Thomas (fr), Alice (it), Luciana (pt), Tingting (zh), Yuna (ko), Majed (ar). Already mapped in `scripts/multilingual-eval/tts_generate.py` `SAY_VOICES_BY_LANG`.
- Do NOT use OpenAI TTS as the default. Its single-voice American-accented rendering of every language may be contributing to the LID confusion we saw this session.

### 7. Don't skip

- Runtime UAT is mandatory before declaring the fix done. See `feedback_runtime_uat_catches_static` memory.
- No coding agents for LARGE-tier work. See `feedback_refactor_discipline` memory.
- Validate codex findings against actual code before acting. See `feedback_validate_review_findings` memory.

### 8. Council sessions (persistent history)

The `llm-council` MCP maintains session state across Claude conversations. The following sessions were created during Multilingual v1 work and have the full strategic context. Resume them in the next session by passing the same `session_name` to `mcp__llm-council__council`. Config (provider, model, temperature, reasoning_effort) is locked at creation — do NOT try to switch providers or models on an existing session; create a new session name if you need different config. The `system_prompt` is the one attribute that can be updated mid-session.

| Session name | Provider / model | Topic |
|---|---|---|
| `multilingual-rubric-gpt-v2` | openai / gpt-5.4 | Pressure-tested the scoring rubric (tier thresholds, TTS-to-real-speech assumption, autodetect gate, sample sizes, model selection). GPT flagged: "best of explicit/autodetect is wrong, use explicit-only for picker and a separate autodetect gate." |
| `multilingual-rubric-gemini-flash` | gemini / gemini-2.5-flash | Same rubric review. Converged with GPT on most points; emphasized real-speech data and stricter thresholds. |
| `multilingual-northstar-gpt` | openai / gpt-5.4 | Strategy: 99-language auto-detect as default, no primary picker. GPT endorsed with specific 30-day roadmap (W1 Auto + hidden Lock, W2 VAD + multi-window LID + session memory, W3 prompt split, W4 eval). Source of the layered autodetect stack design (voiced-duration gate, multi-window LID, session memory, top-2 fallback, abstain logic). |
| `multilingual-northstar-gemini` | gemini / gemini-2.5-flash | Same strategy question. Phased public messaging approach ("multiple languages" -> "50+" -> "99"). Hidden picker as escape hatch. |

Sessions that errored and should NOT be reused (create fresh names instead):
- `multilingual-rubric-gpt` (poisoned: gpt-5 rejected the default temperature=0.7)
- `multilingual-rubric-gemini` (Gemini Pro hit 503 UNAVAILABLE; Flash version worked)

**When to resume which session:**
- Before coding the LID fix, optionally consult `multilingual-northstar-gpt` for "given the fixed LID returns confidences like X, should we reduce the 0.65/0.20 thresholds?" GPT has the full thresholds context.
- Before the 99-language advertised-quality push, consult `multilingual-rubric-gpt-v2` for the tier thresholds conversation. The rubric in docs/feature-requests/multilingual-v1.md is based on its feedback.
- For prompt-injection strategy tweaks (tier table, script guardrail edge cases), resume `multilingual-northstar-gpt`.

**When to NOT resume:** for a fresh independent review of new code, spin up a new session name so the prior conversation does not anchor the review. Codex audit (`codex review --uncommitted`) should always be fresh per-pass.

### 9. Artifacts to hand off verbatim

If you are still stuck, the following session artifacts may help:

- This session's transcript lives in `~/.claude/projects/-Users-m4pro-sv-Desktop-EnviousWispr/` logs.
- The actual UAT log (with LID results for the 7 languages) is in `~/Library/Logs/EnviousWispr/app.log` under the 2026-04-12T17:41-17:47Z timestamps.
- The TTS audio files are at `/tmp/wispr_eyes_tts.mp3` (most recent overwrites prior; regenerate per language via `wispr_eyes.tts(sentence, voice, engine)`).
- The benchmark corpus with 150 sentences across 15 languages is at `benchmark-results/multilingual-eval-2026-04-12/corpus/sentences.jsonl` on the feature branch.
