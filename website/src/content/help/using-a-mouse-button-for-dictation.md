---
title: "Using a Mouse Button for Dictation"
description: "Start dictation from a side button on a gaming mouse."
category: "recording-and-hotkeys"
section: "Recording"
order: 6
keywords: ["mouse", "mouse button", "gaming mouse", "side buttons", "thumb buttons", "razer", "naga", "logitech", "mmo mouse", "extra buttons", "bind mouse button", "middle click", "scroll wheel click", "start dictation with mouse", "hotkey on mouse"]
related: ["customizing-your-hotkey"]
updated: 2026-08-10
---
The **Shortcuts** page accepts keyboard keys, so there is no mouse button to pick from a list. Most extra buttons on a gaming mouse can still start dictation, because those buttons already send keyboard keys rather than mouse clicks.

### Find out what your buttons send

The hotkey box itself is the test, because it shows you exactly what EnviousWispr
receives from that button.

1. **Open settings.** Click the EnviousWispr icon in your menu bar, choose **Settings**, and go to **Shortcuts**.
2. **Select the hotkey box.** Click the **Recording hotkey** box.
3. **Press one of the extra buttons on your mouse.** Use a side button or a thumb button, not left or right click.

Whatever appears in the box is what that button sends.

| What appears in the box | What it means | What to do |
|---|---|---|
| `F13`, or another key you never type | The button is already sending an unused key | Nothing more. Save it and you are done. |
| A letter, number or punctuation mark | The button sends a key you type with | Remap it first, or your hotkey fires every time you type that character |
| A modifier such as Right Option | The button is acting as a modifier | Works, with the trade-off in the table below |
| Nothing at all | The button sends something EnviousWispr cannot bind | See the last section |

A twelve button thumb grid often sends the number row, so the buttons come
through as `1`, `2`, `3` and so on. Every mouse is different, which is why it is
worth checking yours rather than assuming.

Pressing the button into an ordinary text field is a quicker rough check, but it
cannot tell you everything. A button already set to F13, to an arrow key, or to a
modifier types no character at all, and silence in a text field looks identical
to a button that sends nothing. The hotkey box tells the two apart.

### Remap the button, then bind it

Sending `4` is not useful on its own, because setting `4` as your hotkey would swallow that key everywhere you type. The fix is to point the button at a key that nothing else uses, then set that as your hotkey.

**F13 through F20 are the keys to aim for.** Most Mac keyboards stop at F12, so these keys are usually sitting unused and nothing competes for them.

1. **Remap the button to F13 in your mouse software.** Most gaming mouse software can assign a keyboard key to a button. Assign F13 to the button you want to dictate with.
2. **Press the mouse button in the Recording hotkey box.** `F13` appears in the box and saves immediately.
3. **Try it.** Click into a text field and press the button. Recording starts.

### If your mouse software does not run on macOS

Several manufacturers have thin macOS support, and Razer's Synapse 3 does not run on macOS at all. Two ways around it:

- **Configure it on a Windows PC.** Many gaming mice store the mapping in onboard memory on the mouse itself, so a profile you set up on Windows keeps working once you plug the mouse into your Mac. Check whether your model has onboard memory before relying on this.
- **Remap on the Mac with a third party tool.** [Karabiner-Elements](https://karabiner-elements.pqrs.org) is a free keyboard customizer for macOS that can remap keys for one specific device. That last part matters: it can turn `1` coming from your mouse into F13 while leaving the `1` on your keyboard alone. Its bundled EventViewer also shows exactly what each button sends.

### Choosing the key

| Key you remap to | Worth choosing? |
|---|---|
| F13 to F20 | Best choice. Most Mac keyboards stop at F12, so nothing else is listening. |
| A letter or number | No. Your hotkey would fire every time you typed that character. |
| Right Option or another modifier | Works, but the button then behaves as that modifier everywhere. Holding it changes what your other keys and clicks do. |

### Buttons the box cannot capture

If nothing appeared in the **Recording hotkey** box, the button is sending
something EnviousWispr does not accept as a shortcut. That is usually one of two
things, and they are worth telling apart because only one of them is a dead end.

- **A real mouse click.** The scroll wheel click is the common case. It already
  opens links in new tabs and closes tabs in every browser, so taking it over for
  dictation costs you that.
- **A media key.** Buttons set to play, pause, volume or track skip send a
  different kind of event that the shortcut box does not read, even though they
  are not mouse clicks.

Either way the fix is the same: open your mouse software and assign the button a
keyboard key instead, F13 for preference, then follow the steps above. If your
software does not show you what the button is currently set to, the EventViewer
bundled with [Karabiner-Elements](https://karabiner-elements.pqrs.org) will.

### Which mode to use

Once the button is set as your hotkey it behaves like any other. Push to talk records while you hold the button, and toggle mode starts on one press and stops on the next. Toggle mode suits a mouse button well, because holding a mouse button down while you speak is more tiring than holding a key.
