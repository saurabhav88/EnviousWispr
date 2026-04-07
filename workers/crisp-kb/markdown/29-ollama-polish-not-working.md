Ollama polish requires the Ollama server to be running on your Mac. EnviousWispr connects to it at `http://localhost:11434`.

## Troubleshooting Steps

1. **Is Ollama installed?** Download it from [ollama.com](https://ollama.com) if you have not already.
2. **Is the server running?** Start it with `ollama serve` in Terminal, or launch the Ollama app. The server must be running before you start recording.
3. **Is a model downloaded?** You need at least one model installed. Run `ollama list` in Terminal to see your installed models, or `ollama pull llama3` to download one.
4. **Check the timeout.** EnviousWispr uses a strict 3-second timeout when connecting to the Ollama server. If the server is slow to respond, the connection may time out.

## Fallback Behavior

If Ollama is unreachable or the request times out, EnviousWispr falls back to using the raw ASR text. Your dictation is never lost. The text will be unpolished but still pasted into your app.

## Model Selection

EnviousWispr auto-discovers your installed Ollama models. You can select which model to use in **Settings > AI Polish**. Models are classified by quality tier; smaller models may hide some advanced polish options.