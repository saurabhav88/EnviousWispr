---
title: "Self-Learning Dictionary"
description: "Fix a misheard word in text EnviousWispr pasted a moment ago, and the right spelling joins your dictionary on its own, with four seconds to undo."
category: "custom-words"
section: "Dictionary"
order: 5
keywords: ["self-learning dictionary", "learn from my edits", "learn from edits", "undo", "auto-learned", "correction", "misheard word", "custom words", "on-device", "local classifier", "word check", "Envious Word Check", "checked by", "learn-only", "privacy", "which apps", "word not learned", "remove a learned word", "turn off learning", "wrong word added to dictionary"]
related: ["adding-custom-words", "how-custom-word-correction-works", "adding-a-word-from-your-selection", "privacy-overview", "model-downloads-and-management"]
updated: 2026-09-29
deflection: "can_resolve"
---
The Self-Learning Dictionary adds words to your dictionary for you. When you fix a misheard word in text EnviousWispr pasted a moment ago, and a check on your Mac agrees it was a correction, the word you typed is saved in Your Words with the mishearing attached. A small pill gives you four seconds to undo it. You never have to open Settings to teach it a name.

### Teach it a word by fixing it

1. **Dictate and paste as usual.** Nothing changes about recording.
2. **Fix the word.** Say you dictated "send it to Saoirse" and it came out "send it to Sasha". Click into the pasted text and change "Sasha" to "Saoirse".
3. **Read the pill.** A pill appears where the EnviousWispr pill lives, at the top of your screen unless you moved it. For a name EnviousWispr did not know, it says **Added “Saoirse” to Dictionary**. If Saoirse was already in Your Words, or came from one of your vocabulary packs, it says **“Saoirse” updated**, because the mishearing was attached to the word you already had. Either way, the word is saved before the pill appears.

There is nothing else to answer, now or later.

### Undo a word it learned

The pill has one **Undo** button and stays for 4 seconds. Moving your pointer over it does not pause or extend that time.

Click **Undo** and the pill says **Undone** for 1.5 seconds. A new word is removed. An updated word goes back exactly to what it was before. If you leave the pill alone, the word stays.

If Undo says **Couldn’t undo**, the word stayed as it was. That notice stays for 3 seconds. Remove it in **Settings** > **Dictionary** > **Your Words** instead.

### Remove a word it learned

1. Open **Settings** > **Dictionary** > **Your Words**.
2. Choose the **Auto-learned** filter to see words the Self-Learning Dictionary added, or words it attached a sound-alike to. They carry a small sparkle, and so does each sound-alike it attached to a word you added yourself.
3. Edit or delete them the way you would any other word.

### A word I fixed wasn't learned

Not every edit becomes a dictionary entry. Rewriting a sentence, changing your mind about a word, or fixing punctuation is not a correction, so nothing is saved and no pill appears.

Before it saves a word, a small correction model on your Mac looks at the dictation and your edit. It asks one question: is the new word what you actually said, spelled the way you want it? If the answer is no, nothing happens.

If your edit was a real correction and nothing was learned, check these:

- **The pill said Couldn’t save.** Nothing was written. The mishearing already belongs to another word as a trigger, the word it was about had been deleted in the meantime, or the dictionary file could not be updated. This pill also stays for 3 seconds.
- **The app does not share its text.** Some apps and custom web editors never share their text with macOS accessibility. The dictation still pastes normally, but nothing is learned.
- **The watch ended early.** EnviousWispr stops watching if you clear the text box, click into a different text box, dictate again, rewrite the text instead of fixing a word, or switch to another app before the watch begins. After two pauses in your editing, it also stops judging further fixes to that paste.
- **You stopped without moving on.** If the only sign you were done was a pause or a switch to another app, the correction model has to be surer before it saves the word, because a half-typed word looks the same. Moving the cursor off the word right after your fix counts as done. Dictating again within a minute and before you leave that app does too, and so does sending the text in most apps (when sending clears or closes the text box): the usual check then applies.
- **The text went to the clipboard.** EnviousWispr only follows text it pasted itself.
- **The correction model is not ready.** Open **Settings** > **Dictionary** > **Learn from...**. The row shows a download line with progress while the model downloads, or a plain reason if it could not download or load, with a button to download, cancel or try again. Once the model is ready, that extra line goes away. EnviousWispr normally starts the download after first-run setup and your speech model finish. The model is about 300 MB. It runs on your Mac's own chip and answers in a fraction of a second.

### Which apps it works in

The Self-Learning Dictionary watches the pasted text for up to 60 seconds through macOS accessibility, the same channel a screen reader uses. It needs the Accessibility permission you already granted for automatic paste. Without it, nothing is watched. It works wherever the app shares its text box that way, which is most of them. The watch also ends early if the app stops sharing its text.

| Where you pasted | What happens |
|---|---|
| Native Mac apps (Mail, and any app whose text box works with a screen reader) | Watched. A fix inside the pasted text is judged. |
| Terminals (Ghostty and terminals that share their rows the same way) | Watched, including when the terminal wraps a long dictation onto several rows. |
| Apps built on web technology (WhatsApp is one) | Watched. EnviousWispr asks these apps to switch on accessibility first, then waits a moment for the pasted text to show up before it starts watching. |
| Web pages in Safari, Chrome, Brave and Edge | Watched where the page's text box shares its text with accessibility, which most do. Some custom editors on web pages do not, and then there is nothing to watch. |
| Password fields | Never watched. |
| Text that went to the clipboard instead of being pasted | Not watched. |

