EnviousWispr includes two speech recognition engines. Both run entirely on your Mac. No audio is ever sent to a server.

### Parakeet v3 (default)

* Built on NVIDIA's Parakeet TDT 0.6B model via the FluidAudio framework.
* **Streaming ASR:** Transcription runs in parallel with recording (when Live transcription is enabled), so results are nearly instant after you stop speaking.
* **Speed:** Approximately 110x real-time factor. 60 seconds of audio transcribes in under 1 second.
* **Language:** English only.
* **Setup:** Model downloads automatically during onboarding with progress tracking and SHA-256 checksum verification.

### WhisperKit

* Runs OpenAI Whisper models locally via Apple Core ML.
* **Multi-language:** Supports 90+ languages. Set the language in the **Transcription** tab, or leave it on auto-detect.
* **Model:** Default is large-v3-turbo. Models are downloaded when you select WhisperKit.
* **Batch processing:** WhisperKit transcribes after recording stops (not during). An incremental background worker provides progressive results during recording.
* **Quality controls:** Configurable temperature, no-speech threshold, and language selection.

### Which should I use?

|  | Parakeet v3 | WhisperKit |
| --- | --- | --- |
| Language | English | 90+ languages |
| Speed | Fastest (streaming) | Fast (batch) |
| Streaming ASR | Yes | No (incremental worker) |
| Best for | English dictation, speed | Multi-language, accuracy |

### Switching engines

Open the settings window, go to the **Transcription** tab, and select your preferred engine. The switch takes effect on your next recording.