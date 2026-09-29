---
title: "Using Snippets"
description: "Say a short keyword and a trigger, and EnviousWispr pastes the text you saved."
category: "features"
section: "Text Processing"
order: 7
keywords: ["snippets", "text expansion", "voice shortcut", "paste my email", "keyword", "backslash", "signature", "expand phrase", "saved text", "today's date", "paste the time", "paste what I copied", "clipboard snippet", "fill-in", "snippet not working", "snippet did not expand", "change snippet keyword", "import snippets", "export snippets"]
related: ["adding-custom-words", "ai-polish-and-cloud-data"]
updated: 2026-09-29
deflection: "can_resolve"
---
A snippet is a voice shortcut. You save a piece of text once, then say a short phrase to paste it. It suits an email address, a sign-off, or a link you send people every week. Snippets live in **Settings** > **Snippets**.

### Add a snippet

1. Open **Settings** > **Snippets**.
2. Click **Add snippet**.
3. Type the words you will say in **Snippet**, and the text you want pasted in **Expands to**. Your keyword sits to the left of the **Snippet** box, so you can read the whole phrase you will say.
4. Click **Save**.

### Say a snippet

A snippet only expands when you say your keyword first, then the trigger. The keyword is `backslash` unless you change it.

Say this:

> Feel free to email me at **backslash my email** any time.

You get this:

> Feel free to email me at john.doe@example.com any time.

### My snippet did not expand

Check that you said the keyword first. The keyword keeps snippets out of your way, so the same trigger without it does nothing:

> Can you send me **my email** from that form?

That sentence comes out exactly as you said it.

The same is true if you say the keyword and nothing after it matches a snippet you saved. No snippet fires, and your words carry on through EnviousWispr as normal. That includes AI Polish, so the sentence can be tidied like any other.

Also check the trigger you saved. Matching ignores capital letters and trailing punctuation, so "My Email Address." and "my email address" are the same trigger.

### Try the example snippets

EnviousWispr ships with six example snippets so you can try the feature before you write anything. They belong to a made-up person called John Doe, and each one is marked **Example** in the list until you change it.

| Say | You get |
| --- | --- |
| `backslash my email` | john.doe@example.com |
| `backslash my phone` | (555) 010-4477 |
| `backslash my address` | 1600 Example Way, Suite 200, Springfield, IL 62704 |
| `backslash my calendar` | https://cal.example.com/john-doe |
| `backslash my signature` | Thanks so much. John Doe, Product at Example Co. |
| `backslash my intro` | Hi, I'm John Doe. I lead product at Example Co, and I'm happy to help however I can. |

These are ordinary snippets. Open one, replace John Doe's details with yours, and click **Save**. The **Example** mark disappears once the text is yours.

Delete the ones you do not want. They stay deleted, and EnviousWispr does not add them back on the next launch.

### Paste the date, the time or what you copied

Three parts of a snippet do not have to be fixed text: today's date, the time right now, and the last thing you copied. Write them inside your snippet's text:

| Write this | You get |
| --- | --- |
| `{{date}}` | Sep 17, 2026 |
| `{{time}}` | 2:45 PM |
| `{{clipboard}}` | whatever you copied last |

A snippet saved as `Filed {{date}} at {{time}}. Link: {{clipboard}}` pastes today's date, the time you spoke, and the link on your clipboard.

The **Expands to** box has a button for each one: **Today's date**, **Time now** and **Last copied**. A button adds the fill-in at the end of your text, and you can move it anywhere afterwards. Capital letters make no difference, so `{{DATE}}` works the same way.

- The date and the time follow your Mac's language and time zone.
- A fill-in is worked out when you speak, not when you save. A snippet saved today still says the right day next month.
- If your clipboard has no plain text, `{{clipboard}}` adds no text. If that leaves the whole dictation empty, EnviousWispr returns the words you spoke.
- Fill-ins read your clipboard only when a snippet using `{{clipboard}}` fires. Clipboard preservation is separate: when it is on, EnviousWispr saves your clipboard while pasting so it can put it back afterwards.
- If EnviousWispr recovers a recording after a crash, fill-ins use the values available when recovery processes it.
- Other placeholders, such as `{{cursor}}` or `{{DATE:yyyy-MM-dd}}`, stay as literal text in a saved snippet.

### Change the snippet keyword

The keyword field is at the top of the Snippets screen. Pick a word you would not say by accident. `backslash` is the default because most people rarely say it out loud.

Clearing the field puts the default back rather than switching snippets off.

If you turn on **Convert spoken punctuation**, a `backslash` that no snippet claims types the `\` symbol instead. A saved snippet always wins when its words follow the keyword, even in the middle of a file path. If you dictate paths that collide with your snippet names, pick a different keyword.

### Will AI Polish change my snippet?

No. The text you save is pasted word for word, with a space after it like any other dictation. The only exception is a fill-in you asked for, which becomes the date, the time or what you copied first. AI Polish never rewrites any of it, so an email address, a web link or a signature arrives as you saved it. Everything else you dictate is still polished as normal.

Line breaks are kept, so a two-line sign-off arrives as two lines.

### Why does my snippet have no full stop at the end?

Your saved text decides how it ends.

- If you say only the keyword and the trigger, such as into a search box or an empty field, the full stop the speech engine adds to a complete sentence is dropped. An email address does not arrive with a full stop attached.
- If your saved text already ends a sentence, no second full stop is added.
- In the middle of a sentence of your own, your own punctuation is kept.
- If your snippet ends in a fill-in, the filled-in text decides. A snippet ending in `{{clipboard}}` counts as ending a sentence when the text you copied does.

### Spacing and capitals look different after a snippet

A dictation containing a snippet skips the cursor tidy-up. Normally, when you dictate into the middle of a sentence you already typed, EnviousWispr fixes the spacing and capital letters where the two halves meet. On a dictation that expanded a snippet, it leaves the text alone, so nothing can alter your saved text.

### Save fails or a trigger is refused

The Snippets screen enforces three rules:

- A snippet needs both a trigger and some text. An empty snippet would delete the words you said.
- Two snippets cannot share the same spoken words. There would be no way to say which one you meant.
- Matching ignores capital letters and trailing punctuation.

### Back up snippets or move them to a new Mac

**Export** writes your snippets and your keyword to a file you choose. EnviousWispr will not save over its own snippets file, because that would erase the snippets you were trying to back up.

**Import** brings snippets in from four places:

- The file you exported.
- A CSV with a trigger column and a text column.
- A list you paste, one snippet per line: the trigger, then `=`, then the text. A tab, an arrow or a comma also works.
- Another dictation app on the same Mac. Wispr Flow and TypeWhisper are supported today.

You review the list before anything is saved. Snippets you already have are marked and skipped, and you can untick any you do not want. Your keyword is never changed by an import; only the snippets come across.

TypeWhisper entries that use today's date, the time or the clipboard come across and keep filling in. TypeWhisper entries containing other placeholders are left out and counted.
