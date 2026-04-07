When a Bluetooth headset (like AirPods) is used for audio output, macOS switches the codec from A2DP (high-quality playback) to SCO (lower-quality bidirectional) when an app requests microphone input. This codec switch causes a brief audio disruption and can degrade recording quality.

## Automatic BT-Aware Routing

EnviousWispr has built-in Bluetooth-aware audio routing via the **Bluetooth-aware audio router**. When it detects that a Bluetooth device is active for audio output:

* It automatically routes audio capture to your Mac's **built-in microphone** instead of the Bluetooth device.
* This avoids the A2DP-to-SCO codec switch entirely.
* Your Bluetooth headset continues playing audio without interruption.

## Pre-Warm on Push-to-Talk

When using Push-to-Talk mode, pressing the hotkey triggers a pre-warm phase that resolves the audio route and settles any codec switching before capture begins. This happens in parallel with other setup tasks.

## Device Disconnect During Recording

If a Bluetooth device disconnects during recording, EnviousWispr detects this via CoreAudio device property monitoring. If the device is still alive (codec switch), it recovers gracefully in place. If the device is gone (disconnect), it performs an emergency teardown and salvages any audio captured so far.