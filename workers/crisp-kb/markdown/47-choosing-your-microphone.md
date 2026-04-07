EnviousWispr supports two modes for audio input device selection, configurable in **Settings > Microphone**.

### Auto Mode

In Auto mode, EnviousWispr uses smart mic selection to pick the best available input device. This is the default and works well for most setups. The app handles device changes (plugging in a USB mic, connecting Bluetooth headphones) automatically.

### Manual Selection

If you prefer to lock to a specific microphone, switch to manual mode and choose your device from the list. EnviousWispr will always use that device regardless of other inputs that become available.

### Device Disconnect Recovery

If your selected microphone is disconnected during a recording (USB unplugged, Bluetooth drops), EnviousWispr detects this via CoreAudio device-alive checks and performs an emergency teardown to salvage any audio captured so far. The partial recording is transcribed rather than discarded.