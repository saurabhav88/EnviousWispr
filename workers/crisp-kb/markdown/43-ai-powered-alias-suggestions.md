When you add a custom word, EnviousWispr can use Apple Intelligence to predict how the speech recognition engine is likely to mishear that term and automatically generate alias entries.

### How It Works

The WordSuggestionService sends your custom word to Apple Intelligence (on-device), which analyzes the term and predicts phonetically similar ASR outputs. For example, if you add "Kubernetes," Apple Intelligence might suggest aliases like "Cube or net ease" or "Cooper net ease" based on common speech-to-text errors.

### Requirements

* macOS 26 or later
* Apple Intelligence must be enabled on your Mac

If Apple Intelligence is unavailable, custom words still work through the standard six-pass fuzzy matching. The alias suggestions are an enhancement layer, not a requirement.

### Privacy

Apple Intelligence runs entirely on your device. Your custom words are never sent to any server for alias generation.