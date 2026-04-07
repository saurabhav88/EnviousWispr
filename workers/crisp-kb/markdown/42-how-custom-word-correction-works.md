When you add a custom word, EnviousWispr does not rely on simple exact matching. Instead, the word correction engine runs a six-pass fuzzy matching algorithm designed to catch the many ways speech recognition can mangle a term.

### The Six Passes

Each pass uses a different similarity metric to find matches between what the ASR produced and what you intended:

1. **Levenshtein distance**: Measures character-level edit distance. Catches minor misspellings like "Kubernettes" instead of "Kubernetes."
2. **Soundex**: Phonetic algorithm that groups words by how they sound. Catches phonetically similar but visually different outputs like "Cue Bernetes" for "Kubernetes."
3. **Bigram Dice coefficient**: Compares overlapping character pairs between two strings. Effective at catching partial matches and transpositions.

These three metrics are applied across multiple passes with varying thresholds and normalization strategies, for a total of six passes. If any pass finds a match, the correction is applied.

### Example

If you add "ChatGPT" to your custom words, the corrector will catch ASR outputs like:

* "Chat G P T" (spacing artifacts)
* "Chat GPT" (partial split)
* "Chatgpt" (case variation)

### Processing Order

Word correction runs as the first step in the text processing chain, before filler removal and before AI polish. This means corrected terms are already in place when the LLM sees the text.