---
title: "Self-Learning Dictionary"
description: "When you fix a misheard word in text EnviousWispr pasted a moment ago, it offers to add the right spelling to your dictionary. Which apps it works in, how the on-device judge decides, and what stays on your Mac."
category: "custom-words"
section: "Dictionary"
order: 5
keywords: ["self-learning dictionary", "learn from my edits", "learn from edits", "pending suggestions", "correction", "misheard word", "custom words", "on-device", "local classifier", "privacy", "which apps"]
related: ["adding-custom-words", "how-custom-word-correction-works", "adding-a-word-from-your-selection", "privacy-overview", "model-downloads-and-management"]
updated: 2026-09-21
---
When EnviousWispr pastes a dictation and you then fix one word in it by hand, a small card asks whether that fix should become a dictionary entry. Accept it and the word joins Your Words with the mishearing attached, so the next time EnviousWispr hears the same thing it writes the word you meant. You never have to open Settings to teach it a name.

### What you see

**Dictate and paste as usual.** Nothing changes about recording.

**Fix a word in the pasted text.** Say you dictated "send it to Saoirse" and it came out "send it to Sasha". Click into the pasted text and change "Sasha" to "Saoirse".

**Answer the card.** A card appears where the EnviousWispr pill lives (the top of your screen unless you moved it), showing the mishearing on one side and the correct word on the other, with **Accept** and **Reject**. Accept saves the word. Reject means EnviousWispr will not ask about that pair again.

**Or answer later.** The card stays for about eight seconds, longer while your pointer is over it. A card you do not answer waits in **Settings** \> **Dictionary** \> **Pending**, where you can accept or reject it any time. The Pending tab shows a count when something is waiting.

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
| Text that went to the clipboard instead of being pasted | Not watched. The card only follows text EnviousWispr pasted itself. |

The watch ends early if you clear the text box, click into a different text box, dictate again, rewrite the text rather than fix a word in it, or the app stops sharing the text. It also stops if you switch to another app before the watch begins, and after two pauses in your editing it stops judging further fixes to that paste. If an app never shares its text, the dictation still pastes normally; there is no card, and nothing else changes.

### How it decides what counts as a correction

Not every edit is a correction. Rewriting a sentence, changing your mind about a word, or fixing punctuation should not become dictionary entries. A small language model on your Mac, a classifier trained for exactly this question, looks at the dictation and your edit and answers one thing: is the new word the word you actually said, spelled the way you want it? Only then does the card appear.

That model is about 305 MB. EnviousWispr normally starts its download after first-run setup and your speech model finish, including on earlier versions of macOS where it cannot run yet; you can cancel or retry the download from the same row. It runs on your Mac's own chip, on the Neural Engine where the Mac offers it and otherwise on the CPU, and answers in a fraction of a second. You can see its state in **Settings** \> **Dictionary** \> **Learn from...**: a download line with progress while it fetches, no extra line once it is ready, or a plain reason if it could not download or load, with a button to download, cancel or try again.

### What stays on your Mac

Everything in this feature runs on your Mac. The text EnviousWispr watches and the word you fixed never leave it, and Envious Labs receives neither. The app reports metadata only: why a watch ended or was skipped (a reason such as "password field"), how long it lasted and how many editing pauses it had, and a broad kind of app (native, web-based, browser or other); which on-device judge answered, whether it did, how many edits it saw and accepted, and how long it took; whether a suggestion was for a new or an existing word; whether a card was shown, expired, was accepted or rejected, and from which screen; and whether saving or the waiting list's file failed or recovered. No words, watched text, app names or identifiers are attached.

One thing to know: a learned word is a custom word, and custom words are part of what EnviousWispr sends to your polish provider along with your text. If you polish on your Mac (Apple Intelligence, EG-1, or a downloaded Ollama model) that never leaves it. If you chose cloud polish, whether under your own OpenAI, Gemini or Claude key or through one of Ollama's hosted models under your Ollama sign-in, learned words travel with your text to that provider, the same as any custom word you typed in yourself.

### Requirements and turning it off

The judge model has passed its exam on macOS 15, macOS 26 and macOS 27, so that is where the Self-Learning Dictionary runs today. On macOS 14 the switch is still there but the row says **Not available on this version of macOS yet**; your choice is kept and applies as soon as your Mac qualifies.

To stop it, open **Settings**, go to **Dictionary** \> **Learn from...**, and switch off **Self-Learning Dictionary**. Words you already accepted stay in Your Words until you remove them.
