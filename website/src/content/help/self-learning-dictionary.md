---
title: "Self-Learning Dictionary"
description: "When you fix a misheard word in text EnviousWispr pasted a moment ago, the right spelling joins your dictionary on its own, with two seconds to undo. Which apps it works in, how the on-device judge decides, and what stays on your Mac."
category: "custom-words"
section: "Dictionary"
order: 5
keywords: ["self-learning dictionary", "learn from my edits", "learn from edits", "undo", "auto-learned", "correction", "misheard word", "custom words", "on-device", "local classifier", "privacy", "which apps"]
related: ["adding-custom-words", "how-custom-word-correction-works", "adding-a-word-from-your-selection", "privacy-overview", "model-downloads-and-management"]
updated: 2026-09-22
---
When EnviousWispr pastes a dictation and you then fix one word in it by hand, the word you typed joins your dictionary on its own, with the mishearing attached, and a small pill gives you two seconds to undo. The next time EnviousWispr hears the same thing it writes the word you meant. You never have to open Settings to teach it a name, and you never have to answer a question to keep it.

### What you see

**Dictate and paste as usual.** Nothing changes about recording.

**Fix a word in the pasted text.** Say you dictated "send it to Saoirse" and it came out "send it to Sasha". Click into the pasted text and change "Sasha" to "Saoirse".

**Read the pill.** A pill appears where the EnviousWispr pill lives (the top of your screen unless you moved it). For a name EnviousWispr did not know it says **Added “Saoirse” to Dictionary**. If Saoirse was already in Your Words, or came from one of your vocabulary packs, it says **“Saoirse” updated**, because the mishearing was attached to the word you already had. Either way the word is saved before the pill appears.

**Undo it if you want.** The pill carries one **Undo** button and stays for 2 seconds. Moving your pointer over it does not pause or extend that window. Click Undo and the pill says **Undone** for 1.5 seconds: a new word is removed, and an updated word goes back exactly to what it was before. Leave the pill alone and the word stays; there is nothing else to answer, now or later.

**Change your mind later.** Open **Settings** \> **Dictionary** \> **Your Words**. Words the Self-Learning Dictionary added carry a small sparkle, and so does each sound-alike it attached to a word you added yourself. Choose the **Auto-learned** filter to see only those. Edit or delete them the way you would any other word.

If the pill says **Couldn’t save “Saoirse”**, nothing was written: the mishearing already belongs to another word as a trigger, the word it was about had been deleted in the meantime, or the dictionary file could not be updated. If Undo says **Couldn’t undo**, the word stayed as it was and you can remove it in Your Words. Both notices stay for 3 seconds.

A learned word behaves like any word you added yourself: the mishearing is corrected before the text is polished, and it is used in every language you dictate in. You can edit or delete it in **Settings** \> **Dictionary** \> **Your Words**.

### Which apps it works in

EnviousWispr watches the pasted text for up to 60 seconds through macOS accessibility, the same channel a screen reader uses. It needs the Accessibility permission you already granted for automatic paste; without it nothing is watched. It works wherever the app shares its text box that way, which is most of them.

| Where you pasted | What happens |
|---|---|
| Native Mac apps (Mail, and any app whose text box works with a screen reader) | Watched. A fix inside the pasted text is judged. |
| Terminals (Ghostty and terminals that share their rows the same way) | Watched, including when the terminal wraps a long dictation onto several rows. |
| Apps built on web technology (WhatsApp and other Electron apps) | Watched. EnviousWispr asks these apps to switch on accessibility first, then waits a moment for the pasted text to show up before it starts watching. |
| Web pages in Safari and Chromium-family browsers (Chrome, Brave, Edge) | Watched where the page's text box shares its text with accessibility, which most do. Some custom editors on web pages do not, and then there is nothing to watch. |
| Password fields | Never watched. |
| Text that went to the clipboard instead of being pasted | Not watched. EnviousWispr only follows text it pasted itself. |

The watch ends early if you clear the text box, click into a different text box, dictate again, rewrite the text rather than fix a word in it, or the app stops sharing the text. It also stops if you switch to another app before the watch begins, and after two pauses in your editing it stops judging further fixes to that paste. If an app never shares its text, the dictation still pastes normally; nothing is learned, and nothing else changes.

### How it decides what counts as a correction

Not every edit is a correction. Rewriting a sentence, changing your mind about a word, or fixing punctuation should not become dictionary entries. A small language model on your Mac, a classifier trained for exactly this question, looks at the dictation and your edit and answers one thing: is the new word the word you actually said, spelled the way you want it? Only then is the word saved and the pill shown. If it answers no, nothing happens, and there is nothing to dismiss.

That model is about 305 MB. EnviousWispr normally starts its download after first-run setup and your speech model finish; you can cancel or retry the download from the same row. It runs on your Mac's own chip, on the Neural Engine where the Mac offers it and otherwise on the CPU, and answers in a fraction of a second. You can see its state in **Settings** \> **Dictionary** \> **Learn from...**: a download line with progress while it fetches, no extra line once it is ready, or a plain reason if it could not download or load, with a button to download, cancel or try again.

### What stays on your Mac

The watching and the judging run on your Mac. The text EnviousWispr watches, the word you fixed, the mishearing it attached, and the name of the app you were in never leave it, and Envious Labs never receives them. Your voice never leaves your Mac either: transcription happens on it. What Envious Labs receives is metadata with no content in it: why a watch was skipped or how it ended (a reason such as "password field"), how long it lasted and how many editing pauses it had, and a broad kind of app (native, web-based, browser or other); which on-device judge answered, whether it did, how many edits it saw and accepted, and how long it took; whether a save landed and, if not, which of three fixed reasons; whether the saved word was new, existing, or came from a pack; whether the Undo pill was shown; and whether an Undo restored the word, found it already changed, or failed. No words, watched text, app names, identifiers or error text are attached.

One thing to know: a learned word is a custom word, and custom words are part of what EnviousWispr sends to your polish provider along with your text. If you polish on your Mac (Apple Intelligence, EG-1, or an Ollama model you downloaded) nothing leaves it. If you chose cloud polish, whether under your own OpenAI, Gemini or Claude key or through one of Ollama's hosted models under your Ollama sign-in, the selected text and your custom words go directly to that provider under your key, never through Envious Labs, the same as any custom word you typed in yourself.

### Requirements and turning it off

The judge model has passed its exam on every macOS EnviousWispr supports, macOS 14 through macOS 27, so the Self-Learning Dictionary runs on any Apple silicon Mac. If a future macOS has not been examined yet, the row says **Not available on this version of macOS yet**; your choice is kept and applies as soon as your Mac qualifies.

To stop it, open **Settings**, go to **Dictionary** \> **Learn from...**, and switch off **Self-Learning Dictionary**. The row under the switch reads: Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words. Words it already learned stay in Your Words until you remove them; the **Auto-learned** filter finds them all.
