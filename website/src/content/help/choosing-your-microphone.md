---
title: "Choosing Your Microphone"
description: "Letting EnviousWispr follow your Mac, or choosing a microphone yourself."
category: "audio-and-microphone"
section: "Input Configuration"
order: 1
keywords: ["microphone", "mic", "input device", "which microphone", "headset", "usb mic", "external mic", "built in mic", "change microphone", "wrong microphone"]
related: ["bluetooth-and-airpods", "empty-or-missing-transcription"]
updated: 2026-09-05
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