### Learned words aren't fixing my dictations

A learned word never replaces text on its own. When a later dictation contains a mishearing you corrected before, EnviousWispr asks a word check on your Mac one question about that spot: in this sentence, did you mean the learned word? Only the spots it approves change. That is how it swaps an ordinary word for your term where you meant the term, for example "Twist" to "Tuist", and leaves the ordinary word alone in a sentence where you meant it. A mishearing it has not seen yet is left alone until you correct it once.

If learned words are not being applied, check these:

- **Enable Dictionary is off.** Words are still learned then, but never applied. Switch **Enable Dictionary** on in **Settings** > **Dictionary**.
- **The row says Learn-only.** Look at the row under the switch in **Settings** > **Dictionary** > **Learn from...**. It shows which check is in use, for example **Checked by: Envious Word Check. Learned words are checked before they're used.** While the check is downloading, or if it could not download or is not ready, the row starts with **Learn-only**. New words are still learned and saved, and they start fixing dictations once the check is ready, as long as **Enable Dictionary** is on. When a download failed, or Envious Word Check could not load, a **Try again** button appears.
- **The check ran out of time.** If the word check cannot answer in time, your text arrives exactly as it would have without it. That costs at most about two and a half seconds for a dictation. For Transcribe a File, each part of a long file can wait up to about 1.2 seconds more, and a little more when a part is in a different language. A very short dictation after a quiet stretch may reach the check while it is still loading, and is then left as it would be without the check.

The word check works in every dictation language, for dictation and for Transcribe a File.

### Which word check is used

The check depends on the polish choice you use:

| Polish choice | Word check |
|---|---|
| EG-1 | EG-1's own word check |
| S1-mini | S1-mini's own word check |
| Apple Intelligence, a cloud provider, Ollama, or no polish | Envious Word Check |

The word check is a separate download from the correction model: about 500 MB for Envious Word Check, 66 MB for EG-1's and 81 MB for S1-mini's. Envious Word Check downloads only while **Enable Dictionary** is on and a polish choice you use for dictation or Transcribe a File needs it.

It loads into memory only when something needs it: a dictation, a file you start in Transcribe a File (**Start** or **Clean it again**), a recording EnviousWispr recovered after an unexpected quit or a cancel with [Escape Recovery](/help/escape-recovery/), or you press **Try again**. Starting EnviousWispr or changing a setting does not load it. Finishing its download loads it only if a dictation, a file transcription or a recording recovery already running needs it. It normally leaves memory after about 10 minutes without use. Work still using it can keep it longer, and turning off **Enable Dictionary** or choosing polish options with their own word check can release it sooner.

### Does it send anything off my Mac?

The watching and the judging run on your Mac and send nothing off it. Envious Labs never receives the text EnviousWispr watches, the word you fixed, or the mishearing it attached. Your voice never leaves your Mac either: transcription happens on it.

What Envious Labs can receive is metadata with no content in it:

- **Only while Share usage metrics is on** (in **Settings** > **Permissions**): why a watch was skipped or how it ended, how long it lasted, a broad kind of app (native, web-based, browser or other), whether the correction model answered and how long it took, whether the edit ended clearly (you moved the cursor away, sent the text or dictated again) or only by a pause or a switch to another app, whether a word was saved (and if not, which of three fixed reasons), whether the saved word was new, existing or from a pack, and whether Undo was shown and used. Each word check adds only which check ran, its version, whether it could answer and why not, and counts and timing. Some of these reports carry the same anonymous ID as that dictation's own usage report, which includes the identifier of the app you pasted into. See [What data is collected](/help/what-data-is-collected/). Also only while this switch is on, the app sends at most one memory report per launch, after 12 minutes with no dictation or file transcription: how much memory it uses, time since launch, and whether Envious Word Check is loaded and needed.
- **Error reports, controlled by Send crash reports** (in **Settings** > **Permissions**): if the correction model fails to load, returns a broken answer or cannot be asked, one error report per kind per launch names that kind, the model's version and your macOS version. No dictated or watched text, and no error text, is attached.

Every word check runs locally, including when you use cloud polish. The word check itself sends no text over the network. If you choose cloud polish, the selected text goes directly to your chosen provider under your key, never through Envious Labs, after the word check has already applied your learned words. Custom words you added yourself may also go to that provider with the selected text.

### Turn off learning from my edits

1. Open **Settings** > **Dictionary** > **Learn from...**.
2. Switch off **Self-Learning Dictionary**.

The row under the switch reads: Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.

Turning it off stops new learning only. Words it already learned stay in Your Words and keep fixing dictations through the word check until you remove them or turn off **Enable Dictionary**. The **Auto-learned** filter finds them all.

### Does it work on my Mac?

The correction model is approved for every macOS that EnviousWispr supports, macOS 14 through macOS 27, so the Self-Learning Dictionary runs on any Apple silicon Mac. If a future macOS has not been examined yet, the row says **Not available on this version of macOS yet**. Your choice is kept and applies as soon as your Mac qualifies.
