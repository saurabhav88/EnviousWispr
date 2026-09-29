---
title: "Recording Won't Stop or Seems Stuck"
description: "How to stop a recording that will not end, and what to do when EnviousWispr seems frozen after you stop talking."
category: "troubleshooting"
section: "Recording Issues"
order: 7
keywords: ["wont stop", "stuck", "keeps recording", "frozen", "hung", "still recording", "cant stop", "spinning", "transcribing", "previous take still running", "restart", "a take is stuck", "restart the app", "stuck on transcribing", "recording bar wont go away"]
related: ["canceling-a-recording", "app-crashes-or-asr-engine-crashes"]
seeAlso: "mac-dictation-keeps-stopping"
updated: 2026-09-29
deflection: "show_but_always_send"
---
If a recording will not stop, press **Escape**. This ends any recording in progress, in every recording mode. The recording bar disappears, which confirms it worked.

### Stop a recording now

Press **Escape**. By default, Escape keeps what you said instead of throwing it away. EnviousWispr transcribes it and offers it back, and it waits in your History for 24 hours. That is a setting called [Escape Recovery](/help/escape-recovery/), on unless you switch it off.

To discard the recording instead, click **Cancel** in the main EnviousWispr window, next to **Stop** under the recording timer. It always discards immediately. The floating recording bar has no Cancel button.

### The recording stopped by itself after a long time

A single recording can last up to one hour. You get a warning one minute before the limit. Then EnviousWispr stops on its own and writes out the text up to that point.

### Stop recording automatically when I pause

You can have EnviousWispr end a recording after a period of silence.

1. Click the EnviousWispr icon in your menu bar and choose **Settings**.
2. Open **Transcription**.
3. Switch on **Stop recording on silence**. It is off by default.
4. Use the slider next to the switch to set how long the pause has to be, from half a second to three seconds.

A pause shorter than your chosen length is ignored. At the half-second setting, an ordinary pause for thought is enough to end the recording.

### Nothing seems to happen after I stop talking

If the bar still shows it is recording, the recording has not ended: finish it with your recording keybind, or turn on **Stop recording on silence**. If the bar shows **Transcribing**, the recording has ended and EnviousWispr is turning your speech into text and applying any polish you chose. That takes a moment, especially on the first dictation after opening the app. Give it a few seconds before you start a new one.

### The bar stays on Transcribing

If the recording bar stays on **Transcribing** long after a few seconds, press **Escape**. The bar goes away and nothing is pasted. EnviousWispr stops waiting for that dictation. If the speech engine finishes later, its text is dropped, because you asked to stop waiting. Escape does not interrupt AI polish. Polish has its own time limit and finishes on its own.

### I see "A take is stuck. Restart the app."

This notice can appear when you press your recording keybind again. It means an earlier recording is still holding the speech engine and never finished. Quit EnviousWispr and open it again, then dictate again. After the restart, EnviousWispr tries to recover the stuck recording and puts any text it recovers in History. Check History before you say it again.

If the app closes on its own instead, see [what happens after a crash](/help/app-crashes-or-asr-engine-crashes/).
