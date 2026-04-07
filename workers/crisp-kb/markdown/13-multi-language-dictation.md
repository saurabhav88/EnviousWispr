EnviousWispr supports multi-language dictation through the WhisperKit engine.

### Setup

1. Open the settings window and go to the **Transcription** tab.
2. Select **WhisperKit** as your speech engine.
3. Set your language from the language picker, or leave it on auto-detect.

### Supported languages

WhisperKit supports 90+ languages via OpenAI's Whisper model family. Parakeet v3 is English-only. For other languages, use WhisperKit.

### AI polish language handling

When AI polish is enabled with an API provider (OpenAI or Gemini), the polish prompt automatically includes a language directive: "This transcript is in [language]. Polish in [language]." This ensures the AI does not translate your text into English.

### Tips

* For best accuracy, explicitly set the language rather than relying on auto-detect.
* WhisperKit's auto-detect works well for single-language recordings but may be less reliable for mixed-language speech.