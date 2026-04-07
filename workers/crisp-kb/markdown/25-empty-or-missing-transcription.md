1. **Microphone permission.** Open **System Settings > Privacy & Security > Microphone** and confirm EnviousWispr is listed and enabled.
2. **Audio input device.** In EnviousWispr settings under **Microphone**, verify your preferred input device is selected. The Auto mode uses smart device selection, but you can pick a specific mic if needed.
3. **ASR model loaded.** The speech recognition model must be downloaded and loaded before transcription can work. If the model is still downloading, the menu bar icon or overlay will indicate progress. Wait for it to complete.
4. **VAD filtering.** The Voice Activity Detection (VAD) system filters out silence. If the environment sensitivity is set too low, it may discard audio that contains speech. Try setting the environment preset to **Quiet** or increasing the sensitivity slider.
5. **Minimum audio length.** Very short recordings may be too brief for the ASR engine to produce output. The app requires at least 1 second of total audio (16000 samples) for transcription. Additionally, the VAD filter needs at least 300ms of voiced content; below that, it falls back to using the full audio.

## Still No Text?

If the recording completes but the transcript is empty, check that your microphone is not muted at the hardware level (some headsets have a physical mute switch). Also verify that audio is actually reaching the app: the menu bar icon animates with audio-reactive bars during recording, which confirms the mic input is live.