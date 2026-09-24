---
title: "Paste Not Working?"
description: "What to check when your dictation does not appear in your app."
category: "pasting-your-text"
section: "Paste System"
order: 3
keywords: ["paste not working", "wont paste", "nothing pastes", "text not appearing", "goes to the wrong app", "vs code", "slack", "discord", "notion", "no text in my app", "paste again", "paste last dictation", "dictation disappeared"]
related: ["accessibility-permission-not-working", "how-text-gets-pasted-into-your-app", "transcript-history"]
updated: 2026-09-23
---
When your dictation does not appear in the app you were typing in, work through these steps in order.

### First, get your words back

Click into the text box, then press your Paste Last Dictation keys (**Control Command V** unless you changed them), or click the EnviousWispr icon in your menu bar and choose **Paste Last Dictation**. Your last dictation is pasted again, so you do not have to repeat yourself. To paste it somewhere yourself, press your Copy Last Dictation keys (**Control Command C** unless you changed them) and then Cmd+V. Your current keys are in **Keybinds**; see [Customizing Your Keybind](/help/customizing-your-keybind/).

If that does not paste either, the checks below find the cause. Pasting needs Accessibility permission: without it the menu item opens the permission settings for you, and the paste keys do nothing. Copying works either way.

### 1. Check Accessibility permission

macOS requires explicit permission before any app can type text into other windows, and this is the cause of missing text most of the time. Open **System Settings**, click **Privacy & Security**, and select **Accessibility**. Find EnviousWispr in the list and make sure its switch is turned on. Without this permission, EnviousWispr cannot deliver your text.

If the switch already looks on but nothing is typed, remove EnviousWispr from the list using the minus button, then add it back using the plus button.

### 2. Check your cursor was in a text box

EnviousWispr delivers text to whichever text field your cursor was in when you started recording. Click directly into your target text box first, then press your keybind and begin speaking.

### 3. The text went to a different app

If you switched windows while dictating, the text still goes to the app you were in when you started. That is deliberate. It makes sure a slow AI polish cannot drop your words into an unexpected window if you change tasks mid-sentence.

### 4. VS Code, Slack, Discord and similar apps

Some apps built on web technology accept text input and then quietly drop it. EnviousWispr has fallback delivery methods that handle this for most of them. If your text still fails to appear, bring the target app to the front and make sure your cursor is inside the text field before you record.

### 5. You were told the text is on your clipboard

If every delivery method fails, or EnviousWispr can see that a paste went nowhere (for example, no text box was selected), it leaves your words on the clipboard and shows **Copied. Press ⌘V to paste**. Your dictation is safe. Click into a text box and press Cmd+V to paste it yourself, then work through the checks above to get normal delivery back. Because your words stay on the clipboard, whatever you had copied before that dictation is replaced.

EnviousWispr can only tell a paste went nowhere when the app shows enough about where your cursor is, so in some apps a missed paste still shows nothing. [First, get your words back](#first-get-your-words-back) works in those apps too.
