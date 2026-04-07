EnviousWispr offers Apple Voice Processing noise suppression to produce cleaner audio input, especially useful in noisy environments.

### How It Works

When enabled, the AVAudioEngine is configured with Apple's Voice Processing I/O audio unit, which applies noise suppression at the system level before audio reaches the speech recognition model.

### Configuration

Noise suppression can be toggled in **Settings > Microphone**.

### Bluetooth Limitation

Noise suppression is unavailable when Bluetooth audio output is active (e.g., AirPods). When Bluetooth output is detected, EnviousWispr routes audio capture through a different path that does not support Voice Processing. This is a system-level constraint, not a bug. If you need noise suppression, use your Mac's built-in speakers for output or a wired headset.

### Default State

Noise suppression is off by default.

### Important Note

Changing the noise suppression setting requires rebuilding the audio engine internally. EnviousWispr handles this automatically, but the change takes effect on the next recording, not mid-recording.

### Troubleshooting

* **Noise suppression has no effect with Bluetooth headphones:** This is expected. Noise suppression requires the standard audio engine path, which is not used when Bluetooth output is active. See the Bluetooth and AirPods article for details.
* **Toggle does not seem to change anything:** The change applies on your next recording, not the current one.