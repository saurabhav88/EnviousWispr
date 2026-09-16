---
title: "Choosing Your Microphone"
description: "Letting EnviousWispr follow your Mac, or choosing a microphone yourself."
category: "audio-and-microphone"
section: "Input Configuration"
order: 1
keywords: ["microphone", "mic", "input device", "which microphone", "headset", "usb mic", "external mic", "built in mic", "change microphone", "wrong microphone", "music", "spotify", "pause music", "lower the volume", "duck", "mute music while dictating", "other audio", "youtube"]
related: ["bluetooth-and-airpods", "empty-or-missing-transcription"]
updated: 2026-09-16
---
EnviousWispr can follow whichever microphone your Mac is set to, or use a specific device you name yourself. Both choices live under **Settings** \> **Microphone**.

### Auto

Auto records from whatever input your Mac is currently set to, and follows that input as devices come and go. This is the default, and it suits most setups.

To change what Auto follows, set your input in **System Settings** \> **Sound**.

There is one exception. If the input your Mac is set to turns out not to be a real microphone, such as a virtual device installed by Krisp, Loopback, BlackHole, an aggregate device or a meeting app, EnviousWispr records from an available real microphone instead, because a virtual device delivers nothing but silence. If a virtual device is the only input on your Mac, it is still used. The **Microphone** page shows which device Auto is using.

### Choosing a specific microphone

Pick a device from the list and EnviousWispr always uses that one, whatever your Mac is set to. This is worth doing if you keep ending up on the wrong microphone. The picker then shows that device's name in place of Auto.

To select a specific device:

**Open settings.** Click the EnviousWispr icon in the menu bar and select **Settings**, or press Cmd+,.

**Go to the Microphone tab.** Click **Microphone** in the settings sidebar.

**Select your device.** Choose your microphone from the list.

### If your microphone box has more than one input

Audio interfaces such as a Focusrite Scarlett have two or more inputs, and EnviousWispr records from one of them. It uses Input 1 unless you tell it otherwise. When the selected device reports more than one input, a **Mic is on** control appears next to the device picker. Pick the input your microphone is plugged into, and EnviousWispr remembers that choice for that box.

If your microphone is on the wrong input, a recording ends with a notice that names the device and points you to this setting. If the input numbers do not match the sockets on your device, try the next one.

**Scarlett Solo 4th Gen:** the XLR microphone socket is Input 2, so pick Input 2. If you have enabled "Combine inputs", Input 1 already carries your microphone and no change is needed. On Scarlett Solo 3rd Gen, the XLR microphone socket is Input 1.

**Two microphones at once:** this setting listens to one input. To record two people through one interface, use the mix your interface itself provides. Combining devices with a macOS Aggregate Device is not recommended.

### If your microphone is unplugged mid-recording

EnviousWispr keeps what it recorded up to that point and transcribes it, rather than losing the entire recording.

### A note on headsets

If your AirPods are your Mac's input, EnviousWispr records from them, and your headset drops out of music mode while it does. Read [_Bluetooth and AirPods_](/help/bluetooth-and-airpods/) for what that changes.

### Other audio while you dictate

If you dictate with music, a podcast or a video playing, EnviousWispr can get that sound out of the way when you start talking and put it back when you stop. Go to **Settings**, then **Microphone**, and pick one of four choices under **Other Audio While You Dictate**, just above Microphone Readiness. The setting is off from the start, so nothing changes until you choose.

- **Nothing.** Music and other audio keep playing as they are.
- **Turn down.** Lowers what plays through your current speakers or headphones to about half for the whole take, then puts it back to exactly where it was.
- **Mute.** Silences your current speakers or headphones for the whole take, then puts the volume back.
- **Pause music.** Pauses whatever is playing (Spotify, Music, a YouTube tab, a podcast app), then resumes it when you stop. Only what was playing when you started is paused; anything you start during the take keeps going.

A few things worth knowing:

- Turn down and Mute act on everything your Mac plays through that output, including a call in progress and spoken feedback from a screen reader.
- Audio that starts mid-take is quiet on the output selected when recording began. If you switch speakers or headphones during the take, the new output is not lowered or muted.
- If you change the volume yourself during a take, your new level stays. EnviousWispr only puts the volume back when it is still at the level it set.
- If your Mac was already muted when you started, it stays muted.
- Pause music resumes only what it paused, and only if it is still the paused item. If you switch to another song, tab or app during a take, or press play yourself, EnviousWispr leaves things as you left them rather than starting something you did not have playing.
- Pause music reaches every player through a part of macOS that Apple has not opened up to apps. If a macOS update turns that off, EnviousWispr falls back to pausing Music and Spotify only, and the Microphone page says so. On that fallback, macOS asks the first time whether EnviousWispr may control Music or Spotify; that first take is not paused, and every take after you allow it is.
- If EnviousWispr quits or crashes in the middle of a take, the volume comes back the next time the app opens.
- Some speakers and headphones, such as a display over HDMI, do not let apps change their volume. The Microphone page tells you when Turn down or Mute is not available on your current output.
- The start and stop sounds still play. The output is lowered a moment after the start sound so it is not cut off.
