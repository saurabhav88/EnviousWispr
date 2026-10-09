---
title: "What Data Is Collected"
description: "What stays on your Mac, what the app never sends, and what it does collect."
category: "privacy-and-security"
section: "Privacy"
order: 2
keywords: ["what data", "analytics", "telemetry", "collected", "do you see my text", "do you store", "opt out", "turn off", "tracking", "crash reports", "usage metrics", "diagnostics", "send feedback privacy", "help check", "TypeSafe", "share usage metrics"]
related: ["privacy-overview"]
updated: 2026-10-09
deflection: "show_but_always_send"
---
EnviousWispr collects anonymous usage data and crash reports, and you can turn either one off. Nothing you say is part of that. Usage data can include a Settings search that found nothing, after the app filters it. Your audio never reaches Envious Labs, the company that makes the app. The app never sends us your dictations or transcripts, unless you type them into a feedback message yourself.

## What stays on my Mac?

Your dictations and transcripts are saved to your History so you can find them later. They sit in your user folder, and Envious Labs never receives a copy.

Your custom words, settings, and API keys live there too. An API key is a private password that lets the app use an AI service under your own account. These stay on your Mac unless you turn on cloud polish, which sends your text to the AI company you pick.

The app also keeps a short diagnostics diary on your Mac. It stays there unless you choose to attach it to a feedback report.

## What happens to a recording I cancel?

[Escape Recovery](/help/escape-recovery/) is on unless you switch it off. A recording you cancel with your keybind is transcribed and held in your user folder, so you can paste it back or press Keep to make it permanent. It stays available for 24 hours. After that it is removed while the app is running, or the next time you launch it. Its audio is deleted once its text is safely saved, as with any other dictation.

## Is my recording backed up?

While you dictate, the app keeps an encrypted backup of the recording on your Mac. Once your text is safely saved, the app requests deletion of that backup. If the app quits first, EnviousWispr makes one recovery attempt the next time it runs, then requests deletion whether that attempt worked or not.

## What does the app never send?

None of these is ever included in usage data or crash reports, or attached to a feedback report. (If you choose cloud polish, your text goes directly to the provider you picked, under your own key.)

- Your audio
- Your dictations and transcripts, before or after polish, including files you transcribe
- Your History
- Your custom words and snippets
- The text around your cursor, or any other text on your screen
- Your API keys
- Your name or email address, unless you choose to include either in a feedback report

