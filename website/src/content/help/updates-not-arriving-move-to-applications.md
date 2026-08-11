---
title: "Updates Never Arrive: Move EnviousWispr to Applications"
description: "If EnviousWispr is running from Downloads it cannot update itself. Here is how to fix it in about thirty seconds."
category: "updates-and-source"
section: "Updates"
order: 3
keywords: ["no updates", "never updates", "stuck on old version", "cannot update", "update does nothing", "running from downloads", "move to applications", "translocated", "check for updates does nothing", "still on old version"]
related: ["auto-updates"]
updated: 2026-08-11
---
If EnviousWispr never seems to get a new version, the most likely reason is where it is running from rather than anything wrong with the app.

### Why this happens

When you download an app and open it straight from your Downloads folder, macOS does something protective: it runs the app from a hidden temporary copy instead of from the file you actually downloaded. Apple designed this so an app cannot quietly load other files that came down alongside it.

The side effect is that an app running this way cannot replace itself, which is exactly what updating requires. So EnviousWispr keeps working, but it stays on the version you first installed and can never fetch a newer one.

You will usually see this if you opened the app directly from the disk image, or from Downloads, without dragging it into Applications first.

### First, check what is already in Applications

Open your Applications folder and look for EnviousWispr.

- **If there is no copy there**, go straight to the steps below.
- **If there is a copy there**, open it and choose Check for Updates. If it reports a version the same as or newer than the one you have been using, that copy is the healthy one. Use it from now on, and delete the one in Downloads. Nothing else is needed.

This check matters because replacing a newer copy with an older one leaves you worse off than you started.

### Moving it across

1. Quit EnviousWispr.
2. Find the app. If you saved a disk image, the file in Downloads ends in `.dmg` and is not the app itself. Double-click it first, and a window opens showing the EnviousWispr icon next to an Applications folder.
3. Drag EnviousWispr into your Applications folder. If macOS asks whether to replace an existing copy, only say yes if you confirmed above that the existing copy is older.
4. Open EnviousWispr from Applications.

Dragging the app in Finder is the specific action that clears the restriction, which is why it works when other approaches do not.

### Checking it worked

Open EnviousWispr and choose Check for Updates. If it now tells you whether you are up to date, rather than doing nothing, you are set. From then on updates arrive on their own.

### If the app offers to move itself

Newer versions notice this situation on launch and offer to move themselves into Applications for you. Accepting that is safe, and it does the same thing as the steps above.

If that offer fails, read what it says before dragging the app across yourself. Some failures are about your Mac rather than the app, and a manual drag will not get past them either:

- **Not enough space.** Free some up first, then try again.
- **Another copy is already open.** Quit it first.
- **A different app is already in that spot.** Sort that out first.

There is one more that the message cannot always name for you. If your Mac is managed by someone else, or your account is not an administrator, the main Applications folder may not accept new apps at all. Finder will refuse the drag, or ask for a password you do not have. In that case, use your own personal Applications folder instead: in Finder choose **Go > Home**, make a folder called `Applications` there if one does not exist, and drag EnviousWispr into that. Updates work from there too.

Once the reason has been cleared, or you have used your personal Applications folder, the move will go through.

### One thing worth knowing

Because this problem prevents updates, a version containing a fix for it cannot reach you through the app. If you are reading this on an older version, the manual move above is the way out, and after that updates will flow normally.
