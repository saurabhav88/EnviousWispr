Hands-Free mode is an extension of Push-to-Talk that lets you dictate without holding a key. It is designed for longer recordings where holding a key is impractical.

### How to activate

1. Start a Push-to-Talk recording by pressing and holding your hotkey.
2. **Double-press** the hotkey (press again quickly while holding). The recording locks into hands-free mode.
3. Release the key. Recording continues.

### Visual feedback

When hands-free mode activates, the floating recording overlay expands to visually confirm that recording is locked.

### How to stop

* **Press the hotkey once** to stop recording and transcribe.
* **Triple-press the hotkey** to cancel the recording entirely (discards audio).
* The **Escape** key also cancels the recording.

### Auto-stop

EnviousWispr uses voice activity detection (VAD) to automatically stop recording after a configurable period of silence. There is also a hard maximum recording duration of 5 minutes (graceful stop) and 10 minutes (hard cap).

### Environment presets

The VAD sensitivity can be tuned via environment presets (Quiet, Normal, Noisy) in the **Microphone** tab of settings. These adjust the onset and offset thresholds so auto-stop works reliably in different environments.