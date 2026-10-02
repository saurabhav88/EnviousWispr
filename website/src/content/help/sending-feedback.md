---
title: "Sending Feedback From the App"
description: "Tell us about a bug or an idea without leaving EnviousWispr: the bug button beside Record opens a short form, your draft is saved as you type, and an email is optional."
category: "troubleshooting"
section: "Getting Help"
order: 9
keywords: ["send feedback", "feedback", "report a bug", "bug report", "bug button", "ladybug", "feature request", "contact", "support", "reply", "suggestion", "include diagnostics", "diagnostics", "help check", "send greyed out", "send button disabled", "couldn't send", "solved don't send"]
related: ["what-data-is-collected", "source-code-and-contributing", "app-crashes-or-asr-engine-crashes", "privacy-overview"]
updated: 2026-10-02
deflection: "never_intervene"
---
Found a bug or have an idea? You can tell us from inside EnviousWispr. Every message you send reaches the team directly, and we read every one.

## How do I send feedback?

1. **Open the EnviousWispr window.** Click the EnviousWispr icon in the menu bar and choose **Settings**, or click EnviousWispr in the Dock.
2. **Click the bug button.** It sits at the top right of the window, beside **Record**. A small **Send feedback** form opens.
3. **Write what happened.** Describe what you saw, or what you would like EnviousWispr to do. The more specific, the better: which app you were dictating into, what you said, and what came out. A message can be up to 4,000 characters.
4. **Add your email if you want a reply.** The email field is optional. Leave it empty and your message is still sent, but we cannot write back.
5. **Choose whether to include diagnostics.** Tick **Include diagnostics** to attach a short record of your recent dictations, which helps us find the problem.
6. **Click Send.** When your message is sent, the form says **Thanks, it's on its way**. If you left your email, we reply there.

In recent versions, EnviousWispr may show you help pages before it sends your message. You then choose whether to send.

## What happens when I click Send?

In recent versions, EnviousWispr first looks for help pages that might answer your message. The form says **Checking help articles…** for a few seconds at most. Your message is sent to look for those pages, so [What Data Is Collected](/help/what-data-is-collected/) explains where it goes.

- **If it finds help**, you see up to three short answers from the help center, each with a **Read the full article** link.
- **To send your message anyway**, click **Send my message**. Your report is sent exactly as you wrote it, with your email and diagnostics if you added them. It also notes which answers you marked solved.
- **To change your message**, click **Edit message**. No report is sent, and your draft stays as it was.
- **To come back later**, close the answers. No report is sent, and a dot on the bug icon shows your message is waiting. Click the bug icon to pick up where you left off. If you quit EnviousWispr first, your draft is kept and the check runs again when you click **Send**.
- **If nothing fits, or the check fails**, your report is sent as usual, with no extra step.

## How do I mark a problem solved so nothing is sent?

If your message has more than one part, you can mark a matched part **Solved** when that option appears. If the app matched every part of your message to an answer, and you marked them all, you can click **Solved, don't send** (or **All solved, don't send**). No report is sent and your draft is cleared. Clicking **Send** has already sent your message text through our website to TypeSafe for the help check.

Some answers, such as pages about crashes or privacy, are shown for reference only and cannot be marked solved. Click **Send my message** if you still want to report the issue.

## Why is there no Solved button?

Solved marks, **Solved, don't send** and **All solved, don't send** need Apple Intelligence, which works on macOS 26 or later. EnviousWispr uses it on your Mac to split your message into separate problems. Without it, you can still see answers, and **Send my message** still sends your report.

## What does Include diagnostics send?

The **Include diagnostics** box attaches one file to your report. It holds a record of up to 20 of your most recent dictations kept on your Mac, such as which engine ran, how long each step took and whether the paste worked. When the app has it, the file also holds a random ID that links the report to your earlier usage data. When the file holds that ID, the report also carries it as a label, so we can find that data. It never contains your audio or the words you dictated.

- **It follows your usage setting.** The box starts ticked when **Share usage metrics** is on and unticked when it is off. It never remembers your last choice, so each report is your decision.
- **You can read it first.** With the box ticked, click **Preview diagnostics** to see the whole file exactly as it will be sent.
- **Nothing to attach.** If the form says **No diagnostics available**, the report is sent without a file. Your message still goes through.
- **Wait for it to load.** While the form says **Loading diagnostics...** with the box ticked, **Send** waits until the file is ready. Untick the box to send straight away.
- **If you change the setting while the form is open.** The box resets to match, and the preview reloads, so you always see what you send.

Whatever you type into the message itself is sent as you wrote it, so leave out anything you would rather keep to yourself.

## Is my draft saved?

Yes. What you type is saved on your Mac as you type it. Close the form, or quit EnviousWispr, and your draft is still there the next time you open it. It clears when EnviousWispr saves the report for delivery, or when you confirm that the help solved everything.

## Can I send feedback while offline?

Yes. The form says **You're offline. We'll send it when you're back online.** The report waits on your Mac, even through a restart, and is sent once you are connected again.

## Feedback says "Couldn't send"

If the form says **Couldn't send. Email hello@enviouslabs.co**, your draft stays in the form. Copy it into an email to hello@enviouslabs.co.

The same applies if it says **Too much feedback is waiting to send. Email hello@enviouslabs.co**. That means many earlier reports are still waiting for a connection.

If the form says **Some saved feedback could not be sent. It remains on this Mac.**, an earlier report could not be delivered. It stays saved on your Mac. Email hello@enviouslabs.co if it matters.

## The Send button is greyed out

**Send** stays greyed out in these cases:

- The message is empty.
- The message is too long. The form says **Maximum 4,000 characters**. Some emoji count as more than one character, so shorten the message until the warning goes away.
- The email address is not valid. The form says **Enter a valid email address**. Fix it or leave the field empty.
- **Include diagnostics** is ticked and the diagnostics are still loading. Wait a moment, or untick the box.
- A report is still being saved. Wait a moment.

## What do you receive when I send feedback?

If you choose to send your report, we receive the message you write, your email address only if you add it, and your app and macOS versions. If you ticked **Include diagnostics**, we also receive the diagnostics file. Your report never includes your recordings or your History.

The report also carries the result of the help check as labels: which help pages and sections matched, which parts you marked solved, how the check ended, and the versions of the app, the help content and the help check. These labels never contain your own words. With usage metrics on when you send, and when the app has the random ID that links the report to your usage data, the report carries that ID as a label, even if you do not include diagnostics. Whenever an included diagnostics file contains that ID, the report also carries it as a label, even with usage metrics off. With usage metrics off and no diagnostics included, no such ID is sent. The crash-report switch never changes what a report contains.

To look for help before you send, recent versions send the text of your message (never your email address or diagnostics) through our website to TypeSafe, an AI service that works on our behalf. This happens when you click **Send**, before you decide whether to send the report. It applies even if the help solves everything and no report is sent. We do not store that text in this step, and TypeSafe does not use your message to train its models.

See [What Data Is Collected](/help/what-data-is-collected/) for the full picture.

## Other ways to reach us

You can also open an issue on [GitHub Issues](https://github.com/saurabhav88/EnviousWispr/issues), which is public, or use the [contact page](/contact/).
