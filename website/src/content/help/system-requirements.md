---
title: "System Requirements"
description: "EnviousWispr for Mac needs Apple Silicon and macOS 14 or later, plus some disk space for its models."
category: "getting-started"
section: "Basics"
order: 2
keywords: ["requirements", "supported macs", "will it run", "intel", "apple silicon", "m1", "m2", "m3", "m4", "macos version", "sonoma", "sequoia", "compatible", "does it work on my mac", "old mac", "disk space", "how much space", "download size", "storage", "8 GB", "memory"]
updated: 2026-11-05
deflection: "can_resolve"
---
EnviousWispr is a free dictation app for macOS. It runs on any Mac with Apple Silicon (M1 or later) running macOS 14 Sonoma or later. Intel Macs are not supported. The separate [Android app](/android/) needs Android 13 or later on a 64-bit phone with at least 6 GB of memory.

### Will EnviousWispr run on my Mac?

You need three things:

- **A Mac with Apple Silicon.** That means an M1, M2, M3, M4, or newer chip. To check yours, open the Apple menu and choose About This Mac. If the chip line starts with Apple, your Mac meets this requirement.
- **macOS 14 Sonoma or later.** The same About This Mac window shows your macOS version.
- **A microphone.** The built-in microphone on your Mac works well. You can also use external microphones, AirPods, and Bluetooth headsets.

### How much disk space does EnviousWispr need?

The application file is small. During setup it downloads the speech engine you choose; Setup recommends one for your language, such as the Parakeet Ultra model, about 632 MB. If you use only Whisper, you can remove Parakeet later to free that space.

After setup, EnviousWispr can download two more small models for the [Self-Learning Dictionary](/help/self-learning-dictionary/):

- **A model that spots your corrections**, about 320 MB. EnviousWispr normally downloads it once first-run setup and your speech model have finished.
- **Envious Word Check**, about 500 MB. EnviousWispr downloads it only while **Enable Dictionary** is on and a polish choice you use has no word check of its own. That is Apple Intelligence, a cloud provider, Ollama, or no polish, for dictation or for Transcribe a File. EG-1 and S1-mini bring their own.

The optional AI polish models are extra. To free up space by removing models you no longer need, see [model downloads and management](/help/model-downloads-and-management/).

### What does AI polish need?

AI polish is an optional feature that removes filler words and corrects grammar. Dictation works without it, so these requirements only apply if you turn it on. Each polish option asks for something different:

- **Apple Intelligence** requires macOS 26 or later, running on a Mac model that supports Apple Intelligence.
- **EG-1**, the model built by Envious Labs, comes in three sizes, each a one-time download: **EG-1** is 4.7 GB (around 10.4 GB of free disk space while it installs), **EG-1 Mini** is 2.1 GB (around 4.6 GB) and **EG-1 Micro** is 805 MB (around 1.8 GB). All three run on macOS 14 or later, the same as the app. The AI Polish page marks the size that suits your Mac's memory as **Best for this Mac**; on a Mac with 8 GB of memory that is EG-1 Micro, or EG-1 Mini if you set a fixed language other than English.
- **S1-mini**, the small model made by Superwhisper, requires a one-time 484 MB download and around 1 GB of free disk space while it installs. It runs on macOS 14 or later too, is the smallest download of the built-in on-device models, and is at its best in English.
- **Ollama** running on your Mac requires enough free memory to load the model you choose. Ollama also offers models hosted on its own servers, which need an internet connection instead.
- **OpenAI, Gemini, or Claude** require an internet connection and your own API key from that provider.
