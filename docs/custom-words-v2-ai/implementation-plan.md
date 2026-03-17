# Custom Words v2 — Apple Intelligence Integration Plan

## What We Have (shipped today)

- `CustomWord` model with UUID, canonical, aliases, category, priority, forceReplace
- `CustomWordsManager` with atomic persistence + migration from old `[String]` format
- `WordCorrector` with 3-pass correction: multi-word alias → single alias → fuzzy scoring
- Edit sheet for per-word category/alias/forceReplace editing (users don't discover it — UX gap)
- Deterministic resolver works offline on all supported macOS versions

## What's Wrong

1. Users don't know they can tap a word to edit it — the edit sheet is hidden
2. Aliases must be manually entered — users won't do this
3. Deterministic matching can't handle novel ASR misrecognitions
4. No integration with Apple Intelligence despite targeting M-series users on current macOS

---

## Phase 1: UX + Apple Intelligence Auto-Suggest (ew-ceh)

### Goal
When a user adds a custom word, the system auto-categorizes it and suggests phonetic aliases. Zero manual work for the common case.

### UX Flow
1. User types "Claude" and hits Add
2. Edit sheet opens immediately (not hidden behind tap-to-discover)
3. Loading spinner in category + aliases sections
4. Foundation Models call returns: category=brand, aliases=["cloud","clawed","clod","clot"]
5. Category auto-selected, aliases pre-populated as chips
6. User reviews, optionally tweaks, hits Save
7. Pre-macOS 26: sheet opens with empty fields, user fills manually

### Implementation

#### `Sources/EnviousWispr/PostProcessing/WordSuggestionService.swift` (new)
```swift
import FoundationModels

@Generable
struct WordSuggestions {
    @Guide(description: "Category: person, brand, acronym, domain, or general")
    let category: String
    @Guide(description: "Common ways speech recognition might mishear this word")
    let suggestedAliases: [String]
}

@MainActor
final class WordSuggestionService {
    private var session: LanguageModelSession?

    var isAvailable: Bool {
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        return false
    }

    func suggest(for word: String) async -> WordSuggestions? {
        guard #available(macOS 26, *) else { return nil }
        if session == nil {
            session = LanguageModelSession(instructions: {
                "You categorize words and predict speech recognition errors."
            })
        }
        let prompt = """
            The user added "\(word)" to their dictation app's custom word list.
            What category is it? What might speech-to-text mishear it as?
            """
        return try? await session!.respond(to: prompt, generating: WordSuggestions.self).content
    }
}
```

#### `WordFixSettingsView.swift` changes
- `addWord()` creates the `CustomWord`, opens edit sheet immediately
- Sheet shows loading state, fires `WordSuggestionService.suggest(for:)`
- On completion, auto-fills category picker + alias chips
- User can accept/modify/dismiss

#### `AppState.swift` changes
- Add `let wordSuggestionService = WordSuggestionService()`
- No pipeline changes — suggestions only affect the stored word metadata

### What Doesn't Change
- WordCorrector, WordCorrectionStep, pipeline — untouched
- Existing words — unaffected (no retroactive suggestions)

### Verification
- macOS 26+: Add "Kubernetes" → sheet opens → category auto-fills "domain" → aliases suggest "kubernetes", "kubernetis" etc
- Pre-macOS 26: Add word → sheet opens → fields empty → manual entry works
- Build gate: `swift build` must pass with `#available` guards

---

## Phase 2: Foundation Models as Primary Correction Layer (ew-2zt)

### Goal
After ASR produces raw text, pass it through Foundation Models with the user's custom word list for context-aware correction. Replaces fuzzy matching as primary — deterministic resolver becomes the fallback.

### Architecture
```
ASR output
  ↓
Foundation Models correction (macOS 26+, Apple Intelligence on)
  ↓ fallback if unavailable
Deterministic WordCorrector (current system)
  ↓
LLM Polish (if enabled — cloud or Foundation Models)
  ↓
Paste/clipboard
```

### The Session Question
Can word correction and polishing share one Foundation Models session?

**Option A: Combined prompt** (preferred if token budget allows)
```
System: "You correct and polish dictated text.
Custom vocabulary: [Claude, EnviousWispr, Saurabh, Malavika]
Polish style: [user's polish instructions]"

User: [raw ASR text]
→ One call, one response, corrected + polished
```
Token budget: ~200 tokens for instructions + vocabulary + polish rules. Leaves ~3,800 for text + response. For typical dictation (1-5 sentences), this works.

**Option B: Sequential sessions**
```
Session 1 (correction): raw text → corrected text
Session 2 (polish): corrected text → polished text
```
Doubles latency. Only needed if combined prompt degrades quality.

**Recommendation**: Start with Option A. Fall back to B only if testing shows quality issues.

### Implementation

#### `Sources/EnviousWispr/Pipeline/Steps/WordCorrectionStep.swift` changes
```swift
func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    // Try Foundation Models first
    if let fmResult = await foundationModelCorrect(context.text, words: customWords) {
        var ctx = context
        ctx.text = fmResult
        return ctx
    }
    // Fallback: deterministic resolver
    let corrector = WordCorrector()
    let (fixed, count) = corrector.correct(context.text, against: customWords)
    // ... existing logic
}
```

#### When Apple Intelligence is selected for BOTH correction and polish
- If user has Apple Intelligence as their polish provider AND word correction enabled:
  - Use Option A (combined prompt) — correct + polish in one call
  - Skip the separate WordCorrectionStep to avoid double-processing
  - The LLMPolishStep handles both
- If user has cloud LLM (OpenAI/Gemini) for polish:
  - WordCorrectionStep uses Foundation Models for correction
  - LLMPolishStep uses cloud LLM for polish
  - Two separate steps, no conflict

#### `Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift` changes
- When provider is Apple Intelligence: inject custom word list into polish prompt
- Combined mode: single Foundation Models call does correction + polish

### What Doesn't Change
- WordCorrector stays as deterministic fallback
- Cloud LLM polish path untouched
- CustomWordsManager, CustomWord model — untouched

### Verification
- Dictate "my name is sorab and I use cloud code" → corrects to "Saurabh" and "Claude Code" without any aliases configured
- Toggle Apple Intelligence off → falls back to deterministic WordCorrector
- Measure latency: correction pass should add <3 seconds

---

## Phase 3: Cloud LLM Polish with Custom Words (ew-awj)

### Goal
Users with their own API keys get custom word correction baked into their cloud polish call. No separate correction step needed — the cloud LLM handles it contextually.

### Implementation

#### `Sources/EnviousWispr/Pipeline/Steps/LLMPolishStep.swift` changes
When cloud LLM polish is enabled AND custom words exist:
```swift
let wordList = customWords.canonicals.joined(separator: ", ")
let enhancedPrompt = """
    \(polishInstructions)

    IMPORTANT: The following are the user's preferred spellings for proper nouns,
    names, and technical terms. Always use these exact spellings when the
    transcribed text contains similar-sounding words:
    \(wordList)
    """
```

#### Interaction with Phase 2
- If Apple Intelligence handles correction (Phase 2) AND user has cloud polish:
  - Foundation Models corrects → cloud LLM polishes (sequential, different providers)
- If user has cloud LLM for everything (no Apple Intelligence):
  - Skip Foundation Models correction entirely
  - Cloud LLM gets custom words in polish prompt — handles both
- If user has no polish enabled:
  - Foundation Models correction only (Phase 2) or deterministic fallback

### What Doesn't Change
- OpenAIConnector, GeminiConnector — API calls unchanged
- Only the prompt construction changes

### Verification
- Set polish to OpenAI + custom words enabled
- Dictate with known ASR errors → verify cloud LLM fixes them using the word list
- Verify token usage doesn't explode (word list adds ~50-200 tokens to prompt)

---

## Decision Matrix: What Runs When

| Apple Intelligence | Polish Provider | Word Correction | Polish |
|---|---|---|---|
| Available | Apple Intelligence | Combined: FM does both in one call | (included above) |
| Available | Cloud (OpenAI/Gemini) | FM correction step | Cloud LLM with word list in prompt |
| Available | None | FM correction step | Skipped |
| Unavailable | Cloud (OpenAI/Gemini) | Deterministic WordCorrector | Cloud LLM with word list in prompt |
| Unavailable | None | Deterministic WordCorrector | Skipped |

---

## Migration Path

- Phase 1 ships independently — pure UX improvement + auto-suggest
- Phase 2 requires macOS 26 SDK but gracefully degrades via `#available`
- Phase 3 is additive — enhances existing cloud polish without breaking it
- Deterministic WordCorrector + aliases remain as permanent offline floor
- No user data migration needed — same CustomWord model throughout

## Open Questions (resolve during implementation)

1. Foundation Models quality for combined correct+polish vs separate passes
2. Token budget pressure with large custom word lists (>50 words) + long polish instructions
3. Rate limiting behavior under rapid sequential dictations
4. Whether `session.prewarm()` should fire on app launch or on recording start
