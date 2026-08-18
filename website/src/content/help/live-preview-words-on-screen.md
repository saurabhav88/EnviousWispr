---
title: "Live Preview"
description: "Seeing your words on screen while you are still speaking."
category: "features"
section: "Recording"
order: 6
keywords: ["live preview", "preview", "see words as i speak", "see my words", "words on screen", "on screen preview", "while i speak", "recording pill", "watch it type", "is it hearing me", "nothing appears", "no words showing"]
updated: 2026-08-18
---
Live Preview shows your words in the recording pill while you are still speaking, so you can see that EnviousWispr is hearing you. It is off unless you turn it on.

**It is only a preview.** The words in the pill are a rough draft from a second, lighter engine. They are thrown away when the recording ends, and they never change a character of the text that gets pasted. That text comes from the main engine, which is more accurate.

Your voice and preview text stay on your Mac.

### Turning it on

**Open settings.** Click the EnviousWispr menu bar icon and select **Settings**, or press Cmd+,.

**Go to Live Preview.** Under **Record**, click **Live Preview**.

**Switch on Show words while I speak.** The card at the top of the page tells you whether the preview is ready, and if it is not, what is missing.

### Live Preview is not Live transcription

These are two different settings and it is easy to mix them up.

| | Live Preview | Live transcription |
|---|---|---|
| What you see | Words in the recording pill, on screen | Text written into your document |
| Where it goes | Nowhere. It is discarded when you stop | Straight into whatever you are typing in |
| Changes your result | No | Yes, it is the result |
| Where to find it | Settings, Record, Live Preview | Settings, Transcription |

If you want to watch your words appear as you talk without anything being written yet, you want Live Preview. If you want text landing in your document before you finish speaking, you want [Live transcription](/help/live-transcription-streaming-asr/).

### Choosing an engine

The preview needs its own small engine, separate from the one that produces your final text. There are two, and you pick one on the same settings page.

**Apple** is built into macOS. There is nothing extra to download for the engine itself. It needs **macOS 26 or later**, and it only recognises languages your Mac has installed. Most Macs arrive with a handful. Any others are a download, and you can add them from the language list further down the same page.

**Universal** works on **macOS 14 and later** and covers more languages. It needs one optional **217 MB** download, which only starts when you ask for it. You can remove it again later from the same card to get the space back.

If you are on macOS 26 and Apple supports your language, use Apple immediately if its pack is installed, or download that pack from the list below. Choose Universal on older macOS versions, or when Apple does not support your language.

### Which language the preview uses

This works differently on the two engines, and the difference only matters if your dictation language is set to **Auto**.

**On Apple**, the preview follows the language you picked for dictation, under **Transcription**. On **Auto** it has nothing to follow yet, because it must commit to one language before you say your first word, so it goes by your Mac's language instead. Dictation still understands whatever you actually speak. Only the words on screen may come out in the wrong language until you pick one. You can change the language from the Live Preview page using the **Change** button beside it, which sets your dictation language everywhere, not just the preview.

**On Universal**, it depends on the same setting. If you have picked a language for dictation, the preview uses that one. If your dictation language is **Auto**, this engine works out the language itself as you speak, so Auto is not a problem for it. Either way the **Change** button is there if the language is wrong.

The list of downloadable languages further down is Apple's, so it only appears with the Apple engine selected. The language row and the **Change** button appear for both engines whenever Live Preview is switched on.

### If you see no words at all

Work down this list.

**Check the card at the top of the settings page.** It says whether the preview is off, ready, waiting for a download, or unavailable for your language. That answers most cases on its own.

**Check the language.** If you are speaking one language and the preview is set to another, the pill stays empty rather than showing wrong words. This is the most common cause. Pick your language under **Transcription**, or with the **Change** button on the Live Preview page.

**Check whether the language is downloaded.** On the Apple engine, a language your Mac does not have shows a **Download** button in the language list. Until you download it, there is nothing to show.

**Check that Live transcription is off.** On the Universal engine, the preview steps aside while Live transcription is running, so your main dictation keeps its full speed. The status card says so when this is why.

Your dictation is unaffected in every one of these cases. An empty preview never means a lost recording.
