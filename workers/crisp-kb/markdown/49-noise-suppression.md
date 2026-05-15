The noise suppression toggle was removed in EnviousWispr 2.0.2. The app now records raw audio from your microphone and lets the speech recognition model handle background noise.

### Why We Removed It

EnviousWispr's transcription models (Parakeet and WhisperKit) are trained on real-world audio that already includes background noise. Adding the operating system's voice processing on top often hurt transcription accuracy more than it helped, by altering the audio in ways the models were not trained for. The processing also added startup latency to every recording and was the source of intermittent recording failures when toggled.

Removing it makes recordings start faster, behave more reliably, and produce more accurate transcripts in most environments.

### What If My Environment Is Very Noisy

In our testing the on-device transcription models handle typical office, cafe, and home noise without help. If you find a specific noisy setup where transcription quality drops noticeably, please report it through Help and Feedback so we can evaluate whether to add a different noise reduction approach in the future.

### What Changed In Settings

The Noise suppression toggle is no longer present in **Settings > Microphone**. If you previously had it turned on, it is automatically turned off the first time you open EnviousWispr 2.0.2.
