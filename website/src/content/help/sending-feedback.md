---
title: "Sending Feedback From the App"
description: "Tell us about a bug or an idea without leaving EnviousWispr: the bug button beside Record opens a short form, your draft is saved as you type, and an email is optional."
category: "troubleshooting"
section: "Getting Help"
order: 9
keywords: ["send feedback", "feedback", "report a bug", "bug report", "bug button", "ladybug", "feature request", "contact", "support", "reply", "suggestion", "include diagnostics", "diagnostics"]
related: ["what-data-is-collected", "source-code-and-contributing", "app-crashes-or-asr-engine-crashes", "privacy-overview"]
updated: 2026-09-29
deflection: "never_intervene"
---
Found a bug or have an idea? You can tell us from inside EnviousWispr. Every message you send reaches the team directly, and we read every one.

### Sending a message

**Open the EnviousWispr window.** Click the EnviousWispr icon in the menu bar and choose Settings, or click EnviousWispr in the Dock.

**Click the bug button.** It sits at the top right of the window, beside **Record**. A small **Send feedback** form opens.

**Write what happened.** Describe what you saw, or what you would like EnviousWispr to do. The more specific, the better: which app you were dictating into, what you said, and what came out. A message can be up to 4,000 characters.

**Add your email if you want a reply.** The email field is optional. Leave it empty and your message is still sent; we just cannot write back.

**Choose whether to include diagnostics.** Tick **Include diagnostics** to attach a short record of your recent dictations, which helps us find the problem. See the section below.

**Click Send.** When your message is sent, the form says **Thanks, it's on its way**. If you left your email, we reply there. In recent versions, EnviousWispr may first show you help from the help center, described below, and you choose whether to send.

### Help before you send

In recent versions, when you click **Send**, EnviousWispr first looks for help pages that might answer your message. The form says **Checking help articles…** for a few seconds at most.

- **If it finds help**, you see up to three short answers from the help center, each with a **Read the full article** link. If your message had more than one part, you can mark a matched part **Solved** when that option appears.
- **To send your message**, click **Send my message**. Your report is sent exactly as you wrote it, with your email and diagnostics if you added them, and it notes which answers you marked solved.
- **If everything is solved**, and the app could match every part of your message to an answer, you can click **Solved, don't send** (or **All solved, don't send**). Nothing is sent and your draft is cleared.
- **To change your message**, click **Edit message**. Nothing is sent and your draft stays as it was.
- **To come back later**, close the answers. Nothing is sent, and a dot on the bug icon shows your message is waiting. Click the bug icon to pick up where you left off. If you quit EnviousWispr first, your draft is kept and the check runs again when you click **Send**.
- **If nothing fits, or the check fails**, your report is sent as usual, without any extra step.

Some answers, such as pages about crashes or privacy, are shown for reference only and can't be marked solved. Click **Send my message** if you still want to report the issue.

### Include diagnostics

The **Include diagnostics** box attaches one file to this report: a record of up to 20 of your most recent dictations kept on your Mac, such as which engine ran, how long each step took and whether the paste worked, plus, when the app has it, a random ID that links the report to your earlier usage data. It never contains your audio or the words you dictated.

- **It follows your usage setting.** The box starts ticked when **Share usage metrics** is on and unticked when it is off. It never remembers your last choice, so each report is your decision.
- **You can read it first.** With the box ticked, open **Preview diagnostics** to see the whole file exactly as it will be sent.
- **Nothing yet to attach.** If the form says **No diagnostics available**, the report is sent without a file. Your message still goes through.
- **Wait for it to load.** While the form says **Loading diagnostics...** with the box ticked, **Send** waits until the file is ready. Untick the box to send straight away.
- **If you change the setting while the form is open.** The box resets to match, and the preview reloads, so you always see what you send.

Whatever you type into the message itself is sent as you wrote it, so leave out anything you would rather keep to yourself.

### Your draft is kept

What you type is saved on your Mac as you type it. Close the form, or quit EnviousWispr, and your draft is still there the next time you open it. It clears when EnviousWispr saves the report for delivery, or when you confirm that the help solved everything.

### If you are offline

You can send feedback without an internet connection. The form says **You're offline. We'll send it when you're back online.** The report waits on your Mac, even through a restart, and is sent once you are connected again.

### If it cannot send

If the form says **Couldn't send. Email hello@enviouslabs.co**, your draft stays in the form, so you can copy it into an email to hello@enviouslabs.co. The same applies if it says **Too much feedback is waiting to send**, which means many earlier reports are still waiting for a connection.

If the form says **Some saved feedback could not be sent. It remains on this Mac.**, an earlier report could not be delivered. It stays saved on your Mac; email hello@enviouslabs.co if it matters.

If **Send** stays greyed out, check the email address or leave the field empty.

### What we receive

If you choose to send your report, we receive the message you write, your email address only if you add it, and your app and macOS versions. If you ticked **Include diagnostics**, we also receive the diagnostics file described above. Nothing else rides along, and the usage and crash-report switches never change what a report contains. It never includes your recordings or your History. See also [what data is collected](/help/what-data-is-collected/).

To look for help before you send, recent versions send the text of your message, without your email address or diagnostics, through our website to TypeSafe, an AI service that works on our behalf. This happens when you click **Send**, before you decide whether to send the report, so it applies even if the help solves everything and no report is sent. TypeSafe does not use your message to train its models.

### Other ways to reach us

You can also open an issue on [GitHub Issues](https://github.com/saurabhav88/EnviousWispr/issues), which is public, or use the [contact page](/contact/).
