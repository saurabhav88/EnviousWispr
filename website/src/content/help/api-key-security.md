---
title: "API Key Security"
description: "Where your API key is stored and how to remove it."
category: "privacy-and-security"
section: "Privacy"
order: 4
keywords: ["api key", "where is my key stored", "keychain", "secret", "token", "is my key safe", "billing"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini"]
updated: 2026-08-05
---
EnviousWispr is a free dictation app for macOS. If you use OpenAI, Gemini or Claude to polish your dictation, you bring your own API key. Here is where that key is kept and how to take it back out.

### Stored in the macOS Keychain

Your key goes into the macOS Keychain, the same place the system keeps your other passwords. It is protected by your login and encrypted at rest, and no other account on the Mac can read it.

If you used an early version of EnviousWispr, your key may have started out in an older file store. The app moves it into the Keychain the next time it is used, and clears the old file afterwards.

### Where your key does and does not go

- It is never written to logs.
- It is never included in usage or crash data.
- It goes nowhere except the provider you chose, to prove the request is yours.

### Removing a key

Clear the field in **Settings** \> **AI Polish** and the stored key goes with it. You can also revoke the key from your provider's own dashboard at any time, which takes effect immediately whatever EnviousWispr does.
