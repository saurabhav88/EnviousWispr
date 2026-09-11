---
title: "Recording Won't Stop or Seems Stuck"
description: "What to do when a recording seems to hang."
category: "troubleshooting"
section: "Recording Issues"
order: 7
keywords: ["wont stop", "stuck", "keeps recording", "frozen", "hung", "still recording", "cant stop", "spinning", "transcribing", "previous take still running", "restart"]
related: ["canceling-a-recording", "app-crashes-or-asr-engine-crashes"]
seeAlso: "mac-dictation-keeps-stopping"
updated: 2026-09-10
---
If a recording will not stop, press **Escape**. This ends any recording in progress, in every recording mode. The on-screen bar disappears, which confirms it worked.

By default Escape keeps what you said rather than throwing it away: EnviousWispr transcribes it and offers it back, and it waits in your History for 24 hours. That is a setting called [Escape Recovery](/help/escape-recovery/), on unless you switch it off. If you want the recording gone instead, click **Cancel** in the recording bar, which always discards immediately.

### Recording cannot run forever

EnviousWispr enforces a one-hour limit on a single recording. You get a warning one minute before the limit, and then EnviousWispr stops on its own and writes out the text up to that point.

### Stopping automatically when you pause

You can have EnviousWispr end a recording after a period of silence.

To turn this on, open settings, select **Transcription**, and switch on **Stop recording on silence**. The setting is off by default. The slider next to the switch sets how long the pause has to be, anywhere from half a second to three seconds.

A pause shorter than your chosen duration is ignored. At the half-second setting, an ordinary pause for thought is enough to end the recording.

### If it seems stuck after you stop talking

When the app appears unresponsive after you stop speaking, the recording has already ended. EnviousWispr is turning your speech into text and applying any polish you have chosen. That takes a moment, especially on the first dictation after opening the app. Give it a few seconds before starting a new one.

If the bar keeps spinning long after that, press **Escape**. The bar goes away and nothing is pasted. EnviousWispr stops waiting for that dictation but keeps the audio. If the engine does finish the take later, its text is dropped, because you asked to stop waiting.

If your next press of the record key shows **Previous take still running. Restart the app.**, the engine never came back from that take. Quit EnviousWispr and open it again. On the next launch it transcribes the audio it kept and saves the text to your History, the same way it [recovers a recording after a crash](/help/app-crashes-or-asr-engine-crashes/).
