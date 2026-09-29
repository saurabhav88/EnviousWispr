---
title: "API Key Security"
description: "Where EnviousWispr keeps your API key, who can read it, and how to remove it."
category: "privacy-and-security"
section: "Privacy"
order: 4
keywords: ["api key", "where is my key stored", "keychain", "secret", "token", "is my key safe", "billing", "remove api key", "delete api key", "revoke key", "clear key"]
related: ["choosing-an-ai-provider-none-apple-intelligence-ollama-openai-gemini"]
updated: 2026-09-29
deflection: "can_resolve"
---
An API key is a private password that lets EnviousWispr use your own account with OpenAI, Gemini or Claude to polish your dictation. This page covers where that key is kept and how to take it back out. The on-device options, EG-1, Apple Intelligence and S1-mini, need no key at all.

### Where is my API key stored?

Your key goes into the macOS Keychain, the same place the system keeps your other passwords. It is protected by your login and encrypted at rest, and no other user account on the Mac can read it.

If you used an early version of EnviousWispr, your key may have started out in an older file store. The app moves the key into the Keychain the next time it is used, and clears the old file afterwards.

### Does my API key leave my Mac?

Your key goes nowhere except the provider you chose, where it proves the request is yours.

- It is never written to logs.
- It is never included in usage or crash data.

### How do I remove my API key?

1. Open **Settings** > **AI Polish**.
2. Choose your provider.
3. Click **Clear** beside the key field. The stored key goes with it.

### How do I revoke my API key?

You can revoke the key from your provider's own dashboard at any time. That takes effect immediately, whatever EnviousWispr does.
