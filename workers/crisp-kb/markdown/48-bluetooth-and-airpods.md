Bluetooth audio devices require special handling because of codec switching. When a Bluetooth device (like AirPods) switches from the high-quality playback codec (A2DP) to the bidirectional voice codec (SCO/HFP), there is a brief audio disruption. EnviousWispr has Bluetooth-aware routing to handle this gracefully.

### Pre-warm on PTT Key-Down

When you press the push-to-talk key, EnviousWispr immediately fires a pre-warm call that triggers the Bluetooth codec switch. The actual recording start waits for format stabilization (up to 1.5 seconds, polling every 200ms) so the codec switch has time to settle before audio capture begins.

### Warm Engine Between Recordings

After a recording ends, the audio engine stays running (in pre-roll mode) for a configurable timeout. This means the Bluetooth codec stays in voice mode, and your next recording starts instantly without waiting for a codec switch. The warm engine timeout is configurable in Settings under Microphone (options: Off, 10s, 30s, 60s, Always; default is 30s).

### Route Change Detection

If a Bluetooth device connects or disconnects between recordings while the engine is warm, EnviousWispr detects the route change, rebuilds the audio source, and starts fresh with the correct device.