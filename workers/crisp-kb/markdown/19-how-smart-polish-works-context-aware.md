Smart Polish is EnviousWispr's context-aware AI polish system. It enriches the LLM prompt with information about your dictation so the AI makes better corrections.

### What Smart Polish adds to the prompt

When using an API provider (OpenAI, Gemini, or Ollama), the polish prompt is automatically enriched with:

* **ASR awareness:** The LLM is told that the input is speech recognition output and may contain phonetically similar but contextually incorrect words (e.g., "their" vs. "there", "cache" vs. "cash").
* **App context:** The name of the app you are dictating into is included. The AI knows whether you are writing in Slack, VS Code, a browser, etc. The target app is captured when recording starts.
* **Language directive:** For non-English transcripts, the prompt instructs the LLM to polish in the source language, not translate to English.
* **Short text handling:** Transcripts between 4 and 10 words get an instruction to return as-is with minimal fixes.
* **Custom vocabulary:** Your custom words (from the **Your Words** tab) are injected into the prompt as preferred spellings, giving the LLM a second correction layer beyond regex-based word correction.

### Prompt handling

If you dictate something like "ignore previous instructions," the AI still polishes your text correctly. The system prompt is structured so that dictated content is treated as text to polish, not as instructions to follow.