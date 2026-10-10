---
title: "Choosing Your Microphone"
description: "Letting EnviousWispr follow your Mac's microphone, choosing one yourself, and handling audio that plays while you dictate."
category: "audio-and-microphone"
section: "Input Configuration"
order: 1
keywords: ["microphone", "mic", "input device", "which microphone", "headset", "usb mic", "external mic", "built in mic", "change microphone", "wrong microphone", "music", "spotify", "pause music", "lower the volume", "duck", "mute music while dictating", "other audio", "youtube", "audio interface", "focusrite", "scarlett", "virtual microphone", "wrong input", "records silence"]
related: ["bluetooth-and-airpods", "empty-or-missing-transcription"]
updated: 2026-09-29
deflection: "can_resolve"
---
EnviousWispr follows whichever microphone your Mac is set to, or uses a specific device you choose. Both choices live under **Dictation Settings** \> **Microphone**.

### Use whichever microphone my Mac is set to

**Auto** is the default and suits most setups. It records from the input your Mac is currently set to, and follows that input as devices come and go.

To change what Auto follows, set your input in **System Settings** \> **Sound**.

The **Microphone** tab shows which device Auto is using.

### Auto picked a virtual device and records silence

If your Mac's input is not a real microphone, EnviousWispr records from an available real microphone instead. Virtual devices from Krisp, Loopback, BlackHole, meeting apps and aggregate devices deliver only silence, so Auto skips them. If a virtual device is the only input on your Mac, it is still used.

### Always use one specific microphone

Choose a device and EnviousWispr uses it whatever your Mac is set to. This helps if you keep ending up on the wrong microphone. The picker then shows that device's name in place of **Auto**.

1. Click the EnviousWispr icon in the menu bar and choose **Open EnviousWispr**.
2. Click **Dictation Settings** in the sidebar, then **Microphone**.
3. Choose your microphone from the list.

You can also switch without opening the window: click the EnviousWispr icon in the menu bar, choose **Microphone**, and pick **Auto** or a microphone. It is the same choice as the list in Dictation Settings.

### My audio interface records from the wrong input

Audio interfaces such as a Focusrite Scarlett have two or more inputs, and EnviousWispr records from Input 1 unless you say otherwise. When the selected device has more than one input, a **Mic is on** control appears next to the device picker. Pick the input your microphone is plugged into. EnviousWispr remembers that choice for that device.

If your microphone is on the wrong input, a recording ends with a notice that names the device and points you to this setting. If the input numbers do not match the sockets on your device, try the next one.

- **Scarlett Solo 4th Gen:** the XLR socket is Input 2, so pick Input 2. If you have turned on "Combine inputs", Input 1 already carries your microphone and you need no change.
- **Scarlett Solo 3rd Gen:** the XLR socket is Input 1.

To record two people at once, use the mix your interface provides. This setting listens to one input. Combining devices with a macOS Aggregate Device is not recommended.

### My microphone was unplugged during a recording

EnviousWispr keeps what it recorded up to that point and transcribes it, rather than losing the entire recording.

### I use AirPods or a Bluetooth headset

If your AirPods are your Mac's input, EnviousWispr records from them, and the headset drops out of music mode while it does. Read [_Bluetooth and AirPods_](/help/bluetooth-and-airpods/) for what that changes.

### Music keeps playing while I dictate

EnviousWispr can move music, a podcast or a video out of the way when you start talking and put it back when you stop. Go to **Dictation Settings** \> **Microphone** and choose an option under **Media during dictation**, directly above **Microphone readiness**. It starts on **Continue**, which leaves your audio playing.

- **Continue.** Music and other audio keep playing as they are.
- **Lower.** Lowers what plays through your current speakers or headphones to about half for the whole take, then puts it back exactly where it was.
- **Mute.** Silences your current speakers or headphones for the whole take, then puts the volume back.
- **Pause.** Pauses whatever is playing (Spotify, Music, a YouTube tab, a podcast app), then resumes it when you stop. Only what was playing when you started is paused. Anything you start during the take keeps going.

The start and stop sounds still play. The output is lowered a moment after the start sound so it is not cut off.

### Lower or Mute is not available

Some speakers and headphones, such as a display over HDMI, do not let apps change their volume. The **Microphone** tab tells you when **Lower** or **Mute** is not available on your current output.

### My volume did not come back after dictating

- If you change the volume yourself during a take, your new level stays. EnviousWispr only puts the volume back when it is still at the level it set.
- If your Mac was already muted when you started, it stays muted.
- If you switch speakers or headphones during the take, the new output is not lowered or muted. Audio that starts mid-take is quiet only on the output selected when recording began.
- If EnviousWispr quits or crashes in the middle of a take, the volume comes back the next time the app opens.

**Lower** and **Mute** act on everything your Mac plays through that output, including a call in progress and spoken feedback from a screen reader.

### Pause did not resume my music

**Pause** resumes only what it paused, and only if that item is still paused. If you switch to another song, tab or app during a take, or press play yourself, EnviousWispr leaves things as you left them.

**Pause** reaches every player through a part of macOS that Apple has not opened up to apps. If a macOS update turns that off, EnviousWispr falls back to pausing Music and Spotify only, and the **Microphone** tab says so. On that fallback, macOS asks the first time whether EnviousWispr may control Music or Spotify. That first take is not paused, and every take after you allow it is.
