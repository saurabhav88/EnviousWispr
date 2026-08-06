---
title: "Uninstalling EnviousWispr"
description: "Removing EnviousWispr, and the files it leaves behind."
category: "getting-started"
section: "Basics"
order: 6
keywords: ["uninstall", "remove", "delete", "get rid of it", "clean up", "free up space", "leftover files", "models taking up space"]
related: ["model-downloads-and-management"]
updated: 2026-08-06
---
Removing the app involves two parts: deleting the application itself, and deleting the support files it saved on your Mac.

### Remove the app

Quit the application first, so macOS is not holding the program files open when you send them to the Trash.

**Quit the application.** Click the EnviousWispr icon in your menu bar and choose **Quit**.

**Move it to the Trash.** Open your Applications folder in Finder and drag EnviousWispr to the Trash.

The application is now gone, but your dictation history, custom words, and downloaded speech models remain on the Mac.

### Remove your data and settings

Those remaining files can add up to a few gigabytes of storage. Follow these steps to clear them.

**Open the Go to Folder box.** In Finder, press **Shift+Cmd+G** on your keyboard.

**Delete the application support folder.** Paste `~/Library/Application Support/EnviousWispr` into the box, press Enter, and move that folder to the Trash. It holds your dictation history, your custom words, and the WhisperKit and EG-1 models.

**Delete the preferences file.** Press **Shift+Cmd+G** again, paste `~/Library/Preferences`, press Enter, and move `com.enviouswispr.app.plist` to the Trash. That file stores your settings.

### Remove the Parakeet model

Parakeet is one of the two speech engines the app can use. It lives in a folder shared with other applications, so the steps above do not remove it.

**Open the shared model folder.** Press **Shift+Cmd+G** in Finder and go to `~/Library/Application Support/FluidAudio/Models`.

**Delete the Parakeet folder.** Move only the `parakeet-tdt-0.6b-v3` folder to the Trash. Anything else in that folder may belong to a different application, which would then have to download its files again.

If you installed Ollama for text polish, those models belong to Ollama and are removed from there.

### Remove your API key

If you added a personal key for OpenAI, Gemini, or Claude, it lives in your macOS Keychain rather than in the support folders above.

If you cleared the field in EnviousWispr settings before uninstalling, the key is already gone. If the app is already deleted, open the macOS Keychain Access application, search for EnviousWispr, and delete every entry you find. There can be one entry for each provider.

Revoking the key in that company's own dashboard is worth doing either way.

### If you come back

If you plan to reinstall later, leave those support files in place. Reinstalling brings your history, custom words, models, and settings back on its own. Delete them first if you want to start fresh.

Once you move those files to the Trash and empty it, they are gone for good. Envious Labs cannot restore them, because we never had a copy.
