EnviousWispr includes a custom word dictionary that corrects ASR output for proper nouns, technical terms, and specialized vocabulary the speech model may misspell.

### Built-in Vocabulary

EnviousWispr ships with a built-in tech vocabulary that handles common terms out of the box, including macOS, GitHub, and ChatGPT. These work without any configuration.

### Adding Your Own Words

Open **Settings** and navigate to the **Your Words** section. Add the correct spelling of any term the speech engine consistently gets wrong. For example, if the ASR outputs "Chat G P T," adding "ChatGPT" as a custom word will correct it automatically.

### Dual-Layer Correction

Custom words work at two levels:

* **Regex-based correction** (the word correction step): Matches ASR output against your custom word list using six-pass fuzzy matching before any AI polish runs.
* **LLM prompt injection**: Your custom words are also injected into the AI polish prompt as a preferred-spellings list, so the LLM knows your vocabulary when polishing text.

This dual-layer approach means corrections happen even if AI polish is turned off, and AI polish gets extra context about your vocabulary when it is on.