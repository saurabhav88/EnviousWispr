---
title: "AI Polish on Android"
description: "Choose where AI polish runs on Android (Off, This phone or Cloud), add your own cloud key, and set S1-mini's tone, structure and context."
category: "android"
section: "Using EnviousWispr on Android"
order: 6
keywords: ["android ai polish", "s1-mini", "polish on this phone", "cloud polish android", "openai key android", "gemini key android", "claude key android", "tone structure context", "writing style android"]
related: ["android-phone-requirements", "android-privacy", "android-model-downloads"]
updated: 2026-10-28
deflection: "never_intervene"
---
AI polish turns what you said into clear writing after speech recognition finishes. On Android you choose where it runs in the **AI Polish** tab, under **1 · WHERE POLISH RUNS**.

### Choose where polish runs

| Option | What happens | Internet needed |
|---|---|---|
| **Off** | No language model runs. Cleanup still removes obvious filler and spacing issues. | No |
| **This phone** | S1-mini polishes your words on the phone. | No, after the download |
| **Cloud** | Your chosen provider polishes your words under your own key. | Yes |

### Polish on this phone with S1-mini

**Download S1-mini.** It downloads during setup (484.2 MB). If it is missing, the AI Polish tab shows **Download S1-mini to polish on this phone.**

S1-mini works offline. On some mid-range phones, setup and the AI Polish tab note that dictation and on-device AI polish may be slow; it still works, it just takes a few seconds longer. If S1-mini is not working, your words come back with basic cleanup only.

### Polish in the cloud with your own key

1. **Pick a provider.** Tap **Cloud**, then choose **OpenAI**, **Gemini** or **Claude**.
2. **Add your key.** Paste your API key and tap **Check**. The tab links to the page where you can get a key. Your key is encrypted in the Android Keystore and never written to logs.
3. **Pick a model.** Under **4 · MODEL**, choose a model from the list.

With cloud polish on, the selected text and your custom words go directly to that provider. Your audio stays on your phone either way. The provider's charges and terms apply.

### Set S1-mini's writing style

Under **WRITING STYLE**, three settings shape S1-mini's output. A new pick applies to your next dictation.

| Setting | Options | What it changes |
|---|---|---|
| **Tone** | Casual, Semi-casual, Semi-formal, Formal | Semi-formal keeps capitals and full stops. Casual and semi-casual write the way you would text. |
| **Structure** | Prose, Lists | Lists turns a spoken run of items into bullet points. Prose keeps everything as sentences. |
| **Context** | General, Email | Email lays out a greeting line and a sign-off block when you dictate them. It changes nothing else. |
