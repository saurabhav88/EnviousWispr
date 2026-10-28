---
title: "Model Downloads and Updates on Android"
description: "How EnviousWispr downloads its speech and polish models on Android, why it waits for Wi-Fi, and how model updates work."
category: "android"
section: "Using EnviousWispr on Android"
order: 8
keywords: ["waiting for wi-fi", "model download android", "use mobile data", "download stuck", "new speech model available", "model update android", "a model is updating", "download failed android"]
related: ["android-setup", "android-phone-requirements", "android-ai-polish"]
updated: 2026-10-28
deflection: "never_intervene"
---
EnviousWispr for Android runs two models on your phone: Parakeet Ultra for speech recognition (667.8 MB) and S1-mini for AI polish (484.2 MB). They download once, and after that dictation works offline.

### Why the download says Waiting for Wi-Fi

Model downloads wait for Wi-Fi unless you allow mobile data, so a large download does not use your data plan by surprise. Downloads also wait while your phone is low on storage.

**Download on mobile data.** During setup, tap **Use mobile data**. To change it later, open Settings, then **Storage** > **Downloads**, and turn on **Download models on mobile data**.

### Pause, resume or retry

While a model downloads, a notification shows **Downloading** with **Pause** and **Cancel**, and **Resume** once paused. In the app, the model's card offers **Pause**, **Resume** or **Retry**. A model shows **Ready** when it is installed and checked.

### When a model update arrives

When downloads are set to Wi-Fi only, a new model is waiting, and you open the app off Wi-Fi, EnviousWispr asks: **New speech model available** or **New polish model available**, with its size. If you close the question without answering, it asks again next time.

| Choice | What happens |
|---|---|
| **Download now** | Downloads this update on mobile data. Your setting does not change. |
| **Wait for Wi-Fi** | Waits until you are on Wi-Fi. |

If your current model is working, dictation keeps using it until the update finishes. While the files are swapped, a dictation you start may show **A model is updating. Try again in a moment.**
