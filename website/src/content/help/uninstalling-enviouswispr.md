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
EnviousWispr is a free dictation app for macOS. Removing it has two parts: deleting the app, and deleting the files it saved on your Mac.

### Remove the app

1. Click the EnviousWispr icon in your menu bar and choose **Quit**.
2. Open your Applications folder and drag EnviousWispr to the Trash.

The app is now gone. Your history, custom words and downloaded speech models are still on the Mac.

### Remove your data and settings

Those files can add up to a few gigabytes.

1. In Finder, press **Shift+Cmd+G** to open the Go to Folder box.
2. Go to `~/Library/Application Support/EnviousWispr` and move that folder to the Trash. It holds your dictation history, your custom words, and the WhisperKit and EG-1 models.
3. Go to `~/Library/Preferences` and move `com.enviouswispr.app.plist` to the Trash. That file is your settings.

### The Parakeet model sits somewhere else

Parakeet is one of the two speech engines. It lives in a folder shared with other apps, so the step above does not remove it. Go to `~/Library/Application Support/FluidAudio/Models` and move `parakeet-tdt-0.6b-v3` to the Trash.

Move only that one folder. Anything else in there may belong to a different app, which would then have to download it again.

If you installed Ollama, its models belong to Ollama and are removed from there.

### Your API key

If you added a key for OpenAI, Gemini or Claude, it lives in your macOS Keychain rather than in any of the folders above. Clearing the field in EnviousWispr's settings before you uninstall removes it. If the app is already gone, open Keychain Access, search for EnviousWispr, and delete every entry you find. There can be one for each provider.

Revoking the key in that company's own dashboard is worth doing either way.

### If you come back

Leave those files in place and reinstalling brings your History, custom words, models and settings back. Delete them first and you start fresh.

Once you delete them they are gone. Envious Labs cannot restore them, because we never had a copy.
