---
title: "Paste Not Working?"
description: "What to do when your dictation does not appear in your app."
category: "pasting-your-text"
section: "Paste System"
order: 3
keywords: ["paste not working", "wont paste", "nothing pastes", "text not appearing", "goes to the wrong app", "vs code", "slack", "discord", "notion", "no text in my app", "paste again", "paste last dictation", "dictation disappeared", "copied press cmd v", "text went to another window"]
related: ["accessibility-permission-not-working", "how-text-gets-pasted-into-your-app", "transcript-history"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
Your dictation is safe even when it does not appear. If it does not show up in the app you were typing in, get the words back first with Paste Last Dictation. Then check the Accessibility permission and whether your cursor was in a text box.

### Get my last dictation back

Click into the text box, then press your Paste Last Dictation keys (**Control Command V** unless you changed them). You can also click the EnviousWispr icon in your menu bar and choose **Paste Last Dictation**. Your last dictation is pasted again, so you do not have to repeat yourself.

To paste it somewhere yourself, press your Copy Last Dictation keys (**Control Command C** unless you changed them), then press Cmd+V. Your current keys are under **Keybinds**. See [Customizing Your Keybind](/help/customizing-your-keybind/).

Pasting needs Accessibility permission. Without it, the menu item opens the permission settings for you and the paste keys do nothing. Copying works either way.

### Nothing was typed and Accessibility may be off

macOS requires explicit permission before any app can type text into other windows. This is the most common cause of missing text.

1. Open **System Settings** > **Privacy & Security** > **Accessibility**.
2. Find EnviousWispr in the list and make sure its switch is on.

If the switch already looks on but nothing is typed, remove EnviousWispr from the list with the minus button, then add it back with the plus button. See [_Accessibility Permission Not Working_](/help/accessibility-permission-not-working/).

### The cursor was not in a text box

EnviousWispr delivers text to the text box your cursor was in when you started recording. Click directly into your target text box first, then press your keybind and start speaking.

### The text went to a different app or window

If you switched windows while dictating, the text still goes to the window you were in when you started, even when you have several windows of the same app open, such as two browser windows. This is deliberate. A slow AI polish cannot drop your words into an unexpected window if you change tasks mid-sentence.

If that window has closed by the time your text is ready, EnviousWispr leaves the words on your clipboard and shows the **Copied. Press ⌘V to paste** notice, so you can paste them yourself.

### Dictation fails in VS Code, Slack, Discord or Notion

Some apps built on web technology accept text input and then quietly drop it. EnviousWispr has backup delivery methods that handle this for most of them. If your text still does not appear, bring the app to the front and make sure your cursor is inside the text box before you record.

### The notice says the text is on my clipboard

When EnviousWispr cannot deliver your words, it shows **Copied. Press ⌘V to paste** and leaves them on your clipboard. In most apps it does the same when it can see that a paste went nowhere, for example when no text box was selected.

1. Click into a text box.
2. Press Cmd+V.
3. Check that EnviousWispr has the Accessibility permission, then click into the text box you want before your next recording.

Because your words stay on the clipboard, whatever you had copied before that dictation is replaced. If you are not sure what is on your clipboard, click into a text box and press **Control Command V** (unless you changed that key), or choose **Paste Last Dictation** in the menu bar menu. If it does nothing right after a dictation, try again a moment later.

### My paste failed but no notice appeared

EnviousWispr can only tell that a paste went nowhere when the app shows enough about where your cursor is. In some apps a missed paste shows nothing, and your clipboard is handled as usual. If you have **Restore clipboard after paste** on, your previous clipboard comes back. Paste Last Dictation works there too.
