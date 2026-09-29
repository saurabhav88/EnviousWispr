---
title: "What Data Is Collected"
description: "What stays on your Mac, what the app never sends, and what it does collect."
category: "privacy-and-security"
section: "Privacy"
order: 2
keywords: ["what data", "analytics", "telemetry", "collected", "do you see my text", "do you store", "opt out", "turn off", "tracking", "crash reports", "usage metrics", "diagnostics"]
related: ["privacy-overview"]
updated: 2026-09-29
deflection: "show_but_always_send"
---
EnviousWispr collects anonymous usage data and crash reports, and you can turn either one off. Nothing you say is part of that. Your audio never reaches Envious Labs, the company that makes the app, and the app never sends us your dictations or transcripts unless you include them in a feedback report yourself.

### What stays on your Mac

Your dictations and transcripts are saved to your History so you can find them later. They sit in your user folder, and Envious Labs never receives a copy.

[Escape Recovery](/help/escape-recovery/) is on unless you switch it off, so a recording you cancel with your keybind is transcribed and held in that same folder, letting you paste it back or press Keep to make it permanent. It stays available for 24 hours. After that it is removed while the app is running, or the next time you launch it. Its audio is deleted once its text is safely saved, exactly as with any other dictation.

While you dictate, the app keeps an encrypted backup of the recording. Once your text is safely saved, the app requests deletion of that backup. If the app quits first, EnviousWispr makes one recovery attempt the next time it runs, then requests deletion whether that recovery succeeded or failed.

Your custom words, settings, and API keys live here too. They stay on your Mac unless you turn on cloud polish, which is covered below.

The app also keeps a short diagnostics diary here, described below. It stays on your Mac unless you choose to attach it to a feedback report.

### What the app never sends automatically

None of these is ever attached to feedback. Anything you type into a feedback report yourself is covered below.

- Your audio
- Your dictations and transcripts, before or after polish
- Your custom words
- The text around your cursor
- Your API keys
- Your name or email address, unless you choose to include either in a feedback report (below)

### What the app does collect

The app collects anonymous usage and crash data. That data shows whether a release broke dictation on a particular macOS version, or whether anyone ever opens a setting that took a month to build. Both are on by default, and you can turn either one off.

The app records how you use it, never what you said. There is no account, and nothing in the data names you, although each installation gets a random ID so that one Mac counts as one user. The privacy policy has the full detail.

### Turning usage data or crash reports off

Two switches control this, in the **Privacy** section of **Settings > Permissions** in EnviousWispr. Each one works on its own.

| Switch | What it covers | When a change applies |
| :--- | :--- | :--- |
| **Share usage metrics** | Anonymous counts and timings: that a dictation happened, how long it took, which engine ran. | Right away. Turning it off stops collection at once. If the app starts with it off, the usage service does not start at all. |
| **Send crash reports** | Reports about crashes and errors, and a short note that the app is running, used to count sessions without a crash. | The next time EnviousWispr starts. After you change it, the switch shows **Restart now** so you can apply it straight away. If the app starts with it off, the crash-reporting service does not start at all. |

A few details are worth knowing before you rely on either switch:

- **Something already on its way.** When you turn usage metrics off, a report that was already being sent may still arrive. Usage data that was queued but not yet sent stays on your Mac and may be sent if you turn the switch back on.
- **Crash sessions have their own ID.** When crash reports are on, the short "app is running" notes sent to Sentry, the crash-reporting service, keep Sentry's random installation ID, even with usage metrics off. Turning off crash reports stops these notes after a restart.
- **Reports saved before you turned it off.** A crash report the app saved but had not sent yet stays on your Mac while crash reports are off. It is not deleted, and it may be sent if you turn crash reports back on.
- **Feedback still works.** With crash reports off, you can still send feedback, and feedback you already sent may be retried.
- **The app still uses the network.** With both switches off, EnviousWispr still checks for updates, downloads the models you choose, sends your text to a cloud polish provider if you picked one, and, when you press Send on a feedback report, first looks for help pages (in recent versions) and then sends the report if you choose to.
- **Only the app.** These switches cover the app. They do not change anything on this website.

### The diagnostics diary

The app keeps a private, content-free record of up to 20 of your most recent dictations on your Mac: which engine ran, how long each step took, whether the paste worked, the app you dictated into, and a random ID and time for each dictation. It never holds your audio or your words.

Entries older than 7 days are removed when the app starts, when it adds an entry, and when the diary is read. Nothing is removed while the app is closed, and a storage error can delay this cleanup.

The diary is kept whatever the two switches say, because it never leaves your Mac on its own. It is sent only if you tick **Include diagnostics** in a feedback report.

### Feedback you choose to send

If you use Send Feedback, the bug button next to Record in the app window, and choose to send your report, we receive the message you write and, only if you add it, your email address so we can reply. It also carries your app and macOS versions. Your feedback is sent only after you press Send and, in recent versions, only if you still choose to send it when help is shown; no recordings or History are attached. Feedback is separate from the two switches above: they never change what a report contains or whether it is sent. The privacy policy covers how long your feedback is kept and how to have it deleted. In recent versions, pressing Send first sends the text of your message, without your email address or diagnostics, through our website to TypeSafe, an AI service that works on our behalf, to find help pages that might answer it. This happens before you decide whether to send the report, so it applies even if the help solves everything and no report is sent. TypeSafe does not use your message to train its models.

**Include diagnostics.** The feedback form has an **Include diagnostics** box. It starts ticked when usage metrics are on and unticked when they are off, and it never remembers your last choice. If you tick it, the report also carries one file, `enviouswispr-diagnostics.json`: the diagnostics diary and, when the app has it, the random ID that links the report to your earlier usage data. **Preview diagnostics** shows you the whole file before you send. If the diary is empty, nothing is attached. With the box unticked, no file is attached.

**Waiting to send.** When your report is sent, it is saved on your Mac first. It is sent as soon as the app can reach the internet, and it waits through restarts and changes to the switches until it arrives. A report that cannot be delivered at all stays on your Mac, and the feedback form tells you.

### Where your text goes if you use cloud AI polish

Polish runs on your Mac by default. If you choose OpenAI, Gemini, or Claude instead, you add your own API key. Your text is then sent to that provider, along with your custom words and the name of the app you are dictating into, so the model gets your spellings and tone right. Audio is never sent. The app tells you this when you set it up. That connection is your account with that company, governed by their terms.

Ollama works in two ways, and only one of them keeps your text on your Mac. A model you download runs on your Mac and sends nothing anywhere. A hosted model runs on Ollama's servers, so your text goes to Ollama in the same way it would go to any other cloud provider. EnviousWispr lists the two kinds under separate headings so you can tell which you are picking.

Envious Labs is not in the middle of any of these requests. Everything goes straight from your Mac to the provider, so Envious Labs never sees it either way.
