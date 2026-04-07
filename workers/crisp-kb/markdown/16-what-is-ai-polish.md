AI Polish is an optional post-processing step that cleans up your transcribed text. When enabled, an LLM (large language model) fixes grammar, removes filler words, and polishes your dictation while preserving your original meaning.

### What AI Polish does

* Fixes grammar and punctuation errors.
* Removes filler words (um, uh, hmm, ah, er, etc.).
* Cleans up sentence structure while keeping your intent.
* Applies a writing style if you have one configured (Standard, Formal, Friendly, or Custom).

### What AI Polish does NOT do

* It does not add new information or ideas. Your words are your words.
* It does not translate. If you dictate in French, you get polished French.
* For very short transcripts (3 words or fewer), the text passes through verbatim. The LLM is not invoked.

### Graceful degradation

AI Polish is optional and never blocks the critical path. If the AI provider is unavailable, times out, or returns an error, you still get your raw transcribed text. Your dictation is never lost because of an AI failure. The LLM polish step has a 5-second timeout budget.

### Default state

AI Polish is **off by default** (provider set to None). EnviousWispr works fully offline out of the box. You choose whether and how to enable AI polish.