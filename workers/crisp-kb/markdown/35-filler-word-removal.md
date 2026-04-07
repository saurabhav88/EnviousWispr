Filler word removal strips common verbal fillers from your transcription: **um, uh, hmm, mm, mhm, ah, er**. Matching is case-insensitive. After removal, double spaces are collapsed and the text is trimmed.

## No AI Required

Filler removal is a regex-based post-processing step that runs independently of AI polish. It works even when the LLM provider is set to None and the app is fully offline.

## Performance

Filler removal has a 50ms timeout budget. If it somehow exceeds this (extremely unlikely given the regex approach), the pipeline falls back to the unfiltered text. Your dictation is never lost or delayed by this step.

## Processing Order

Filler removal runs as the second step in the text processing chain:

1. Word Correction (custom dictionary)
2. Filler Removal
3. LLM Polish (if enabled)

This order means fillers are removed before the text reaches the LLM, giving the AI cleaner input to work with.

## Enabling and Disabling

Filler removal can be toggled in the app settings. It is a separate control from AI polish.