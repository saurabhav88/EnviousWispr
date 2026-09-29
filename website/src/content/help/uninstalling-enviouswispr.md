---
title: "Uninstalling EnviousWispr"
description: "How to remove EnviousWispr and the files it leaves behind, or keep them for a later reinstall."
category: "getting-started"
section: "Basics"
order: 6
keywords: ["uninstall", "remove", "delete", "get rid of it", "clean up", "free up space", "leftover files", "models taking up space", "delete EnviousWispr", "remove models", "reinstall", "start fresh", "Trash"]
related: ["model-downloads-and-management"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
Removing EnviousWispr takes two parts: deleting the application, and deleting the support files it saved on your Mac. Deleting the application alone leaves your history, custom words, snippets, and downloaded models in place.

### Remove the app

1. **Quit the application.** Click the EnviousWispr icon in your menu bar and choose **Quit**. This stops macOS holding the program files open.
2. **Move it to the Trash.** Open your Applications folder in Finder and drag EnviousWispr to the Trash.

### Delete your data, models and settings

The support files can add up to a few gigabytes. To clear them:

1. **Open the Go to Folder box.** In Finder, press **Shift+Cmd+G**.
2. **Delete the support folder.** Paste `~/Library/Application Support/EnviousWispr` into the box, press Enter, and move that folder to the Trash. It holds your dictation history, your custom words, your snippets, and every model EnviousWispr downloaded: Parakeet, WhisperKit, EG-1, S1-mini, and the word-check models. Any recording that Escape Recovery was still holding for you sits in there too, and goes with it.
3. **Delete the preferences file.** Press **Shift+Cmd+G** again, paste `~/Library/Preferences`, press Enter, and move `com.enviouswispr.app.plist` to the Trash. That file stores your settings.

### Remove an older Parakeet copy

Current versions keep Parakeet inside `~/Library/Application Support/EnviousWispr`, so deleting that folder removes it. If you installed Parakeet with an older version, a copy may also sit in a folder that other apps can share.

1. **Open the shared model folder.** Press **Shift+Cmd+G** in Finder and go to `~/Library/Application Support/FluidAudio/Models`.
2. **Delete only the Parakeet folder.** Move only the `parakeet-tdt-0.6b-v3` folder to the Trash. Anything else in that folder may belong to a different application, which would then have to download its files again. If another app on your Mac uses Parakeet, leave this folder alone.

### Remove Ollama models

If you installed Ollama for text polish, those models belong to Ollama and are removed from there.

### Remove your API key

If you added a personal key for OpenAI, Gemini, or Claude, it lives in your macOS Keychain rather than in the support folders.

If you cleared the field in EnviousWispr settings before uninstalling, the key is already gone. If the app is already deleted, open the macOS Keychain Access application, search for EnviousWispr, and delete every entry you find. There can be one entry for each provider.

Revoking the key in that company's own dashboard is worth doing either way.

### Keep your data if you might reinstall

If you plan to reinstall later, leave the support files in place. Reinstalling brings your history, custom words, snippets, models, and settings back on its own. Delete them first if you want to start fresh.

Once you move those files to the Trash and empty it, they are gone for good. Envious Labs cannot restore them, because we never had a copy.
