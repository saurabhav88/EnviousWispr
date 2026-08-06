---
title: "Apple Intelligence Not Available"
description: "Why Apple Intelligence polish may be unavailable on your Mac."
category: "troubleshooting"
section: "AI Polish Issues"
order: 6
keywords: ["apple intelligence missing", "apple intelligence greyed out", "cant use apple intelligence", "not available", "unavailable", "why cant i pick apple"]
related: ["apple-intelligence-setup", "system-requirements"]
updated: 2026-08-06
---
Apple Intelligence is one of the polish options EnviousWispr can use to tidy up your dictation, but Apple restricts the feature to specific hardware and software versions. Dictation itself keeps working normally even when Apple Intelligence is unavailable on your Mac.

To see which requirement is missing, open EnviousWispr settings, go to **AI Polish**, and select Apple Intelligence. EnviousWispr names the exact reason the option is unavailable on your system.

### Common reasons it is unavailable

Work through this list to identify why Apple Intelligence is not active in EnviousWispr.

- **macOS is too old.** This feature requires macOS 26 or later. Check your version under the Apple menu by selecting **About This Mac**. This requirement is separate from the Apple Intelligence features introduced in macOS 15, because other applications could not reach the system model until macOS 26.
- **Apple Intelligence is switched off.** Open **System Settings**, go to **Apple Intelligence & Siri**, and turn the feature on.
- **The model is still downloading.** macOS downloads the required model files in the background after you turn the feature on, and that can take a while. Try the option again later.
- **Your Mac does not support the feature.** Apple decides which Macs qualify, and there is no way around that from inside EnviousWispr.

### Alternative polish options

If Apple Intelligence is out of reach on your Mac, you can choose a different way to clean up your dictated text. Pick EG-1 or a downloaded Ollama model to keep everything on your Mac, or enter your own API key for OpenAI, Gemini, or Claude.
