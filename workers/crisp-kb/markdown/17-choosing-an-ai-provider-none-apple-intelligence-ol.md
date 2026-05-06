EnviousWispr supports five AI polish providers. Open the settings window and go to the **AI Polish** tab to configure.

### None (default)

No AI processing. Raw transcription is delivered as-is, with optional filler word removal and custom word correction still applied.

### Apple Intelligence

Uses Apple's on-device language model. Free, private, no API key required. Requires macOS 26+ and Apple Silicon. See the *Apple Intelligence Setup* article for requirements.

### Ollama

Connects to a locally running Ollama server for fully offline AI polish. You choose which model to run. No data leaves your Mac. See *Using Ollama for Fully Offline AI Polish*.

### OpenAI

Uses OpenAI's API (GPT models). Requires an OpenAI API key. Text is sent to OpenAI's servers for processing. EnviousWispr sends `store: false` with each request so OpenAI is asked not to retain the prompt or response. Enter your API key in the AI Polish settings.

### Gemini

Uses Google's Gemini API. Requires a Gemini API key. Text is sent to Google's servers for processing. EnviousWispr sends `store: false` with each request so Google is asked not to retain the prompt or response. Supports SSE streaming for lower perceived latency. Enter your API key in the AI Polish settings. Extended thinking is available with Gemini 2.5 Flash and Pro models.

### Choosing a provider

| Provider | Privacy | Cost | Requires |
| --- | --- | --- | --- |
| None | Full privacy | Free | Nothing |
| Apple Intelligence | On-device | Free | macOS 26+, Apple Silicon |
| Ollama | On-device | Free | Ollama installed and running |
| OpenAI | Cloud text only, `store: false` | API usage | API key |
| Gemini | Cloud text only, `store: false` | API usage | API key |
