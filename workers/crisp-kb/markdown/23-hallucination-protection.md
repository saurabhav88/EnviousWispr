LLMs can sometimes "hallucinate," generating text that was not in the original dictation. EnviousWispr has a three-layer protection system to prevent this.

### Layer 1: Short transcript bypass

Transcripts of 3 words or fewer skip the LLM entirely. The text passes through verbatim. Very short inputs are most prone to hallucination, so bypassing the LLM for these is the safest approach.

### Layer 2: Output length validation

After the LLM returns a result, EnviousWispr compares the output length against the input. If the polished text is significantly longer than the original transcription, it is rejected as a likely hallucination and the raw ASR text is used instead.

### Layer 3: Preamble stripping

LLMs sometimes prepend responses with phrases like "Certainly!" or echo back the original instructions. EnviousWispr automatically strips these preamble artifacts from the output before pasting.

### Fallback behavior

If any protection layer triggers, or if the LLM fails entirely, you always receive your raw transcribed text. If any protection layer triggers, or if the AI fails entirely, raw transcription always completes and is delivered to your app.