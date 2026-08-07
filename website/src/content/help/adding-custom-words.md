---
title: "Adding Custom Words"
description: "Teaching EnviousWispr names and terms it keeps getting wrong."
category: "custom-words"
section: "Custom Words"
order: 1
keywords: ["custom words", "vocabulary", "add a word", "my name", "names", "jargon", "technical terms", "spells my name wrong", "dictionary", "teach it a word", "acronyms"]
related: ["why-is-my-dictation-inaccurate", "how-custom-word-correction-works"]
updated: 2026-08-06
---
When EnviousWispr repeatedly misspells a name or a specialised term, you can teach it the exact spelling you want to use.

### Adding a custom word

Open settings to enter your preferred terms and override what the speech engine produces.

1. **Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Your Words**.
2. **Add your term.** Type the exact spelling you want to appear.

From then on, when you speak that word, EnviousWispr writes your chosen spelling. If it writes out "Chat G P T", adding "ChatGPT" to your words corrects that for every dictation from then on.

### Words worth adding

Building a reliable list saves you time editing afterwards. These are the categories that pay off most:

- Names of people you write to regularly.
- Your company name and your internal product names.
- Technical terms, acronyms, and jargon from your field that a general dictionary misses.

### Using ready-made vocabulary packs

Vocabulary packs group common terms by industry, so you do not have to type every word in yourself.

**Switch on a pack.** On the same **Your Words** page, turn on any of the packs: Tech, Medical, Legal, and Brands and Names. Turn on the ones that match your daily work to cover those terms straight away.

### Importing from Contacts

You can pull names directly out of your macOS Contacts app, so the people you write to are spelled correctly from your very first dictation.

**Import your contacts.** Use the Contacts import on the **Your Words** page. macOS asks for your permission the first time you do this.

**Keep it up to date.** Switch on **Keep in sync on launch** if you want EnviousWispr to check for new contacts each time it starts. This setting is off unless you turn it on.

### Letting your Mac guess the mishearings

When you add a word, EnviousWispr can work out how the speech engine is likely to mishear it and watch for those versions too. Adding "Kubernetes" prompts it to watch for versions like "Cooper net ease", which saves you thinking up the wrong spellings yourself.

This needs macOS 26 or later with Apple Intelligence switched on, and it all happens on your Mac. Without Apple Intelligence, your custom words still work exactly as they should.

### When your words are applied

Your custom spellings are applied to your transcribed text before AI Polish runs, on every dictation, whether or not polish is switched on.

OpenAI, Gemini, Claude, and every Ollama model also receive your custom word list, so their rewrites keep your spellings. Apple Intelligence and EG-1 do not receive it, because they do better with shorter instructions, and your words have already been applied to the text by that stage.

To move your words between Macs, or bring them in from another app, read [_Importing and Exporting Custom Words_](/help/importing-and-exporting-custom-words/).
