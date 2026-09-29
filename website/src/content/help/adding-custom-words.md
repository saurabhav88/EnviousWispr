---
title: "Adding Custom Words"
description: "Teach EnviousWispr the exact spelling of names and specialised words it keeps getting wrong."
category: "custom-words"
section: "Dictionary"
order: 1
keywords: ["custom words", "vocabulary", "add a word", "my name", "names", "jargon", "technical terms", "spells my name wrong", "dictionary", "teach it a word", "acronyms", "how do I add a name", "where is your words", "fix a misspelled name", "turn on vocabulary packs", "import my contacts", "wrong spelling", "word keeps coming out wrong", "custom word not working", "Enable Dictionary"]
related: ["self-learning-dictionary", "why-is-my-dictation-inaccurate", "how-custom-word-correction-works", "using-snippets"]
updated: 2026-09-29
deflection: "can_resolve"
---
When EnviousWispr keeps misspelling a name or a specialised word, add it to your words and it writes your spelling from then on. You often do not need to add it by hand: fix the word once in text EnviousWispr recently pasted, and the [Self-Learning Dictionary](/help/self-learning-dictionary/) adds it for you.

### Add a word it keeps getting wrong

1. **Open your words.** Click the EnviousWispr icon in your menu bar, choose **Settings**, then go to **Dictionary** > **Your Words**.
2. **Add the word.** Click **Add word** and type the exact spelling you want to appear.

From then on, when you speak that word, EnviousWispr writes your spelling. If it writes "Chat G P T", adding "ChatGPT" fixes that in every dictation.

If a word you added still comes out wrong, see [How Custom Word Correction Works](/help/how-custom-word-correction-works/).

### Which words to add

A short, well-chosen list saves the most editing. These pay off most:

- Names of people you write to regularly.
- Your company name and your internal product names.
- Technical words, acronyms and jargon from your field that a general dictionary misses.

### Add a block of text instead of a word

A custom word is a spelling. If you want a whole block of text, such as your email address, a sign-off, or a link you send every week, use a snippet instead. See [Using Snippets](/help/using-snippets/).

### Add a ready-made pack of words

Vocabulary packs group common words by field, so you do not have to type each one.

1. Go to **Settings** > **Dictionary** > **Vocabulary Packs**.
2. Turn on the packs that match your work: Tech, Medical, Legal, Brands, and Names.

### Add names from your Contacts

You can pull names from the macOS Contacts app, so the people you write to are spelled correctly from your first dictation.

1. Go to **Settings** > **Dictionary** > **Learn from...**.
2. Use the Contacts import. macOS asks for your permission the first time.
3. Switch on **Keep in sync on launch** if you want EnviousWispr to check for new contacts each time it starts. This is off until you turn it on.

### Let EnviousWispr guess how a word gets misheard

When you add a word, EnviousWispr can work out how the speech engine is likely to mishear it and watch for those versions too. Adding "Kubernetes" prompts it to watch for versions like "Cooper net ease", so you do not have to think up the wrong spellings yourself.

This needs macOS 26 or later with Apple Intelligence switched on, and it all happens on your Mac. Without Apple Intelligence, your custom words still work as they should.

### My custom words stopped working

Your custom spellings apply only while **Enable Dictionary** is on. It is the switch at the top of **Settings** > **Dictionary**. Turn it on and your words apply again.

### Do my words reach AI Polish?

While **Enable Dictionary** is on, your spellings are applied to your transcribed text before AI Polish runs, whether or not polish is switched on.

If you use a cloud provider for AI Polish, your word list is also sent to it with your text, so its rewrite keeps your spellings. This covers OpenAI, Gemini, Claude, and every Ollama model except EG-1 and S1-mini. If the app cannot tell with confidence which language you spoke, it keeps the list back for that dictation. Apple Intelligence, EG-1 and S1-mini are never sent it. While **Enable Dictionary** is on, your words have already been applied to the text before AI Polish gets it, so nothing is lost.

### Move your words to another Mac

To back up your words, carry them to another Mac, or bring them in from another app, see [Importing and Exporting Custom Words](/help/importing-and-exporting-custom-words/).
