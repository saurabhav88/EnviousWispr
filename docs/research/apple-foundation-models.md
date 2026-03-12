# Apple Foundation Models — Research (2026-03-11)

## Overview
~3B parameter on-device LLM. Free, offline, private. macOS 26+ / Apple Silicon M1+.

## API
```swift
let session = LanguageModelSession(instructions: { "Correct transcribed speech using: Claude, EnviousWispr, Saurabh" })
let response = try await session.respond(to: rawText)
// Or structured:
let result = try await session.respond(to: prompt, generating: CorrectedText.self)
```

## @Generable Guided Generation
Constrained decoding — model output forced to match Swift struct at decode time (not post-hoc parsing).
```swift
@Generable struct CorrectedText {
    @Guide(description: "Corrected text") let corrected: String
    @Guide(description: "Corrections applied") let replacements: [Replacement]
}
```
Supports nested structs, enums, `.range()`, `.count()`, `.anyOf()` constraints.

## Key Constraints
- **4,096 token context window** (input + output combined). ~50-100 custom words in prompt is practical.
- **~30 tokens/sec** on M-series. 1-3 seconds for short corrections.
- **One request per session** at a time. Multiple sessions allowed.
- **Neural Engine contention** with WhisperKit possible if concurrent. Our sequential pipeline (ASR → correct → polish) avoids this.
- **No rate limit foreground**, budget-limited when backgrounded.
- **session.prewarm()** preloads resources before user triggers request.

## Availability Check
```swift
let model = SystemLanguageModel.default
switch model.availability {
case .available: // proceed
case .unavailable(.appleIntelligenceNotEnabled): // user hasn't enabled
case .unavailable(.deviceNotEligible): // hardware can't run it
}
```

## Custom Adapters
LoRA fine-tuning. ~160MB adapter weights. Python toolkit. Requires Apple entitlement.
**Pain point:** Must retrain per OS version when Apple updates the base model.
Not worth it for V1 — prompt-based approach is sufficient for word correction.

## Quality
Competitive with Qwen-2.5-3B. Good for ASR error correction. Not GPT-4 class.
MMLU: 64.4%, IFEval: 82.3%.

## Use Cases for EnviousWispr
1. **Word correction**: Inject custom word list into prompt, get contextual correction
2. **Auto-categorization**: When user adds word, infer category (person/brand/etc) and suggest phonetic aliases
3. **Polish (potential)**: Could replace cloud LLM for basic polish — open question on quality vs GPT-4/Gemini

## Open Questions
- Can word correction + polishing share one session or need sequential sessions?
- Quality comparison: Foundation Models polish vs cloud LLM polish
- Token budget when combining correction prompt + polish instructions + text
