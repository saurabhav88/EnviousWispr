### Writing style presets

EnviousWispr includes four writing style presets that control the tone of AI polish output:

* **Standard:** Clean, neutral tone. Fixes grammar and removes filler without changing your voice.
* **Formal:** Professional, polished language suitable for business communication.
* **Friendly:** Warm, conversational tone.
* **Custom:** Write your own system prompt to control exactly how the AI processes your text.

### Custom system prompts

When you select the Custom writing style, a text field appears where you can enter your own instructions for the AI. This gives you full control over how the LLM behaves.

You can use the `${transcript}` placeholder in your custom prompt. If present, EnviousWispr replaces it with the transcribed text.

### Where to configure

Open the settings window, go to the **AI Polish** tab. The writing style picker and custom prompt field are there.

### Note on Apple Intelligence

Apple Intelligence uses its own on-device instruction format and does not use the enriched prompt system that API providers (OpenAI, Gemini, Ollama) use. Writing style presets still apply, but the advanced prompt enrichment (ASR-awareness, app context) is specific to API providers.