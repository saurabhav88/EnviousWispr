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

### The fix

1. Quit EnviousWispr.
2. Open your Downloads folder, or wherever you saved the app.
3. Drag EnviousWispr into your Applications folder. If macOS asks whether to replace an existing copy, say yes.
4. Open EnviousWispr from Applications.

That is it. Dragging the app in Finder is the specific action that clears the restriction, which is why it works when other approaches do not.

### Checking it worked

Open EnviousWispr and choose Check for Updates. If it now tells you whether you are up to date, rather than doing nothing, you are set. From then on updates arrive on their own.

### If the app offers to move itself

Newer versions notice this situation on launch and offer to move themselves into Applications for you. Accepting that is safe, and it does the same thing as the steps above.

If that offer fails and tells you nothing was moved, drag the app across yourself using the steps above. It works in cases the automatic move cannot handle, such as a full disk, or an Applications folder your account is not allowed to write to.

### One thing worth knowing

Because this problem prevents updates, a version containing a fix for it cannot reach you through the app. If you are reading this on an older version, the manual drag above is the way out, and after that updates will flow normally.
