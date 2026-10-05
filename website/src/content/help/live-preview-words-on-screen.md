---
title: "Live Preview"
description: "Seeing your words on screen while you are still speaking, and what to do when nothing appears."
category: "features"
section: "Recording"
order: 6
keywords: ["live preview", "preview", "see words as i speak", "see my words", "words on screen", "on screen preview", "while i speak", "recording pill", "watch it type", "is it hearing me", "nothing appears", "no words showing", "install new languages", "preview language", "preview engine"]
updated: 2026-09-29
deflection: "can_resolve"
---
Live Preview shows a rough draft of your words in the recording pill while you are still speaking, so you can see that EnviousWispr is hearing you. It is on unless you switch it off.

The preview is only a draft. It is thrown away when the recording ends and never changes the text that gets pasted. That text comes from your main speech engine, which is more accurate. Your voice and the preview text stay on your Mac.

### I see no words while I speak

Your dictation is not affected when the preview is empty, and an empty preview never means a lost recording. Check these in order.

1. **Read the status bar.** Open **Settings** > **Live Preview**. The bar at the top says whether the preview is off, ready, waiting for a download, or unavailable for your language. That answers most cases.
2. **Check the language.** If you speak one language and the preview is set to another, the pill stays empty instead of showing wrong words. This is the most common cause. Click the language at the top of the **Live Preview** page, or change it under **Settings** > **Transcription** > **Language**.
3. **Check for a missing language.** On the Apple engine, a language your Mac does not have needs a download first. The status bar says so and offers **Browse downloads**, which opens the list with that language already searched for. Until you download it, there is nothing to show.
4. **Check Faster Transcription.** On the Universal engine, the preview pauses when [Faster Transcription](/help/live-transcription-streaming-asr/) is on with the Fast engine, or with All Languages while a language is locked, so your dictation keeps its full speed. The status bar says **Paused while Faster Transcription is on** when this is the reason. Turn Faster Transcription off to see the preview again.

### Turn Live Preview on or off

1. **Open EnviousWispr.** Click the EnviousWispr menu bar icon and select **Open EnviousWispr**.
2. **Open Live Preview.** Click **Dictation Settings** in the sidebar, then **Live Preview**.
3. **Use the switch.** It sits at the right end of the status bar at the top of the page. It has no label of its own.

On a Mac that cannot run the selected engine, you get the ordinary recording bar while you dictate, and the status bar on this page says why.

### Live Preview or Faster Transcription

These are two different settings, and they are easy to mix up.

| | Live Preview | Faster Transcription |
|---|---|---|
| What you see | Words in the recording pill | Finished text pasted after you stop |
| Where the words go | Nowhere. They are discarded when you stop | Into whatever you are typing in |
| Changes your result | No | Yes, it is the result |
| Where to find it | **Settings** > **Live Preview** | **Settings** > **Transcription** |

To watch your words appear while you talk, use Live Preview. [Faster Transcription](/help/live-transcription-streaming-asr/) does transcription work while you speak, but it still pastes the finished text after you stop.

### Apple or Universal: which preview engine

The preview needs its own small engine, separate from the one that produces your final text. You pick one under **Preview engine** on the **Live Preview** page.

- **Apple** is built into macOS, so the engine itself needs no download. It needs **macOS 26 or later**, and it only recognizes languages your Mac has installed. Other languages are a download.
- **Universal** works on **macOS 14 and later** and covers more languages. It needs one optional **217 MB** download, which only starts when you click **Download** on its card. You can remove it from the same card to get the space back.

If you are on macOS 26 and Apple supports your language, use Apple. Choose Universal on older macOS versions, or when Apple does not support your language.

### The preview shows the wrong language

Which language the preview uses depends on the engine. It only matters if your dictation language is set to **Auto-detect language**.

- **On Apple**, the preview follows the language you picked for dictation under **Transcription**. On Auto-detect it has nothing to follow, because it must commit to one language before you say your first word. It goes by your Mac's language instead. Dictation still understands whatever you speak. Only the words on screen may come out in the wrong language until you pick one.
- **On Universal**, if you picked a language for dictation, the preview uses it. If your dictation language is Auto-detect, this engine works out the language itself as you speak.

To change it, click the language at the top of the **Live Preview** page. This sets your dictation language everywhere, not only the preview. The list starts with **Auto-detect**, so you can hand the choice back to the app.

### Add a language for the Apple engine

The **Languages** section appears on the **Live Preview** page only when the Apple engine is selected on macOS 26 or later.

1. **Open the list.** Under **Languages**, click **Install new languages**. It lists the languages that are not on your Mac yet.
2. **Download the one you need.** Each language is about 140 MB. Nothing downloads until you ask.
