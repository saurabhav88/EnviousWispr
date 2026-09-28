---
title: "Self-Learning Dictionary"
description: "When you fix a misheard word in text EnviousWispr pasted a moment ago, the right spelling joins your dictionary on its own, with three seconds to undo, and a word check on your Mac uses it in later dictations. Which apps it works in, how it decides, and what stays on your Mac."
category: "custom-words"
section: "Dictionary"
order: 5
keywords: ["self-learning dictionary", "learn from my edits", "learn from edits", "undo", "auto-learned", "correction", "misheard word", "custom words", "on-device", "local classifier", "word check", "Envious Word Check", "checked by", "learn-only", "privacy", "which apps"]
related: ["adding-custom-words", "how-custom-word-correction-works", "adding-a-word-from-your-selection", "privacy-overview", "model-downloads-and-management"]
updated: 2026-09-27
---
When EnviousWispr pastes a dictation and you then fix one word in it by hand, the word you typed joins your dictionary on its own, with the mishearing attached, and a small pill gives you three seconds to undo. Learned words are saved in Your Words, and from then on a word check on your Mac uses them to fix the same mishearing in later dictations. You never have to open Settings to teach it a name, and you never have to answer a question to keep it.

### What you see

**Dictate and paste as usual.** Nothing changes about recording.

**Fix a word in the pasted text.** Say you dictated "send it to Saoirse" and it came out "send it to Sasha". Click into the pasted text and change "Sasha" to "Saoirse".

**Read the pill.** A pill appears where the EnviousWispr pill lives (the top of your screen unless you moved it). For a name EnviousWispr did not know it says **Added “Saoirse” to Dictionary**. If Saoirse was already in Your Words, or came from one of your vocabulary packs, it says **“Saoirse” updated**, because the mishearing was attached to the word you already had. Either way the word is saved before the pill appears.

**Undo it if you want.** The pill carries one **Undo** button and stays for 3 seconds. Moving your pointer over it does not pause or extend that window. Click Undo and the pill says **Undone** for 1.5 seconds: a new word is removed, and an updated word goes back exactly to what it was before. Leave the pill alone and the word stays; there is nothing else to answer, now or later.

**Change your mind later.** Open **Settings** \> **Dictionary** \> **Your Words**. Words the Self-Learning Dictionary added carry a small sparkle, and so does each sound-alike it attached to a word you added yourself. Choose the **Auto-learned** filter to see only those. Edit or delete them the way you would any other word.

If the pill says **Couldn’t save “Saoirse”**, nothing was written: the mishearing already belongs to another word as a trigger, the word it was about had been deleted in the meantime, or the dictionary file could not be updated. If Undo says **Couldn’t undo**, the word stayed as it was and you can remove it in Your Words. Both notices stay for 3 seconds.

### How learned words fix later dictations

A learned word never replaces text on its own. When a later dictation contains a mishearing you corrected before, EnviousWispr asks a word check on your Mac one question about that spot: in this sentence, did you mean the learned word? Only the spots it approves change. A mishearing it has not seen yet is left alone until you correct it once. The check is what lets it swap an ordinary word for your term where you meant the term, for example "Twist" to "Tuist", and leave the ordinary word alone in a sentence where you meant it.

Which word check answers depends on the polish choice you use:

| Polish choice | Word check |
|---|---|
| EG-1 | EG-1's own word check |
| S1-mini | S1-mini's own word check |
| Apple Intelligence, a cloud provider, Ollama, or no polish | Envious Word Check |

The check works in every dictation language, for dictation and for Transcribe a File. If it cannot answer in time, your text arrives exactly as it would have without it, at most about two and a half seconds later, rather than waiting on the check.

The row under the switch in **Settings** \> **Dictionary** \> **Learn from...** shows which check is in use, for example **Checked by: Envious Word Check. Learned words are checked before they're used.** While the check is downloading, or if it could not download or is not ready, the row starts with **Learn-only**: new words are still learned and saved, and they start fixing dictations once the check is ready. When a download or load failed, a **Try again** button appears.

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

That model is about 320 MB. EnviousWispr normally starts its download after first-run setup and your speech model finish; you can cancel or retry the download from the same row. It runs on your Mac's own chip, on the Neural Engine where the Mac offers it and otherwise on the CPU, and answers in a fraction of a second. You can see its state in **Settings** \> **Dictionary** \> **Learn from...**: a download line with progress while it fetches, no extra line once it is ready, or a plain reason if it could not download or load, with a button to download, cancel or try again.

The word check that uses learned words is a separate download: about 500 MB for Envious Word Check, 66 MB for EG-1's and 81 MB for S1-mini's. Envious Word Check downloads only while **Enable Dictionary** is on and a polish choice you use for dictation or Transcribe a File needs it. It loads into memory when a dictation is about to need it and is released after 10 minutes without one, or as soon as you turn off **Enable Dictionary**.

### What stays on your Mac

The watching and the judging run on your Mac and send nothing off it. Envious Labs never receives the text EnviousWispr watches, the word you fixed, or the mishearing it attached. Your voice never leaves your Mac either: transcription happens on it. What Envious Labs receives is metadata with no content in it: why a watch was skipped or how it ended (a reason such as "password field"), how long it lasted and how many editing pauses it had, a broad kind of app (native, web-based, browser or other), and, when the watch lost track of the text, counts that describe the text box's shape (such as how many rows it showed), never its content; which on-device judge answered, whether it did, how many edits it saw and accepted, and how long it took; whether a save landed and, if not, which of three fixed reasons; whether the saved word was new, existing, or came from a pack; whether the Undo pill was shown; whether an Undo restored the word, found it already changed, or failed. Each word check adds only which check ran, its version, whether it could answer and why not, and counts and timing. Reports about a skipped watch, an ended watch, and a judge result carry the dictation's anonymous ID. They can be matched with that dictation's own usage report, which includes the destination app's identifier (see [privacy overview](/help/privacy-overview/)). If the judge model fails to load, returns a broken answer, or cannot be asked, one error report per kind per launch names that kind, the judge's version and your macOS version. No dictated or watched text, and no error text, is attached.

Every word check runs locally, including when you use cloud polish. The text it checks never leaves your Mac. If you choose cloud polish, the selected text goes directly to your chosen provider under your key, never through Envious Labs, after the word check has already applied your learned words. Custom words you added yourself may also go to that provider with the selected text.

### Requirements and turning it off

The judge model is approved for every macOS EnviousWispr supports, macOS 14 through macOS 27, so the Self-Learning Dictionary runs on any Apple silicon Mac. If a future macOS has not been examined yet, the row says **Not available on this version of macOS yet**; your choice is kept and applies as soon as your Mac qualifies.

To stop it, open **Settings**, go to **Dictionary** \> **Learn from...**, and switch off **Self-Learning Dictionary**. The row under the switch reads: Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words. Words it already learned stay in Your Words until you remove them; the **Auto-learned** filter finds them all.
