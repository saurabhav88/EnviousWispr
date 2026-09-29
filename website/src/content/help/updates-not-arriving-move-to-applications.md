---
title: "Updates Never Arrive: Move EnviousWispr to Applications"
description: "If EnviousWispr is running from Downloads or the disk image it cannot update itself. Move it to Applications and updates work again."
category: "updates-and-source"
section: "Updates"
order: 3
keywords: ["no updates", "never updates", "stuck on old version", "cannot update", "update does nothing", "running from downloads", "move to applications", "translocated", "check for updates does nothing", "still on old version", "can't be updated if it's running from the location it was downloaded to", "opened from a read-only or a temporary location"]
related: ["auto-updates"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
If EnviousWispr never gets a new version, it is most likely running from Downloads or the disk image instead of your Applications folder. The fix is to quit the app, drag EnviousWispr into Applications, and open it from there.

### Why EnviousWispr cannot update

When you open an app straight from your Downloads folder, macOS runs it from a hidden temporary copy instead of the file you downloaded. Apple does this so an app cannot quietly load other files that came down alongside it.

An app running this way cannot replace itself, and updating means replacing itself. EnviousWispr keeps working, but it stays on the version you first installed.

This usually happens when you opened the app from the disk image, or from Downloads, without dragging it into Applications first. If you choose **Check for Updates**, Sparkle, the update tool inside the app, shows this message: "EnviousWispr can't be updated if it's running from the location it was downloaded to." Opened from the disk image, you may see "can't be updated because it was opened from a read-only or a temporary location" instead.

### Check what is already in Applications

Open your Applications folder and look for EnviousWispr.

- **No copy there.** Go on to the steps for moving it across.
- **A copy is there.** Open it and choose **Check for Updates**. If it reports the same version as you have been using, or a newer one, that copy is the healthy one. Use it from now on and delete the one in Downloads. Nothing else is needed.

Do this check first. Replacing a newer copy with an older one leaves you worse off.

### Move EnviousWispr to Applications

1. Quit EnviousWispr.
2. Find the app. If you saved a disk image, the file in Downloads ends in `.dmg` and is not the app itself. Double-click it, and a window opens showing the EnviousWispr icon next to an Applications folder.
3. Drag EnviousWispr into your Applications folder. If macOS asks whether to replace an existing copy, compare the two versions first and replace it only if the copy you are moving is newer.
4. Open EnviousWispr from Applications.

Dragging the app in Finder is the action that clears the restriction, which is why it works when other approaches do not.

### Check that updates work now

Open EnviousWispr and choose **Check for Updates**. If it tells you whether you are up to date, instead of doing nothing, you are set. From then on updates arrive on their own.

### The app offers to move itself, or the move fails

Newer versions notice this situation when they open and offer to move themselves into Applications. Accepting is safe. It moves EnviousWispr into an Applications folder and reopens it from there. If /Applications does not accept new apps from your account, the offer uses your personal Applications folder instead, and it never asks for a password.

If the offer fails, read what it says before you drag the app across yourself. Some failures come from your Mac, and a manual drag will not get past them:

- **Not enough space.** Free some up, then try again.
- **Another copy is already open.** Quit it first.
- **A different app is already in that spot.** Sort that out first.

### Finder will not let me drag into Applications

If your Mac is managed by someone else, or your account is not an administrator, the main Applications folder may refuse new apps. Finder refuses the drag, or asks for a password you do not have. Use your own personal Applications folder instead:

1. In Finder, choose **Go** > **Home**.
2. Make a folder called `Applications` there if one does not exist.
3. Drag EnviousWispr into it.

Updates work from there too.

### I am on an old version and the fix never reached me

Because this problem blocks updates, a version containing a fix for it cannot reach you through the app. If you are on an older version, quit EnviousWispr, drag it into Applications in Finder without replacing a newer copy, and open it from there. After that, updates arrive normally.
