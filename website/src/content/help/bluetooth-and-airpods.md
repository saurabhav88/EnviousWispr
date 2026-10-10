---
title: "Bluetooth and AirPods"
description: "What to expect when you dictate with AirPods or a Bluetooth headset, and how to fix the usual problems."
category: "audio-and-microphone"
section: "Input Configuration"
order: 2
keywords: ["airpods", "air pods", "bluetooth", "wireless headphones", "headphones", "earbuds", "sounds muffled", "quality drops", "music stops", "beats", "headset", "music sounds worse", "first word missing", "bluetooth tips", "built-in microphone instead"]
related: ["choosing-your-microphone"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
AirPods and Bluetooth headsets work with EnviousWispr. Expect two side effects: your headset's sound quality drops while the microphone is in use, and the microphone needs a moment to wake up after it has been idle.

### My music sounds worse when I dictate with AirPods

A Bluetooth headset has a music mode and a microphone mode, and it cannot do both at once. When EnviousWispr uses the microphone, the headset switches to microphone mode and the sound quality drops.

The quality stays low until EnviousWispr lets go of the microphone. With **Microphone readiness** at its default of 30 sec, that can be up to 30 seconds after you finish dictating.

To get your music back right away:

1. Go to **Dictation Settings** \> **Microphone**.
2. Set **Microphone readiness** to **Off**.

With readiness off, the first word of your next dictation is more likely to go missing. Read [_First Word Gets Cut Off_](/help/first-word-gets-cut-off/) if that happens.

You can also record from your Mac's built-in microphone. Your headset then stays in music mode the whole time. Choose the built-in microphone under **Dictation Settings** > **Microphone**.

### Use my Mac's microphone instead of my AirPods

With **Auto** selected, EnviousWispr records from whatever input your Mac is set to. If that is your AirPods, it records from your AirPods.

To use the built-in microphone instead, do either of these:

- Change the input in **System Settings** \> **Sound**.
- Choose the built-in microphone in **Dictation Settings** \> **Microphone** in EnviousWispr.

Read [_Choosing Your Microphone_](/help/choosing-your-microphone/) for more on how the choice works.

### The first word is missing with my Bluetooth headset

After the microphone has been idle, a Bluetooth headset takes a moment to switch into microphone mode. If you speak straight away, the start of your sentence can be lost. This can happen after any idle stretch, not only the first recording after you connect.

Wait 1 to 2 seconds after pressing your keybind before you start talking. In push to talk mode, keep the key held during that pause. In toggle mode, press the key once and wait.

Keeping **Microphone readiness** on its default of 30 sec (or setting it to 60 sec or **Always**) also keeps follow-up dictations ready. A built-in or wired microphone usually avoids the delay completely.

### Turn off the Bluetooth tips

When a Bluetooth microphone is your input, EnviousWispr shows a short reminder of these tips once per launch. To stop it:

1. Go to **Dictation Settings** \> **Microphone**.
2. Under **Using a Bluetooth microphone?**, click **Learn more**.
3. Switch off **Show Bluetooth tips**.

The guide itself stays on the **Microphone** tab.

### My headset disconnected during a recording

EnviousWispr keeps and transcribes whatever it had recorded before the disconnect, rather than throwing the whole recording away.

### Dictation is less accurate on my headset

Bluetooth microphones are lower quality than your Mac's built-in one. For long or important dictations, the built-in microphone is usually the better choice.