Two kinds of text you type do leave your Mac. A feedback message is sent only when you choose to send it, and pressing Send also runs a help check on it. In recent versions, the words of a Settings search that finds nothing are sent with usage data, as explained in [Does the app send what I type in Settings search?](#does-the-app-send-what-i-type-in-settings-search).

## What does the app collect?

The app collects anonymous usage and crash data. That data shows whether a release broke dictation on a particular macOS version, or whether anyone ever opens a setting that took a month to build. Both are on by default, and you can turn either one off.

The app records how you use it, never what you said. There is no account, and nothing in the data names you. Each installation gets a random ID, so that one Mac counts as one user. The privacy policy has the full detail.

If the part of the app that listens for your keybind has trouble, for example macOS keeps switching it off, usage data includes counts of how often that happened and whether it recovered. These shortcut-health reports never include which keys you pressed.

### Does the app send what I type in Settings search?

In recent versions, yes, in two cases only: when a search in Settings finds no setting, or when you skip its results and pick a page from the sidebar instead. The app then sends the last search you typed, in lower case, so we can teach the search the words people use. It never sends each keystroke. It does this only if **Share usage metrics** was on when you started typing and stayed on.

The search is checked on your Mac first. A search shorter than 3 or longer than 80 characters, or longer than 320 bytes of text, is not sent, and neither is one that contains an @ sign, looks like a web address, has seven or more digits, or looks like an API key or access token.

If you pick a result, or close a search that still had results, the app never sends the words. Every search report, with or without the words, says how the search ended, how many results it had, the app language and, when available, how long the app took to find related settings. If you picked a page from the sidebar, it also names that page and tab.

## How can I check this myself?

EnviousWispr is open source, so you do not have to take our word for any of this. The code that decides what leaves your Mac is public:

- [`ObservabilityBootstrap.swift`](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprServices/ObservabilityBootstrap.swift) starts or skips the usage and crash-reporting services, depending on your two switches.
- [`TelemetryService.swift`](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprServices/TelemetryService.swift) builds the usage events the app sends. The PostHog library adds its standard lifecycle events for when the app is installed, updated, or launched.
- [`SettingsSearchFinished.swift`](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprServices/SettingsSearchFinished.swift) decides which Settings search text may be sent, and drops any that looks private.
- [`SentryEventSanitizer.swift`](https://github.com/saurabhav88/EnviousWispr/blob/main/Sources/EnviousWisprObservabilityCore/SentryEventSanitizer.swift) checks crash reports before they are sent. It removes email addresses, common API-key formats, your Mac user name in file paths, and any text longer than 100 characters that is not a web address.

You can also watch the traffic with a network monitor. Usage data goes to PostHog (`us.i.posthog.com`) and crash reports go to Sentry (an `ingest.us.sentry.io` address). With a switch off, the app stops sending that kind of data. Feedback you choose to send still goes to Sentry, whatever the switches say.

## How do I turn off usage data or crash reports?

Two switches control this, in **App Settings** > **Privacy**. Each one works on its own.

| Switch | What it covers | When a change applies |
| :--- | :--- | :--- |
| **Share usage metrics** | Anonymous usage, settings, and timing data: that a dictation happened, how long it took, which engine ran, which app it went into, and which settings are on. Also the words of a Settings search that found nothing or that you skipped for the sidebar. | Right away. Turning it off stops collection at once. If the app starts with it off, the usage service does not start at all. |
| **Send crash reports** | Reports about crashes and errors, and a short note that the app is running, used to count sessions without a crash. | The next time EnviousWispr starts. After you change it, the switch shows **Restart now** so you can apply it straight away. If the app starts with it off, the crash-reporting service does not start at all. |

## What still happens after I turn a switch off?

- **Something already on its way.** When you turn usage metrics off, a report that was already being sent may still arrive. Usage data that was queued but not yet sent stays on your Mac and may be sent if you turn the switch back on.
- **Crash sessions have their own ID.** When crash reports are on, the short "app is running" notes sent to Sentry, the crash-reporting service, keep Sentry's random installation ID, even with usage metrics off. Turning off crash reports stops these notes after a restart.
- **Reports saved before you turned it off.** A crash report the app saved but had not sent yet stays on your Mac while crash reports are off. It is not deleted, and it may be sent if you turn crash reports back on.
- **Feedback still works.** With crash reports off, you can still send feedback, and feedback you already sent may be retried.
- **The app still uses the network.** With both switches off, EnviousWispr still checks for updates, downloads the models you choose, and sends your text to a cloud polish provider if you picked one. When you press Send on a feedback report, it also runs the help check and then sends the report if you choose to.
- **Only the app.** These switches cover the app. They do not change anything on this website.

## What is the diagnostics diary?

The diary is a private, content-free record of up to 20 of your most recent dictations, kept on your Mac. It notes which engine ran, how long each step took, whether the paste worked, the app you dictated into, and a random ID and time for each dictation. It never holds your audio or your words.

Entries older than 7 days are removed when the app starts, when it adds an entry, and when the diary is read. Nothing is removed while the app is closed, and a storage error can delay this cleanup.

The diary is kept whatever your two switches say, because it never leaves your Mac on its own. It is sent only if you tick **Include diagnostics** in a feedback report.

## What does a feedback report send?

If you use Send Feedback (the bug button next to Record in the app window) and choose to send your report, we receive the message you write. We receive your email address only if you add it, so we can reply. The report also carries your app and macOS versions. No recordings or History are attached.

Your two switches never decide whether a report is sent. With usage metrics on when you send, and when the app has the random ID that links the report to your usage data, the report carries that ID as a label, even without diagnostics. Whenever an included diagnostics file contains that ID, the report also carries it as a label, even with usage metrics off. With usage metrics off and no diagnostics included, no such ID is sent. The crash-report switch never changes what a report contains. The privacy policy covers how long your feedback is kept and how to have it deleted.

In recent versions, a sent report also carries the result of the help check as labels: which help pages matched, which parts you marked solved, the outcome, and the app version. It never carries your own words in those labels.

## Does my message go anywhere before I send it?

In recent versions, pressing **Send** starts a help check before anything is sent to us as a report.

- **What is sent.** Your message text, the parts of it your Mac picked out as separate problems, and the versions of the app and the help check. Your email address and diagnostics are not part of it.
- **Where it goes.** Through our website, enviouswispr.com, to TypeSafe, an AI service that works on our behalf. TypeSafe looks for help pages that might answer your message.
- **When it happens.** As soon as you press **Send**, before you decide whether to send the report. It happens even if the help solves everything and you choose not to send the report.
- **What we keep.** We do not store the text in this step. TypeSafe does not use your message to train its models.

See [Sending Feedback From the App](/help/sending-feedback/) for what you see and choose.

## What does Include diagnostics attach?

The feedback form has an **Include diagnostics** box. It starts ticked when usage metrics are on and unticked when they are off, and it never remembers your last choice.

If you tick it, the report also carries one file, `enviouswispr-diagnostics.json`. The file holds the diagnostics diary and, when the app has it, the random ID that links the report to your earlier usage data. When the attached file contains that ID, the report also carries it as a label. **Preview diagnostics** shows you the whole file before you send. If the diary is empty, nothing is attached. With the box unticked, no file is attached.

## What if I send feedback while offline?

Your report is saved on your Mac first. It is sent as soon as the app can reach the internet, and it waits through restarts and changes to the switches until it arrives. A report that cannot be delivered at all stays on your Mac, and the feedback form tells you.

## Does cloud AI polish send my text?

Only if you choose it. Polish runs on your Mac by default. If you choose OpenAI, Gemini, or Claude instead, you add your own API key. Your text is then sent to that provider, along with your custom words and the name of the app you are dictating into, so the model gets your spellings and tone right. Audio is never sent. The app tells you this when you set it up. That connection is your account with that company, governed by their terms.

Ollama works in two ways, and only one of them keeps your text on your Mac. A model you download runs on your Mac and sends nothing anywhere. A hosted model runs on Ollama's servers, so your text goes to Ollama in the same way it would go to any other cloud provider. EnviousWispr lists the two kinds under separate headings so you can tell which you are picking.

Envious Labs is not in the middle of any of these requests. Everything goes straight from your Mac to the provider, so Envious Labs never sees it either way.
