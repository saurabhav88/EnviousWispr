---
title: "Uninstalling EnviousWispr"
description: "Removing EnviousWispr, and the files it leaves behind."
category: "getting-started"
section: "Basics"
order: 6
keywords: ["uninstall", "remove", "delete", "get rid of it", "clean up", "free up space", "leftover files", "models taking up space"]
related: ["model-downloads-and-management"]
updated: 2026-08-05
---
Quit EnviousWispr from the menu bar, then drag it from your Applications folder to the Trash. That removes the app.

### Removing your data and settings

Your dictation history, custom words and downloaded models stay behind unless you remove them. Together they can be a few gigabytes.

1. In Finder, press **Shift+Cmd+G**.
2. Go to `~/Library/Application Support/EnviousWispr` and move that folder to the Trash. That is your History, your custom words, and the WhisperKit and EG-1 models.
3. Go to `~/Library/Preferences` and move `com.enviouswispr.app.plist` to the Trash. That is your settings.

### The Parakeet model is kept somewhere else

It sits in a shared folder, so the step above does not remove it. Go to `~/Library/Application Support/FluidAudio/Models` and move `parakeet-tdt-0.6b-v3` to the Trash.

Move only that one folder. Anything else in there may belong to another app, which would have to download it again.

If you installed Ollama, its models belong to Ollama and are removed from there.

### Your API key

If you added a key for OpenAI, Gemini or Claude, it lives in your macOS Keychain. Clearing the field in Settings before you uninstall removes it. If the app is already gone, open Keychain Access, search for EnviousWispr, and delete every entry you find. There can be one per provider.

Revoking the key in that company's dashboard is worth doing either way.

### If you come back

Leave those files in place and reinstalling brings your History, custom words, models and settings back. Delete them first and you start fresh.

Once you delete them they are gone. We cannot restore them, because we never had a copy.
