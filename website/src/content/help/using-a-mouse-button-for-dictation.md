---
title: "Using a Mouse Button for Dictation"
description: "Start dictation from a side button on a gaming mouse by making the button send a keyboard key."
category: "recording-and-keybinds"
section: "Recording"
order: 7
keywords: ["mouse", "mouse button", "gaming mouse", "side buttons", "thumb buttons", "razer", "naga", "logitech", "mmo mouse", "extra buttons", "bind mouse button", "middle click", "scroll wheel click", "start dictation with mouse", "hotkey on mouse", "keybind on mouse", "bind mouse to keybind", "nothing appears in keybind box", "f13", "karabiner"]
related: ["customizing-your-keybind"]
updated: 2026-09-29
deflection: "can_resolve"
---
Most extra buttons on a gaming mouse can start dictation. The **Keybinds** page only accepts keyboard keys, so you cannot pick a mouse button from a list. But those extra buttons usually send keyboard keys already, and EnviousWispr can use them.

### Find out what my mouse button sends

The keybind box shows exactly what EnviousWispr receives from a button.

1. **Open Keybinds.** Click the EnviousWispr icon in your menu bar, choose **Open EnviousWispr**, and go to **Keybinds**.
2. **Select the keybind box.** Click the keys field in the **Start / stop recording** row.
3. **Press one of the extra buttons on your mouse.** Use a side button or a thumb button, not left or right click.

Whatever appears in the box is what that button sends.

| What appears in the box | What it means | What to do |
|---|---|---|
| `F13`, or another key you never type | The button is already sending an unused key | Nothing more. It saves, and you are done. |
| A letter, number or punctuation mark | The button sends a key you type with | Remap it first, or your keybind fires every time you type that character. |
| A modifier such as Right Option | The button is acting as a modifier | It works, but the button then acts as that modifier everywhere. Holding it changes what your other keys and clicks do. |
| Nothing at all | The button sends something EnviousWispr cannot bind | See the section on buttons the box cannot capture. |

A twelve button thumb grid often sends the number row, so the buttons come through as `1`, `2`, `3` and so on. Every mouse is different, so check yours.

Pressing the button in an ordinary text field is a quicker rough check, but it cannot tell you everything. A button set to F13, an arrow key or a modifier types no character. Silence in a text field looks the same as a button that sends nothing. The keybind box tells the two apart.

### Make a mouse button send a key nothing else uses

Sending `4` is not useful on its own. If you set `4` as your keybind, it would swallow that key everywhere you type. Point the button at a key nothing else uses, then set that key as your keybind.

**F13 through F20 are the best choice.** Most Mac keyboards stop at F12, so these keys sit unused and nothing competes for them. A letter or number is a poor choice, because your keybind would fire every time you typed that character.

1. **Remap the button to F13 in your mouse software.** Most gaming mouse software can assign a keyboard key to a button. Assign F13 to the button you want to dictate with.
2. **Press the mouse button in the Start / stop recording field.** `F13` appears in the field and saves immediately.
3. **Try it.** Click into a text field and press the button. Recording starts.

### My mouse software does not run on macOS

Several manufacturers have thin macOS support, and Razer's Synapse 3 does not run on macOS at all. You have two ways around it:

- **Configure it on a Windows PC.** Many gaming mice store the mapping in memory on the mouse itself, so a profile you set up on Windows keeps working once you plug the mouse into your Mac. Check whether your model stores its mapping before relying on this.
- **Remap on the Mac with a third party tool.** [Karabiner-Elements](https://karabiner-elements.pqrs.org) is a free keyboard customizer for macOS that can remap keys for one specific device. It can turn `1` coming from your mouse into F13 while leaving the `1` on your keyboard alone. Its bundled EventViewer also shows exactly what each button sends.

### Nothing appears in the keybind box

If nothing appeared in the **Start / stop recording** field, the button is sending something EnviousWispr does not accept as a keybind. That is usually one of two things:

- **A real mouse click.** The scroll wheel click is the common case. It already opens links in new tabs and closes tabs in every browser, so taking it over for dictation costs you that.
- **A media key.** Buttons set to play, pause, volume or track skip send a different kind of event that the keybind box does not read, even though they are not mouse clicks.

Either way, the fix is the same. Open your mouse software and assign the button a keyboard key instead, F13 for preference, then open **Keybinds**, click the keys field in the **Start / stop recording** row and press the mouse button. If your software does not show what the button is currently set to, the EventViewer bundled with [Karabiner-Elements](https://karabiner-elements.pqrs.org) will.

### Which recording mode suits a mouse button

Once the button is your keybind, it behaves like any other. Push to talk records while you hold the button. Toggle mode starts on one press and stops on the next. Toggle mode suits a mouse button well, because holding a mouse button down while you speak is more tiring than holding a key. See [Customizing Your Keybind](/help/customizing-your-keybind/) for more on keys.
