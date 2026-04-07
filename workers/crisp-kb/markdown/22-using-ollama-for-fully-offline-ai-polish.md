Ollama lets you run local language models on your Mac. Combined with EnviousWispr's on-device speech recognition, this gives you a fully offline dictation pipeline: no internet connection needed, no data leaves your machine.

### Setup

1. Install Ollama from [ollama.com](https://ollama.com).
2. Start the Ollama server (it runs on `localhost:11434` by default).
3. Pull a model: `ollama pull llama3.2` (or any model you prefer).
4. In EnviousWispr, open settings and go to the **AI Polish** tab.
5. Select **Ollama** as the provider.
6. Choose your installed model from the dropdown. EnviousWispr auto-discovers installed models by querying the Ollama API.

### Model management

EnviousWispr shows your installed Ollama models and classifies them into quality tiers. You can pull new models or delete existing ones directly from the settings UI.

### Tips

* Larger models produce better polish but use more RAM and are slower.
* For quick dictation polish, a 7B-parameter model is a good balance of quality and speed.
* Ollama must be running before you start dictating. EnviousWispr detects the server automatically.

### If Ollama is down

If the Ollama server is not running or unreachable, AI polish silently falls back to raw transcription. Your dictation is never lost, but the text will be unpolished. Check that Ollama is running if your output seems unprocessed.