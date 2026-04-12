# Apple Intelligence Polish Language Gate

Date: 2026-04-12. Parent: epic #242 (Multilingual v1 follow-up). Status: APPROVED FOR EXECUTION.

**Council validation**: GPT 97/100, Gemini 100/100. Two parallel sessions `apple-lang-gate-plan-gpt-v2` and `apple-lang-gate-plan-gemini-v2` (resume for follow-up questions). No remaining P1 blockers. Execution-ready for an autonomous session.

## 0. TL;DR for a fresh session

Apple Intelligence polish works for ~7 languages, translates-instead-of-polishes for 2 officially supported ones (de/ko), and silently fails on 8 unsupported ones. Root cause: our `AppleIntelligenceConnector` sends an English-only system prompt with no language awareness and no preflight gating against Apple's supported-languages API. Fix: thread detected language through `LLMProviderConfig`, query `SystemLanguageModel.supportedLanguages` at runtime, inject language constraint into the system prompt, validate output language, and skip polish for unsupported languages before the round trip.

This is a MEDIUM-tier change. Single domain (LLM polish path), ~3 files, no architecture change, requires runtime UAT across Parakeet English + WhisperKit multilingual paths.

## 1. Problem

The Multilingual v1 epic (#242, merged in #257) shipped 99-language auto-detect for ASR. Gemini 2.5 Flash polishes multilingual correctly. Apple Intelligence polish does not. Three failure modes observed in the 60-test matrix (20 languages × 3 utterance types, Google Cloud Chirp3-HD TTS, fresh session memory):

### 1.1. Translation hallucination
Clean in-language ASR input is translated to English by Apple Intelligence. LID was correct (highAuto). Happens on languages on Apple's official supported list.

Example (German, `de/list`):
- Raw ASR (clean German): "Also für die Reise brauche ich meinen Pass und mein Ladegerät und meine Kopfhörer und, ach ja, meine Sonnenbrille."
- Polished output: "Also, for the trip, I need my passport, my charger, my headphones, and, ah, my sunglasses."

Same pattern for Korean list-style utterances.

### 1.2. Silent empty generation (~30ms exit)
Apple Intelligence's Foundation Models framework returns empty output with no thrown error in ~30ms (vs ~1.3s for successful polish). Pipeline defaults to raw passthrough. Languages affected: Arabic, Hebrew, Russian, Ukrainian, Polish, Thai, Tamil, Vietnamese.

These eight languages are NOT in Apple's documented supported-languages list. The ~30ms is the framework declining to generate, but we never query `SystemLanguageModel.supportedLanguages` upfront so we burn compute and give up a chance to gate cleanly.

### 1.3. Test matrix outcomes (60 tests)

| Outcome | Official (10 langs) | Unofficial (10 langs) | Total |
|---|---|---|---|
| polished | 6 | 7 | 13 |
| no-change (polish ran, nothing to fix) | 16 | 4 | 20 |
| skipped (<4 word short-circuit) | 6 | 6 | 12 |
| silent-fail (~30ms empty) | 1 | 11 | 12 |
| translated-to-English | 1 | 1 | 2 |
| NO-ASR | 0 | 1 | 1 |

Reliable langs (empirical): en, es, fr, it, pt, ja, zh (7).
Translation hallucinations: de, ko (on official list).
Silent-fail confirmed: ar, he, ru, uk, pl, th, ta, vi.
Surprising wins: hi, tr, nl (worked despite not being on our test-plan's "official" bucket).

Full raw results: `/tmp/polish_matrix_results.jsonl` from the 2026-04-12 session. Corpus: `benchmark-results/multilingual-polish-2026-04-12/corpus/` (gitignored).

## 2. Findings from external research

### 2.1. Council consultation
Two parallel sessions: `apple-polish-gpt` (openai/gpt-5.4, reasoning=medium) and `apple-polish-gemini` (gemini-3.1-pro-preview). Both concluded our connector is under-specified. GPT provided Swift code; Gemini was partially wrong about the API being private (it is public) but right on the gating strategy. Council session names preserved for future resumption.

Consensus:
1. Our English system prompt + bare-transcript input biases the 3B model toward "rewrite for me" instead of "edit in-language."
2. Empty-output (~30ms) must be treated as a failure signal; no framework-level error will come.
3. Gate strictly at request time for known-unsupported languages. Don't burn compute on silent fails.
4. Do not ship Apple Intelligence as the default polish provider for multilingual users today.

### 2.2. Apple docs findings (public, verified)
- `FoundationModels` is a **public framework**. `SystemLanguageModel`, `LanguageModelSession`, `Instructions`, `GenerationSchema`, `DynamicGenerationSchema` are all public.
- `SystemLanguageModel.default.supportedLanguages` returns `[Locale.Language]` at runtime. **This is the authoritative allowlist.**
- Apple officially supports ~23 locales across 15-16 languages (English×3, Spanish×3, Chinese×3, French×2, Portuguese×2, plus German, Italian, Japanese, Korean, Dutch, Swedish, Turkish, Danish, Norwegian, Vietnamese).
- Apple explicitly states the framework default is "match output language to input language." Our English system prompt overrides this default.
- Availability enum: `.available`, `.unavailable(.deviceNotEligible | .appleIntelligenceNotEnabled | .modelNotReady)`. Connector already handles these.

Sources:
- `https://developer.apple.com/documentation/FoundationModels`
- `https://machinelearning.apple.com/research/apple-foundation-models-2025-updates`
- `https://rudrank.com/exploring-foundation-models-supported-languages-internationalization`

## 3. Goals & non-goals

### 3.1. Goals
- Stop translation hallucinations on supported non-English languages (primary concern: de, ko, but should generalize).
- Skip polish round-trip for languages Apple's on-device model doesn't support (no silent fails).
- Preserve Parakeet's English polish path byte-identically.
- Preserve the reliable 7-lang empirical set at current quality.
- Validate output stays in the expected language for non-English polish.
- Keep polish as a limb: never block, never crash, never throw past the pipeline boundary.

### 3.2. Non-goals
- Do not attempt to make Apple Intelligence work for Arabic/Hebrew/Russian/Ukrainian/Polish/Thai/Tamil/Vietnamese through prompt engineering alone. These are genuinely unsupported by the on-device model.
- Do not change the provider selection UX. Users who picked Apple Intelligence continue to get Apple Intelligence for supported langs; raw-text passthrough otherwise.
- Do not change other connectors (Gemini, OpenAI, Ollama). Their multilingual handling is a separate concern.
- Do not change LID, prompt planning, or the prompt family dispatch system.
- Do not add new settings UI (defer to a follow-up).

## 4. Design

### 4.1. Overview
Thread detected language through `LLMProviderConfig`. In the Apple Intelligence path, `LLMPolishStep` sets `config.detectedLanguage`, and the connector uses it for (1) preflight gating against `SystemLanguageModel.default.supportedLanguages`, (2) language-aware system prompt injection, (3) post-generation output validation via `NLLanguageRecognizer`.

For Parakeet flows, `languageDetection` is nil and `config.detectedLanguage` stays nil, which routes to the current English-only path unchanged.

### 4.2. Decision table (what happens for a given detected language)

| Detected lang | In `supportedLanguages`? | Behavior |
|---|---|---|
| nil (Parakeet, pre-W2 callsite) | N/A | Current English-only path (preserve existing behavior) |
| en | Yes | Current behavior, output validation skipped for English |
| es/fr/it/pt/ja/zh | Yes (empirically reliable) | Language-aware prompt, polish runs, output validated |
| de/ko | Yes | Language-aware prompt (new), polish runs, output validated. Validation catches translation drift. |
| ar/he/ru/uk/pl/th/ta/vi etc. | No | Skip polish before round trip, log `polish.gated.unsupported_language`, pass raw text through |
| Unknown code | Conservative: treat as unsupported | Skip |

### 4.3. Language code normalization (canonical)

Whisper and our `LanguageDetectionResult.lang` field emit ISO 639-1 base codes (e.g. `en`, `de`, `ko`, `zh`). Apple's `SystemLanguageModel.supportedLanguages` returns `Set<Locale.Language>` whose entries carry region/script (e.g. `en-US`, `en-GB`, `zh-Hans`, `zh-Hant`, `pt-BR`). Direct equality will not work. Define one normalization function used consistently at every gate:

```swift
// Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift
// fileprivate scope; tested via @testable import.
fileprivate enum LanguageNormalizer {
 /// Normalize any incoming language identifier (BCP-47 or ISO 639-1)
 /// to a lowercased ISO 639-1 base code. Returns nil for empty, `und`,
 /// or unrecognized inputs.
 static func baseCode(_ raw: String?) -> String? {
 guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
 let lower = raw.lowercased()
 if lower == "und" { return nil }
 // Special cases: Apple's zh variants and Mandarin tag collapse to zh.
 if lower.hasPrefix("zh") || lower.hasPrefix("cmn") || lower.hasPrefix("yue") { return "zh" }
 if lower.hasPrefix("nb") || lower.hasPrefix("nn") { return "no" }
 // Parse BCP-47 prefix before dash/underscore.
 let separator = lower.firstIndex(where: { $0 == "-" || $0 == "_" })
 let prefix = separator.map { String(lower[..<$0]) } ?? lower
 // ISO 639-1 is 2 chars. ISO 639-3 is 3 chars. Accept both as-is.
 return prefix.count == 2 || prefix.count == 3 ? prefix : nil
 }

 /// Map a Set<Locale.Language> (as returned by Apple) to base codes.
 static func baseCodes(_ languages: Set<Locale.Language>) -> Set<String> {
 Set(languages.compactMap { lang in
 let full = lang.maximalIdentifier
 return baseCode(full)
 })
 }
}
```

Normalization unit tests (in `Tests/EnviousWisprTests/LLM/AppleIntelligencePolishTests.swift`):

| Input | Expected |
|---|---|
| `"de"` | `"de"` |
| `"de-DE"` | `"de"` |
| `"de_DE"` | `"de"` |
| `"ko-KR"` | `"ko"` |
| `"cmn-CN"` | `"zh"` |
| `"zh-Hans"` | `"zh"` |
| `"zh-Hant"` | `"zh"` |
| `"yue"` | `"zh"` |
| `"nb"` | `"no"` |
| `"pt-BR"` | `"pt"` |
| `"und"` | `nil` |
| `""` | `nil` |
| `nil` | `nil` |
| `"xx"` | `"xx"` (accept but will fail allowlist) |

### 4.4. Supported-language allowlist: runtime vs fallback

Strict precedence rule (implement exactly):

1. On first use (per process), query `SystemLanguageModel.default.supportedLanguages` inside an `@available(macOS 26.0, *)` guard.
2. Normalize the returned `Set<Locale.Language>` to base codes via `LanguageNormalizer.baseCodes(_:)`.
3. If the normalized set is non-empty, use it. Cache in a `private static let` initialized via a `lazy` wrapper OR a `static let` + dispatch-once pattern (see 5.3 for exact code).
4. If the runtime set is empty or the query throws, fall back to `AppleIntelligenceCapabilities.documentedSupportedLanguages` (the hardcoded snapshot of Apple's 2026 public docs).
5. Never union runtime + fallback. Runtime wins when present.

Rationale: the fallback is a safety net for API regressions, not a supplementary list. Trusting only one source keeps the gate predictable.

### 4.5. Unknown / nil detected-language branch (explicit)

| `config.detectedLanguage` normalized to | Behavior |
|---|---|
| `nil` (no detection, Parakeet path, `und`, empty string, parse failure) | **Current English-only path unchanged.** Use `onDeviceInstructions` verbatim. No language injection, no output validation. This branch is Parakeet-compatible. |
| `"en"` | Language-aware prompt OFF (English is the default). No output validation. Call model. |
| Any base code IN the supported allowlist (es/fr/it/pt/ja/zh/ko/de/etc.) | Language-aware prompt ON. Call model. Output validation ON if output >= 24 letter-characters. |
| Any base code NOT in the supported allowlist (ar/he/ru/uk/pl/th/ta/vi/hi etc.) | Preflight gate: throw `LLMError.unsupportedInputLanguage(lang)`. Pipeline catches, falls back to raw text. |

### 4.5.bis. Error semantics: add new `LLMError.unsupportedInputLanguage(String)`

**Do NOT reuse `LLMError.frameworkUnavailable`** for unsupported input language. `frameworkUnavailable` currently means "Apple Intelligence is globally unavailable on this machine" (device not eligible, AI not enabled, model not downloaded). Reusing it for "per-request language gating" would confuse any future consumer that treats `frameworkUnavailable` as "stop trying this provider entirely" or shows a misleading UI string.

Add a new case to `LLMError` in `Sources/EnviousWisprLLM/LLMProtocol.swift`:

```swift
public enum LLMError: LocalizedError, Sendable, Equatable {
 // ... existing cases ...
 case unsupportedInputLanguage(String) // NEW

 public var errorDescription: String? {
 switch self {
 // ... existing cases ...
 case .unsupportedInputLanguage(let code):
 return "Apple Intelligence does not support the input language '\(code)' for on-device polishing."
 }
 }

 public static func == (lhs: LLMError, rhs: LLMError) -> Bool {
 switch (lhs, rhs) {
 // ... existing matches ...
 case (.unsupportedInputLanguage(let a), .unsupportedInputLanguage(let b)):
 return a == b
 default:
 return false
 }
 }
}
```

For output-language drift, use `LLMError.requestFailed("polish output language drift: expected=X got=Y")` as before. Distinct semantics: gate failure vs. post-generation failure.

### 4.6. Language-aware system prompt (exact wording)

When `config.detectedLanguage` normalizes to a non-English supported base code, prepend the following exact clause to `Self.onDeviceInstructions`. Do not improvise wording; the 60-test matrix quality signal is tied to this exact phrasing:

```swift
let basePrompt: String = {
 guard let base = LanguageNormalizer.baseCode(detectedLanguage),
 base != "en" else {
 return Self.onDeviceInstructions
 }
 // Force English-locale resolution of the display name. Injecting non-English
 // language names ("Deutsch", "日本語") into an English-framed system prompt
 // degrades instruction-following on small models. "German" / "Japanese" /
 // "Korean" in an English sentence is consistent and reliable.
 let displayName = Locale(identifier: "en_US").localizedString(forLanguageCode: base) ?? base
 let langClause = """
 Input language: \(displayName) (\(base)).
 Output MUST be in \(displayName). Never translate, summarize, or answer in a different language.
 Preserve list structure and punctuation exactly as given.


 """
 return langClause + Self.onDeviceInstructions
}()
```

Notes:
- Display name MUST be resolved via `Locale(identifier: "en_US").localizedString(forLanguageCode:)` (NOT `Locale.current.localizedString`). This forces English names regardless of user locale. Prevents "Deutsch (de)" or "日本語 (ja)" from appearing in an English system prompt, which the 3B model handles worse than consistent English naming.
- For the user turn, pass the transcript as-is (no additional wrapping). GPT's council suggestion to wrap in `<transcript>` tags is deferred. structured output via `@Generable` / `DynamicGenerationSchema` already constrains the response format. Re-evaluate only if UAT shows regressions.
- Custom vocabulary suffix logic in the existing `makeSession` branches is preserved. The new `langClause` is prepended to `Self.onDeviceInstructions`. When the user's `instructions.systemPrompt` equals `PolishInstructions.default.systemPrompt`, substitute `basePrompt` (which includes `langClause` + `onDeviceInstructions`). When a custom vocab suffix is appended, preserve the suffix after the new `basePrompt`.
- If the caller sets `instructions.systemPrompt` to a fully custom prompt (user-authored via `styleConfig.customSystemPrompt`), respect it as-is. No language injection. Same behavior as today's `else` branch in `makeSession`.

### 4.7. Concrete before/after sample (de/list)

This is the single most important UAT evidence. The fix works iff this flips.

**Before fix (current main):**
- Source (what was spoken via Chirp3-HD): `"also für die Reise brauche ich ähm meinen Pass und mein Ladegerät und äh meine Kopfhörer und ach ja meine Sonnenbrille"`
- Raw ASR: `"Also für die Reise brauche ich meinen Pass und mein Ladegerät und meine Kopfhörer und, ach ja, meine Sonnenbrille."` (clean German)
- LID verdict: `lang=de tier=highAuto conf=1.00`
- Polished: `"Also, for the trip, I need my passport, my charger, my headphones, and, ah, my sunglasses."` (ENGLISH. hallucination)

**After fix expected:**
- Same raw ASR + LID verdict.
- New: `config.detectedLanguage = "de"` passed to connector.
- Connector: preflight gate passes (de is in allowlist); system prompt prepended with `"Input language: German (de). Output MUST be in German..."`.
- Polished output: valid German, e.g. `"Also, für die Reise brauche ich meinen Pass, mein Ladegerät, meine Kopfhörer und, ach ja, meine Sonnenbrille."` (list commas added; may remove one filler).
- If model still translates: `NLLanguageRecognizer` detects English in 100-char output, throws `requestFailed`, pipeline falls back to raw ASR text. Paste = raw German, not English. Either outcome is acceptable; translation hallucination is eliminated.

### 4.8. Logging + telemetry expectations

New log events (category: `LLM`, via `AppLogger.shared.log`). Use these EXACT format strings so greppable in UAT + production logs:

```swift
// Preflight gate: unsupported input language
await AppLogger.shared.log(
 "LLM polish gated: Apple Intelligence does not support input language '\(base)', passing raw transcript through",
 level: .info, category: "LLM"
)

// Output validation: language drift detected after generation
await AppLogger.shared.log(
 "LLM polish output validation failed: language drift expected=\(expectedBase) got=\(actualBase), falling back to raw transcript",
 level: .warning, category: "LLM"
)

// Runtime supportedLanguages query returned empty, using documented fallback
await AppLogger.shared.log(
 "Apple Intelligence: SystemLanguageModel.supportedLanguages returned empty set, using documented fallback allowlist",
 level: .warning, category: "LLM"
)

// Empty generation (distinct from preflight. this fires if a supported-lang call still returns empty)
await AppLogger.shared.log(
 "LLM polish empty generation: Apple Intelligence returned 0 chars for lang=\(base), falling back to raw transcript",
 level: .warning, category: "LLM"
)
```

**Availability guard requirement**: NONE of these log calls reference `FoundationModels` symbols, so no `@available` annotation needed on them. However, the PREFLIGHT and VALIDATION code that computes `base`/`expectedBase`/`actualBase` lives inside the connector's `polish(...)` method, which is already `@available(macOS 26.0, *)`-guarded. **Do not reference `SystemLanguageModel`, `LanguageModelSession`, `Instructions`, or other Foundation Models symbols outside the existing `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` guard scope.** This is the single most common compile-trap for this module.

PostHog telemetry events (add to `TelemetryService`, vendor-contained in EnviousWisprServices):
- `polish.gated.unsupported_language` with `{provider, detected_lang}` (optional, can ship in a follow-up).
- `polish.output_language_drift` with `{provider, expected_lang, actual_lang}` (optional).
- `polish.empty_generation` with `{provider, detected_lang, latency_ms}` (optional).

Logs are mandatory for debuggability; telemetry is nice-to-have. Ship logs first; add telemetry in a follow-up PR if needed.

### 4.9. Output validation function (exact algorithm)

After `polishWithFoundationModels` returns, run this sequence:

```swift
// validateOutputLanguage(polished:expectedBase:) exact impl in connector
// Called only when config.detectedLanguage normalized is non-nil AND != "en".
//
// Algorithm uses NLLanguageRecognizer.dominantLanguage (NOT languageHypotheses).
// This is a deliberate choice: dominantLanguage returns a single best-guess
// with no numeric confidence surface. The algorithm compensates by being
// conservative via the length gate and the base-code normalization step.
// If dominantLanguage returns nil, the recognizer is effectively saying
// "unknown". we fail open.
func validateOutputLanguage(polished: String, expectedBase: String) throws {
 // 1. Count alphabetic Unicode scalars only. Excludes whitespace,
 // punctuation, digits, emoji. Minimum: 24.
 let letterCount = polished.unicodeScalars.filter(\.properties.isAlphabetic).count
 guard letterCount >= 24 else { return } // fail open

 // 2. Run NLLanguageRecognizer over the full polished text.
 let recognizer = NLLanguageRecognizer()
 recognizer.processString(polished)

 // 3. Ask for the single dominant language. nil = recognizer had no guess.
 guard let dominant = recognizer.dominantLanguage?.rawValue else {
 return // fail open: recognizer unknown
 }

 // 4. Normalize recognizer output to base code (same normalizer as gate).
 guard let actualBase = LanguageNormalizer.baseCode(dominant) else {
 return // fail open: un-normalizable
 }

 // 5. Reject only on strong base-code mismatch.
 if actualBase != expectedBase {
 throw LLMError.requestFailed(
 "polish output language drift: expected=\(expectedBase) got=\(actualBase)"
 )
 }
}
```

Rules:
- **Fail-open** on short output (<24 alphabetic scalars), nil `dominantLanguage`, or un-normalizable recognizer output. These are the three fail-open paths. No other fail-open branches.
- **Fail-closed** only when `dominantLanguage` is non-nil, normalizes cleanly, and the normalized base code differs from `expectedBase`. Throw `LLMError.requestFailed(...)`; pipeline catches and falls back to raw text. Same fallback path as unsupported-language preflight.
- **No retry.** On rejection, the pipeline's existing fallback behavior is the final action. Do not re-call the model with a stronger prompt.
- **No `languageHypotheses` usage.** We do not threshold on confidence. Conservative length gate + base-code equality is sufficient for the goal (catching full-language translation hallucinations like de→en or ko→en).
- English outputs (`expectedBase == "en"`) skip validation entirely. Avoids false rejects on English text that LID sometimes misidentifies on short strings.

### 4.10. Empty-output detection (already exists, no change)

Connector already throws `LLMError.emptyResponse` on trimmed-empty content (`AppleIntelligenceConnector.swift` lines 81 and 124 in the current code). Preserved unchanged. Verification: spot-check during UAT that one of the 8 silent-fail langs (post-fix, these should be preflight-gated before reaching this throw) or an unexpected empty response produces the emptyResponse throw → pipeline falls back to raw.

## 5. File-by-file changes

### 5.-1. Additional audit: all `LLMError` consumers (do this before coding)

Adding a new `LLMError` case is an exhaustive-switch hazard. Grep all consumers and confirm each either (a) handles `.unsupportedInputLanguage` correctly, (b) has a `default:` fallback that does the right thing, or (c) needs a new branch.

```bash
# Enumerate all switch/catch sites touching LLMError
grep -rn "case \.frameworkUnavailable\|case \.requestFailed\|case \.emptyResponse\|LLMError\." Sources/ Tests/ | grep -v ".build"
```

Expected hits:
- `Sources/EnviousWisprPipeline/LLMPolishStep.swift`. catch around the polish call. Current logic treats any LLMError as "skip polish, pass raw through". This works for `.unsupportedInputLanguage` too. No change needed.
- `Sources/EnviousWisprServices/SentryBreadcrumb.swift`. error-to-breadcrumb mapping. Add `.unsupportedInputLanguage` mapping (low priority, does not affect compilation).
- `Sources/EnviousWisprLLM/LLMProtocol.swift`. the enum definition, `errorDescription`, and `==` need the new case added (per section 4.5.bis).
- Test files under `Tests/EnviousWisprTests/LLM/`. check for exhaustive switches on `LLMError`. Add `.unsupportedInputLanguage` handling if any exhaust.

Document the audit result in the PR body (one sentence per consumer, even if "no change needed").

### 5.0. All touch points for `LLMProviderConfig` (audit before starting)

`LLMProviderConfig` currently conforms to `Codable, Sendable`. Adding an optional field with a default value does not break existing init call sites if they use labeled args. Before coding, grep for every `LLMProviderConfig(` to confirm all call sites use labeled args:

```bash
grep -rn "LLMProviderConfig(" Sources/ Tests/ | grep -v ".build"
```

Expected call sites (from prior audit, verify these still match):
- `Sources/EnviousWisprPipeline/LLMPolishStep.swift`. the only production constructor. Needs new `detectedLanguage:` arg.
- Any test mocks or spies in `Tests/EnviousWisprTests/LLM/`. use `detectedLanguage: nil` default.
- `Codable` auto-synthesis handles the new optional field without schema changes.
- `Sendable` is preserved by the optional-String addition.

If an unexpected call site uses positional args, add the named `detectedLanguage:` at the end; default-nil keeps compilation green.

### 5.1. `Sources/EnviousWisprCore/LLMResult.swift`
Add `detectedLanguage: String?` to `LLMProviderConfig`. Default nil for backward compat.

```swift
public struct LLMProviderConfig: Codable, Sendable {
 public let model: String
 public let apiKeyKeychainId: String?
 public let maxTokens: Int
 public let temperature: Double
 public let thinkingBudget: Int?
 public let reasoningEffort: String?
 // NEW: detected language tag (ISO 639-1) for provider-side gating and prompting.
 // nil for Parakeet flows, pre-W2 callsites, or locked mode without explicit hint.
 public let detectedLanguage: String?

 public init(
 model: String,
 apiKeyKeychainId: String?,
 maxTokens: Int,
 temperature: Double,
 thinkingBudget: Int?,
 reasoningEffort: String?,
 detectedLanguage: String? = nil
 ) {
 self.model = model
 self.apiKeyKeychainId = apiKeyKeychainId
 self.maxTokens = maxTokens
 self.temperature = temperature
 self.thinkingBudget = thinkingBudget
 self.reasoningEffort = reasoningEffort
 self.detectedLanguage = detectedLanguage
 }
}
```

### 5.2. `Sources/EnviousWisprCore/LanguageTypes.swift`
Add a defensive fallback set for Apple Intelligence supported languages, sourced from Apple's 2026 public docs:

```swift
public enum AppleIntelligenceCapabilities {
 /// Fallback set of ISO 639-1 base codes for languages Apple documents as
 /// supported for on-device Foundation Models generation as of 2026-04.
 /// Used only when SystemLanguageModel.supportedLanguages query fails.
 /// The runtime framework query is authoritative; this is a safety net.
 public static let documentedSupportedLanguages: Set<String> = [
 "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh",
 "nl", "sv", "tr", "da", "no", "vi",
 ]
}
```

### 5.3. `Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift`

Significant changes. Preserves the existing `availability` enum switch and `@Generable` vs `DynamicGenerationSchema` split. Add `import NaturalLanguage` at the top.

**Canonical Swift API shape (verified against Apple docs):**

```swift
// SystemLanguageModel is @available(macOS 26.0, *)
// public class SystemLanguageModel {
// public static var `default`: SystemLanguageModel { get }
// public var availability: Availability { get }
// public var supportedLanguages: Set<Locale.Language> { get } // instance property, NOT async, NOT throwing
// }
//
// Locale.Language has `.languageCode?.identifier` and `.maximalIdentifier`.
// supportedLanguages is safe to call off-main. Stable per OS build.
```

**Caching rule (exact):** one lazy static `productionBaseCodes`, evaluated once per process, stores normalized base codes (NOT raw `Locale.Language`), frozen for process lifetime. The preflight gate reads from a `supportedLanguageProvider` closure which defaults to returning `productionBaseCodes`. Tests swap the closure entirely, bypassing the static cache, so there is NO static-initialization-trap (the static is only evaluated when the default closure is called, never when a test has swapped it).

```swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
internal enum AppleIntelligenceSupport {
 /// Lazy-static snapshot of Apple's supported languages, evaluated once per process.
 /// Accessed ONLY through `AppleIntelligenceConnector.supportedLanguageProvider`,
 /// never referenced directly by the gate. This keeps the test seam clean.
 fileprivate static let productionBaseCodes: Set<String> = {
 let runtime = LanguageNormalizer.baseCodes(SystemLanguageModel.default.supportedLanguages)
 return runtime.isEmpty
 ? AppleIntelligenceCapabilities.documentedSupportedLanguages
 : runtime
 }()
}

extension AppleIntelligenceConnector {
 /// Test seam. Default returns the production static. Tests assign a new
 /// closure in setUp and restore the original in tearDown (see Tests section).
 /// Because the gate calls this closure on every polish request, swapping it
 /// fully bypasses the productionBaseCodes static cache.
 @available(macOS 26.0, *)
 internal static var supportedLanguageProvider: () -> Set<String> = {
 AppleIntelligenceSupport.productionBaseCodes
 }
}
#endif
```

Preflight check in `polish(...)` becomes (one line, called every request):

```swift
if let base = LanguageNormalizer.baseCode(config.detectedLanguage),
 !Self.supportedLanguageProvider().contains(base) {
 throw LLMError.unsupportedInputLanguage(base)
}
```

Rationale: production reads from the closure → closure returns the cached `productionBaseCodes` → static evaluates once. Test swaps the closure → closure returns fixture → `productionBaseCodes` is never touched by that test. No cache-reset helper needed. No ordering dependence. The closure is the single authoritative source; the lazy static is just the closure's default implementation.

**Important: tests must restore the closure in tearDown.** If a test forgets, subsequent tests inherit the swapped allowlist. Use the scoped helper in section 5.5.2 to make this bulletproof.

Pseudo-code for the major additions in `polish(text:instructions:config:onToken:)`. Preserves the existing `availability` enum switch and `@Generable` vs `DynamicGenerationSchema` split.

```swift
import NaturalLanguage

#if canImport(FoundationModels)
import FoundationModels
#endif

public struct AppleIntelligenceConnector: TranscriptPolisher {

 public init() {}

 // NEW: cache supported base codes on first call. 3B model list is stable per OS build.
 #if canImport(FoundationModels)
 @available(macOS 26.0, *)
 private static func supportedBaseCodes() -> Set<String> {
 let model = SystemLanguageModel.default
 let runtime = Set(
 model.supportedLanguages.compactMap { $0.languageCode?.identifier.lowercased() }
 )
 return runtime.isEmpty
 ? AppleIntelligenceCapabilities.documentedSupportedLanguages
 : runtime
 }
 #endif

 public func polish(
 text: String,
 instructions: PolishInstructions,
 config: LLMProviderConfig,
 onToken: (@Sendable (String) -> Void)?
 ) async throws -> LLMResult {
 #if canImport(FoundationModels)
 guard #available(macOS 26.0, *) else {
 let v = ProcessInfo.processInfo.operatingSystemVersion
 throw LLMError.frameworkUnavailable(
 "Apple Intelligence requires macOS 26 or later. Current: \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
 )
 }

 // NEW: preflight language gate. Skip round-trip for unsupported languages.
 if let lang = config.detectedLanguage?.lowercased(),
 !lang.isEmpty,
 !Self.supportedBaseCodes().contains(lang) {
 throw LLMError.frameworkUnavailable(
 "Apple Intelligence on-device model does not support language '\(lang)'. Pass-through raw text."
 )
 }

 let result = try await polishWithFoundationModels(
 text: text,
 instructions: instructions,
 detectedLanguage: config.detectedLanguage
 )

 // NEW: output-language validation for non-English, length-gated.
 if let lang = config.detectedLanguage?.lowercased(),
 lang != "en",
 result.polishedText.count >= 24 {
 if let actual = Self.dominantLanguageCode(for: result.polishedText),
 actual != lang {
 throw LLMError.requestFailed(
 "polish output language drift: expected=\(lang) got=\(actual)"
 )
 }
 }

 return result
 #else
 throw LLMError.frameworkUnavailable(
 "This build was compiled without Apple Intelligence support. Rebuild with the macOS 26 SDK."
 )
 #endif
 }

 private static func dominantLanguageCode(for text: String) -> String? {
 let recognizer = NLLanguageRecognizer()
 recognizer.processString(text)
 return recognizer.dominantLanguage?.rawValue
 }

 // makeSession and polishWithFoundationModels: take an optional detectedLanguage
 // and build language-aware instructions when non-nil + non-English. Parakeet-
 // nil path preserves the current onDeviceInstructions exactly.

 #if canImport(FoundationModels)
 @available(macOS 26.0, *)
 private func polishWithFoundationModels(
 text: String,
 instructions: PolishInstructions,
 detectedLanguage: String?
 ) async throws -> LLMResult {
 let session = try makeSession(
 instructions: instructions,
 detectedLanguage: detectedLanguage
 )
 // ... (existing Generable or DynamicGenerationSchema path)
 // Wrap the user turn with language reminder when non-nil + non-English:
 // "Polish this transcript. Output language must remain \(langName) (\(tag)).
 // <transcript>\(text)</transcript>"
 //
 // For nil or en, pass plain text as today to preserve Parakeet byte-identity.
 }

 @available(macOS 26.0, *)
 private func makeSession(
 instructions: PolishInstructions,
 detectedLanguage: String?
 ) throws -> LanguageModelSession {
 let model = SystemLanguageModel.default
 // ... existing availability switch unchanged ...

 let basePrompt: String
 if let lang = detectedLanguage?.lowercased(), lang != "en" {
 let langName = Locale.current.localizedString(forIdentifier: lang) ?? lang
 basePrompt = """
 You polish speech-to-text transcripts.

 Input language: \(langName) (\(lang)).
 Output MUST be in \(langName). Never translate, summarize, or answer.

 \(Self.onDeviceInstructions)
 """
 } else {
 basePrompt = Self.onDeviceInstructions
 }

 // ... existing custom-vocab-suffix preservation logic unchanged,
 // but operating on `basePrompt` instead of `Self.onDeviceInstructions` directly.
 // The comparison against PolishInstructions.default.systemPrompt still
 // triggers the on-device-instructions swap; after the swap we compose with
 // basePrompt rather than the raw constant.

 return LanguageModelSession(model: model, instructions: systemPrompt)
 }
 #endif
}
```

Note on the custom-vocab preservation branch: the current code compares `instructions.systemPrompt` against `PolishInstructions.default.systemPrompt` to decide whether to swap in `Self.onDeviceInstructions`. Rename the constant we compose with to `basePrompt` (language-aware) but keep the branch logic identical. If users have a fully custom prompt, we still respect it as-is (no language injection).

### 5.4. `Sources/EnviousWisprPipeline/LLMPolishStep.swift`
Thread the detected language into `LLMProviderConfig`. In the existing Apple Intelligence branch (around line 136 in the current file), when building `config`, set `detectedLanguage = languageDetection?.lang`.

```swift
let config = LLMProviderConfig(
 model: llmModel,
 apiKeyKeychainId: keychainId,
 maxTokens: maxTokens,
 temperature: 0,
 thinkingBudget: thinkingBudget,
 reasoningEffort: reasoningEffort,
 detectedLanguage: languageDetection?.lang // NEW
)
```

This is the ONLY change in `LLMPolishStep`. The CJK char-count gate, polish-step orchestration, and non-Apple-Intelligence paths stay untouched.

### 5.5. Tests

#### 5.5.1. Unit `@Test` cases
File: `Tests/EnviousWisprTests/LLM/AppleIntelligencePolishTests.swift` (new).

Tests against the connector that do NOT require the FoundationModels framework at runtime (CLT test target cannot run the actual on-device model; we test prompt construction + gating logic).

**Normalization suite** (the most fragile part; exercise the full table from section 4.3):
- `"LanguageNormalizer: base codes stable for common ISO 639-1 inputs"`. en/de/fr/it/ja/ko → same.
- `"LanguageNormalizer: BCP-47 region tags strip to base"`. de-DE → de, ko-KR → ko, pt-BR → pt.
- `"LanguageNormalizer: Chinese variants collapse to zh"`. cmn-CN, zh-Hans, zh-Hant, yue → zh.
- `"LanguageNormalizer: Norwegian variants collapse to no"`. nb, nn → no.
- `"LanguageNormalizer: invalid inputs return nil"`. `""`, `"und"`, `nil` → nil.
- `"LanguageNormalizer: Locale.Language round-trips via maximalIdentifier"`. feed a Locale.Language, expect the base code.

**Config threading suite:**
- `"LLMProviderConfig: detectedLanguage defaults to nil"`. default-arg init preserves backward compat.
- `"LLMPolishStep passes languageDetection.lang into LLMProviderConfig.detectedLanguage for Apple Intelligence"`. use a spy polisher that captures the config passed in; inject a LanguageDetectionResult with `.lang = "fr"`; assert spy saw `detectedLanguage == "fr"`.
- `"LLMPolishStep passes nil detectedLanguage when languageDetection is nil (Parakeet path)"`. same spy, languageDetection=nil, expect config.detectedLanguage == nil.
- `"Codable auto-synthesis: older persisted LLMProviderConfig JSON without detectedLanguage decodes with nil"`. encode a fixture without the field, decode, assert nil.

**Allowlist suite:**
- `"AppleIntelligenceCapabilities.documentedSupportedLanguages covers Apple's 2026 public list"`. assert presence of en, es, fr, de, it, pt, ja, ko, zh, nl, sv, tr, da, no, vi.
- `"documentedSupportedLanguages excludes known-broken langs"`. assert ar, he, ru, uk, pl, th, ta, hi NOT in set.

**Output validation suite** (pure-function tests on a helper extracted from the connector):
- `"Output validation fails open on short output (<24 letters)"`. Tamil input, 10-letter output, no throw.
- `"Output validation fails closed on strong language drift"`. German input (expectedBase=de), English output of 40+ letters, throws.
- `"Output validation fails open on unknown recognizer result"`. gibberish output with no dominant lang, no throw.
- `"Output validation skipped entirely for expectedBase == en"`. connector shouldn't call the validator on English.

Expose whatever helper functions are needed with `internal` visibility + `@testable import` (don't use `public`). If `LanguageNormalizer` is `fileprivate`, change to `internal` so tests can reach it via `@testable import EnviousWisprLLM`.

#### 5.5.2. Connector-local tests (requires macOS 26 + FoundationModels)
Guard with `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`. In the CLT test environment these compile but are filtered at runtime.

- Spy the NLLanguageRecognizer behavior via a testable helper exposed to tests.
- Test the language-aware prompt construction when `detectedLanguage != nil, != "en"`.
- Test the Parakeet path (nil detectedLanguage) produces prompt identical to pre-change.

**Test isolation for the shared `supportedLanguageProvider` static:** tests that swap the allowlist MUST use a scoped helper so tearDown always restores the original, and the suite MUST be marked serialized so parallel test runners don't race on the shared closure:

```swift
// In test file
@Suite(.serialized) // Swift Testing: serialize this suite
struct AppleIntelligencePolishTests {

 // Scoped override helper with defer-based restoration.
 // Use this for every test that needs a custom allowlist.
 private func withSupportedLanguages<T>(
 _ langs: Set<String>,
 perform: () throws -> T
 ) rethrows -> T {
 let old = AppleIntelligenceConnector.supportedLanguageProvider
 AppleIntelligenceConnector.supportedLanguageProvider = { langs }
 defer { AppleIntelligenceConnector.supportedLanguageProvider = old }
 return try perform()
 }

 @Test("Preflight gate throws unsupportedInputLanguage for language not in allowlist")
 func preflightGateRejectsUnsupported() throws {
 try withSupportedLanguages(["en", "fr"]) {
 // assert polish(...) with config.detectedLanguage="ar" throws .unsupportedInputLanguage("ar")
 }
 }
}
```

Never mutate `supportedLanguageProvider` without `defer`-based restoration. Never rely on tearDown-only restoration because Swift Testing's tearDown semantics differ from XCTest's.

#### 5.5.3. Runtime UAT
Rerun the 60-test matrix from the prior session using `/tmp/polish_matrix.py` (corpus + harness already in place).

Ship criteria:
- Reliable 7-lang set (en/es/fr/it/pt/ja/zh) maintains current quality (equal or better polish-ran rate; no NEW translation hallucinations).
- de and ko: translation hallucination eliminated on the list-style utterance. Polish either runs in-language or throws `requestFailed` and the pipeline falls back to raw text.
- Silent-fail 8 (ar/he/ru/uk/pl/th/ta/vi): polish gated out at request time (log shows `frameworkUnavailable: does not support language 'X'`), pipeline passes raw through in <100ms.
- Parakeet English dictation: byte-identical polished output to a pre-change baseline on the same prompt + same vocab.

## 6. Blast radius & risk

### 6.1. Modules touched
- `EnviousWisprCore` (LLMResult.swift. one optional field added, backward-compatible init with default)
- `EnviousWisprLLM` (AppleIntelligenceConnector.swift. bounded rewrite; LLMProtocol.swift untouched)
- `EnviousWisprPipeline` (LLMPolishStep.swift. one line added to config init)
- Tests added, none deleted

No dependency direction changes. No AppState changes. No god objects. No new module boundaries. No schema migration.

### 6.2. Parakeet impact
Zero. Parakeet never sets `languageDetection` so `config.detectedLanguage` is nil. The connector's nil-language branch uses the unchanged `onDeviceInstructions` constant. Parakeet's English polish path is byte-identical.

### 6.3. Reliable-7 impact
Small behavior change: the new language-aware prompt prefix is prepended to the onDeviceInstructions for non-English inputs. Risk: the model might polish differently on es/fr/it/pt/ja/zh after the prompt change. Mitigation: the UAT matrix reruns these and checks for regression. GPT council's analysis suggests this should be equal-or-better, not worse.

### 6.4. Translation-hallucination impact
de and ko should stop translating. If they still translate, the NLLanguageRecognizer output validation catches it and throws, causing the pipeline to fall back to raw text. Net effect: wrong-language output impossible for non-English utterances >= 24 chars.

### 6.5. Silent-fail impact
8 languages gated out at request time. No round trip. Log shows the gate reason. Pipeline passes raw through. This is strictly an improvement.

### 6.6. Heart protection
Polish remains a limb. All failure paths (gate, empty output, language drift) throw `LLMError`, which is caught by the pipeline's `TextProcessingChain` timeout/error handler and falls back to raw text. No new throw escape past the pipeline boundary.

### 6.7. Known risks
- `SystemLanguageModel.default.supportedLanguages` may return an empty array on some OS builds before the model has been loaded. The fallback to `AppleIntelligenceCapabilities.documentedSupportedLanguages` covers this.
- `NLLanguageRecognizer` can misidentify short strings or code-switched content. Length gate (>=24 chars) plus base-code comparison mitigates. Monitor false-reject rate via telemetry.
- Custom system prompts (user-authored via styleConfig.customSystemPrompt) bypass the language injection. This is intentional per the existing "if user set a fully custom prompt, respect it as-is" branch. Document as a known limitation.
- `Locale.current.localizedString(forIdentifier:)` returns names in the user's display locale, not the target language. For "ja", a US user sees "Japanese"; a Japanese user sees "日本語". The prompt itself is in English regardless. This is acceptable because the 3B model understands English instruction about target languages.

### 6.8. Rollback
Three-line revert in `LLMPolishStep.swift` (drop the new config field assignment) + one-line revert in `LLMProviderConfig.init` (drop the parameter) + `AppleIntelligenceConnector.swift` back to pre-change via git checkout. No schema, no persisted state, no user-visible UI. Clean rollback.

## 7. Workflow & commands

### 7.1. Session setup
```bash
# From main repo (/Users/m4pro_sv/Desktop/EnviousWispr)
cd /Users/m4pro_sv/Desktop/EnviousWispr
git fetch origin
git worktree add -b feat/apple-intelligence-lang-gate \
 /Users/m4pro_sv/Desktop/EnviousWispr-ai-lang-gate origin/main

cd /Users/m4pro_sv/Desktop/EnviousWispr-ai-lang-gate
git status # should show clean worktree on new branch
```

### 7.2. Implementation order
1. Edit `Sources/EnviousWisprCore/LLMResult.swift` (add optional field).
2. Edit `Sources/EnviousWisprCore/LanguageTypes.swift` (add fallback set).
3. Edit `Sources/EnviousWisprPipeline/LLMPolishStep.swift` (thread detectedLanguage into config).
4. Edit `Sources/EnviousWisprLLM/AppleIntelligenceConnector.swift` (full design from section 5.3).
5. Add `Tests/EnviousWisprTests/LLM/AppleIntelligencePolishTests.swift`.
6. Run tests: `scripts/swift-test.sh`. 250 tests pass → 254+ with new cases.
7. Build: `swift build -c release`.
8. Bundle: `./scripts/bundle-dev.sh`.
9. Set provider: `defaults write com.enviouswispr.app.dev llmProvider -string appleIntelligence; defaults write com.enviouswispr.app.dev llmModel -string apple-intelligence`.
10. Reset session memory: `defaults delete com.enviouswispr.app.dev sessionLanguagePriors`.
11. Rerun UAT: `python3 /tmp/polish_matrix.py` (harness + corpus preserved from prior session; if missing, see section 8).
12. Inspect results: compare `/tmp/polish_matrix_results.jsonl` against the pre-change baseline.
13. Codex review: `codex review --uncommitted` (direct CLI, never `codex:rescue` plugin).
14. Commit, push, open PR against main, watch CI, merge.

### 7.3. UAT harness location
The 20-language × 3-utterance-type matrix script is at `/tmp/polish_matrix.py`. The baseline results from the session that produced this plan are at `/tmp/polish_matrix_results.jsonl`. Save both to the new benchmark results folder before starting, since `/tmp/` is wiped on reboot:

```bash
mkdir -p benchmark-results/apple-polish-2026-04-12
cp /tmp/polish_matrix.py benchmark-results/apple-polish-2026-04-12/harness.py
cp /tmp/polish_matrix_results.jsonl benchmark-results/apple-polish-2026-04-12/baseline.jsonl
```

After the fix, rerun and save post-change results alongside. The jsonl schema is stable.

### 7.4. Setup required for UAT
- Google Cloud TTS access via business service account: `~/.enviouswispr-keys/business-workspace-admin-sa.json` (project `ageless-domain-493017-j8`, TTS API enabled, workspace-admin SA has cloud-platform scope).
- App running with Apple Intelligence provider selected (via `defaults write` above or Settings UI).
- `~/Desktop/EnviousWispr/Tests/UITests/simulate_input.py` available on sys.path (the harness imports it).
- User NOT typing into any app during the run; rcmd PTT hold will trigger input capture.

### 7.5. Exact UAT commands

```bash
# Preserve the prior-session corpus (don't regenerate)
mkdir -p benchmark-results/apple-polish-2026-04-12
cp /tmp/polish_matrix.py benchmark-results/apple-polish-2026-04-12/harness.py
[[ -f /tmp/polish_matrix_results.jsonl ]] && \
 cp /tmp/polish_matrix_results.jsonl benchmark-results/apple-polish-2026-04-12/baseline.jsonl

# Reset session memory + launch matrix
defaults delete com.enviouswispr.app.dev sessionLanguagePriors 2>/dev/null
python3 /tmp/polish_matrix.py 2>&1 | tee benchmark-results/apple-polish-2026-04-12/postchange.log

# Compare against baseline
python3 -c "
import json
base = {(r['lang'], r['utt']): r for r in map(json.loads, open('benchmark-results/apple-polish-2026-04-12/baseline.jsonl'))}
post = {(r['lang'], r['utt']): r for r in map(json.loads, open('/tmp/polish_matrix_results.jsonl'))}
for key in sorted(base.keys() | post.keys()):
 b, p = base.get(key, {}), post.get(key, {})
 if b.get('polished') != p.get('polished'):
 print(f'{key}: polish CHANGED')
 print(f' baseline: {(b.get(\"polished\") or \"\")[:80]}')
 print(f' post: {(p.get(\"polished\") or \"\")[:80]}')
"
```

The harness has no args (config is inline). It expects the business SA JSON at the path in section 7.4 and the app running on Apple Intelligence. Total runtime ~25-30 min.

## 8. Council session names (for resumption)

- `apple-polish-gpt` (openai/gpt-5.4, reasoning=medium). authoritative Swift code + pattern recommendations.
- `apple-polish-gemini` (gemini-3.1-pro-preview). partially wrong about API privacy, right on gating strategy.

Resume with the same session name to preserve context. Spawn a new session name for a fresh review (per `feedback_council_usage` memory).

## 9. Gotchas

- **Caching:** lazy-static once per process (see 5.3 exact code). Frozen for process lifetime. Do NOT invalidate on OS upgrade within the same process. app restart handles that.
- **`PolishInstructions.default` branch in `makeSession`:** preserved. Users who set a fully custom `styleConfig.customSystemPrompt` bypass the entire on-device-instructions path via the `else` branch. No language injection on custom prompts. This is intentional. user explicitly opted out.
- **`appleIntelligenceInstructions` in `LLMPolishStep` (the enrichment function around line 369):** unchanged in scope. It composes custom vocabulary onto `base.systemPrompt`. The language clause is injected inside `AppleIntelligenceConnector.makeSession` BEFORE the vocabulary suffix is appended, so the constraint survives the concat.
- **NLLanguageRecognizer threshold: count alphabetic Unicode scalars only** (not bytes, not total chars including punctuation/digits/whitespace). The `.unicodeScalars.filter(\.properties.isAlphabetic).count` expression is the canonical metric. 24 letters minimum.
- **Chinese collapse rule:** `cmn-CN`, `yue`, `zh-Hans`, `zh-Hant` all normalize to `"zh"` via `LanguageNormalizer.baseCode`. Chirp3-HD voice names use `cmn-CN` locale tags; WhisperKit returns `zh`. Both paths reach `"zh"` after normalization.
- **`detectLangauge` typo is WhisperKit's, not ours.** Our codebase calls `whisperKit.detectLangauge(audioArray:)` deliberately because that's the upstream public API name. Our new field is `detectedLanguage` (correct spelling, no typo). Don't confuse the two.
- **macOS `say` voices not needed for UAT.** The harness uses Google Cloud Chirp3-HD via the business service account. Prior session's switch from macOS `say` is documented; do not revert.
- **Parakeet byte-identity check (mandatory before shipping):** with Parakeet backend selected and Apple Intelligence polish, run one PTT dictation of the English prompt used in the 60-test `en/normal` case. Compare the polished output char-for-char to the pre-change baseline (captured in `benchmark-results/apple-polish-2026-04-12/baseline.jsonl`). Byte-identity required. If it differs, the nil-language branch is broken.
- **`Codable` / `Sendable` on `LLMProviderConfig`:** adding an optional `String?` with a default value keeps auto-synthesized `Codable` backward-compatible (existing persisted configs decode with `detectedLanguage = nil`). `Sendable` unaffected.
- **Test seam for `SystemLanguageModel.supportedLanguages` (exact mechanism, no "or"):** expose `internal static var supportedLanguageProvider: () -> Set<String>` in `AppleIntelligenceConnector`, defaulting to `{ AppleIntelligenceSupport.baseCodes }`. The preflight gate reads from the closure, not from `AppleIntelligenceSupport.baseCodes` directly. Tests set `AppleIntelligenceConnector.supportedLanguageProvider = { ["en", "es", "fr"] }` in setup and restore the original in teardown. This avoids mutating the lazy static and gives tests full control over the allowlist without any production branching.
- **Locale.Language `.maximalIdentifier` is the right accessor** for the normalization input. It returns the canonical BCP-47 tag (`zh-Hans-CN`, `en-US`, etc.) which the normalizer parses to a base code.
- **No retry on validation failure.** Pipeline fallback to raw text IS the final action. Retrying with a stronger prompt is explicitly out of scope and would introduce latency variance.

## 10. Ship criteria checklist

Functional:
- [ ] `swift build -c release` exit 0
- [ ] `scripts/swift-test.sh` passes, total count 254+
- [ ] 60-test UAT matrix rerun: zero translation hallucinations on de/ko
- [ ] 60-test UAT matrix rerun: ar/he/ru/uk/pl/th/ta/vi gated at request time (logs show `frameworkUnavailable`)
- [ ] Parakeet English dictation + Apple Intelligence polish still works, byte-identical output
- [ ] Reliable 7 (en/es/fr/it/pt/ja/zh) maintain polish quality, no regressions

Code quality:
- [ ] Zero em-dashes in new code (grep check)
- [ ] Codex review pass: all findings validated, fixed or dismissed with reasoning
- [ ] No new dead-code warnings from Periphery (redundant-public OK if pattern-consistent)

Architecture DoD:
- [ ] Module placement documented in PR body
- [ ] Heart protection verified: polish limb still falls back to raw on any throw
- [ ] Dependency direction unchanged
- [ ] AppState unchanged

External:
- [ ] Architecture Closeout comment on related issue (or new follow-up issue for this work)
- [ ] CI green on merge, main post-merge check green

## 11. Time estimate

Implementation (no UAT device time):
- Read current code + confirm call-site audit: 15 min
- Code changes (5 files): 60-75 min
- Unit tests (normalization matrix + config threading + allowlist + prompt wiring): 30-45 min
- Rebuild + bundle-dev: 5-10 min

UAT (requires device + uninterrupted PTT capture):
- Save `/tmp/polish_matrix.py` + prior `/tmp/polish_matrix_results.jsonl` as baseline
- Matrix rerun (60 × ~25s): 25-30 min (must not touch keyboard/mouse during run)
- Result diff + classification: 15 min

Review + ship:
- Codex review pass + address findings: 20-40 min
- PR + CI watch + merge: 15-30 min

Total: implementation 2-2.5h, UAT 1h, review+ship 0.5-1h. **Budget 4h for an autonomous session**; 3h if no codex findings require rework.

## 12. Open questions

- Should we add a Settings UI surface explaining Apple Intelligence's language limits? Defer to follow-up. Settings copy work is a separate task.
- Should we add telemetry events for `polish.gated.unsupported_language` and `polish.empty_generation`? Recommended but can ship first without, validate via logs, then add.
- Is there value in retrying with a different strategy when language drift is detected? E.g., re-call with an even stronger language-constraint prompt. No. raw passthrough is safer than an unbounded retry loop in a limb.
- Should the fallback `documentedSupportedLanguages` set include Korean and German given they're the translation-hallucination risks? Yes. they ARE supported by the model; the hallucination is a prompt problem, not a capability problem. Keep them in the set.

## 13. Related

- Epic: #242 (Multilingual v1)
- Predecessor PR: #257 (merged 2026-04-12)
- Parent spec: `docs/feature-requests/multilingual-v1-followup.md` section "Native-speaker TTS for multilingual test corpus" and section 11 ship criteria
- Memory: `project_multilingual_v1_state`, `feedback_refactor_discipline`, `feedback_check_tool_layers`, `feedback_validate_review_findings`, `feedback_runtime_uat_catches_static`

## 14. What "done" looks like

A user dictating German into EnviousWispr with Apple Intelligence polish selected sees polished German on paste (not English). A user dictating Arabic sees raw Arabic ASR (not silent-fail confusion). A user dictating English with Parakeet sees the same polished output as today. The 60-test matrix passes with translation hallucinations eliminated and silent-fail languages cleanly gated. No rules broken. No Parakeet regression. Merged on a clean MEDIUM-tier PR.
