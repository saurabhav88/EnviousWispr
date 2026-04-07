Extended Thinking mode tells the AI to spend more time reasoning about your text before producing output. This can improve quality for complex or nuanced dictation.

### Supported providers

* **Gemini:** Uses a thinking budget parameter. Available with Gemini 2.5 Flash and Pro models.
* **OpenAI:** Uses reasoning effort parameter. Available with o-series models.

### Enabling Extended Thinking

Open the settings window, go to the **AI Polish** tab, and enable **Extended Thinking**. This setting only appears when a compatible provider and model are selected.

### Trade-offs

* **Quality:** Can produce higher-quality polish for complex sentences, technical dictation, or ambiguous phrasing.
* **Speed:** Adds latency because the model spends more time on the response. For most dictation, standard mode is fast enough.

Apple Intelligence and Ollama do not support extended thinking.