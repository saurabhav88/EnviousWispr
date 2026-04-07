Press the **Escape** key at any time during recording to cancel and discard the current recording. This works regardless of the recording mode (Push-to-Talk, Toggle, or Hands-Free).

## Maximum Recording Duration

EnviousWispr enforces two safety limits:

* **Soft limit (5 minutes):** The app gracefully stops recording and proceeds to transcription.
* **Hard limit (10 minutes):** An emergency cutoff that ensures the app never records indefinitely.

## Process Isolation

Audio capture and ASR inference run in separate background processes, isolated from the main app. If one of these processes hangs or crashes, it does not take down the main app. The app detects the interruption, transitions to an error state, and the next recording automatically re-launches the service.

## VAD Auto-Stop

If VAD auto-stop is enabled (the default), recording ends automatically when sustained silence is detected. The silence timeout is configurable via the environment sensitivity settings. If the VAD detects extended silence, it transitions through a hangover period before stopping, which prevents premature cutoff during natural speech pauses.