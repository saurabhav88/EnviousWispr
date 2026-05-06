AI polish is optional and off by default. When enabled, the provider you choose determines whether any data leaves your device.

### Fully Local Providers (No Data Leaves Your Device)

* **None**: AI polish is disabled. This is the default. No data is sent anywhere.
* **Apple Intelligence**: Runs entirely on-device using Apple's built-in models. No API key required, no network calls.
* **Ollama**: Runs a local LLM on your machine via the Ollama server. All processing stays on localhost.

### Cloud Providers (Transcribed Text Is Sent)

* **OpenAI**: Your transcribed text is sent to OpenAI's API for polishing. Requires your own API key. EnviousWispr sends `store: false` on each request so OpenAI is asked not to retain the prompt or response.
* **Gemini**: Your transcribed text is sent to Google's Gemini API for polishing. Requires your own API key. EnviousWispr sends `store: false` on each request so Google is asked not to retain the prompt or response.

### What Is Sent to Cloud Providers

When using OpenAI or Gemini, only the **transcribed text** is sent. Audio is never sent. The request includes:

* The transcribed text to polish
* A system prompt with instructions (writing style, custom vocabulary)
* Your API key for authentication
* A `store: false` flag for OpenAI and Gemini provider-side retention

### What Is Never Sent

* Audio recordings
* Other transcripts or history
* System information or device identifiers

### What `store: false` Means

For OpenAI and Gemini, `store: false` is a request-level privacy flag. It tells the provider not to keep that specific polish request or response in server-side history. It does not make cloud polish fully local; the text still goes to the provider so the model can polish it.

### Graceful Degradation

If AI polish fails for any reason (network error, timeout, provider outage), the raw transcription is used instead. You never lose your dictation because of an AI polish failure.
