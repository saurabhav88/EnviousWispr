EnviousWispr stores your transcriptions on your Mac, and it keeps a safety copy of your recording so a crash cannot cost you your words. Neither is ever sent to Envious Labs, and neither is ever included in our usage analytics. The app does send other information, which is described below and in our privacy policy.

### What Stays On Your Mac

* **Your transcriptions.** Saved to your local transcript history so you can find them again. They live in your user folder and are never uploaded.
* **A safety copy of your recording.** Deleted as soon as your dictation is safely saved to your transcript history. It survives only when the app could not finish the job: a crash, a force quit, a power loss, or a save that failed. When that happens EnviousWispr recovers your words for you and then removes the file. It is encrypted on disk, and you can switch it off in Settings if you would rather no audio ever touched the disk.
* **Your custom words, writing styles, and settings.** Yours, on your machine.
* **Your API keys.** Stored on your Mac and sent only to the provider you configured, as part of that request.

### What Never Reaches Envious Labs

* Microphone audio or any sample of it
* Your transcribed text, raw or polished
* Your AI polish prompts, custom words, or writing styles
* The text around your cursor
* Your transcript history
* Your API keys or tokens
* Your name, email, account, or any personally identifying information
* File paths or your macOS username

None of this reaches us, and none of it goes into our usage analytics. If you turn on cloud AI polish, some of it does go to the AI provider you picked, because that is how polishing works. It goes there directly from your Mac under your own API key, never through us. The section below says exactly what.

### What Is Sent

The app sends anonymous usage and crash diagnostics so we can tell when a release breaks something and which features are worth building on. It is on by default and is not something you turn off. It describes how the app is being used, never what you said.

It contains no dictation content of any kind: no audio, no transcripts, no polished text, no prompts. There is no account and no sign-up, and nothing in it identifies you. It is not anonymous in the sense of being unlinkable, though: a random identifier is created on your Mac at install time, and events are grouped under it so we can tell one installation apart from another. Our privacy policy describes all of this in full.

If you would rather run without it, EnviousWispr is open source under GPLv3 and you can build it yourself. Dictation works exactly the same either way.

### Cloud AI Polish

If you choose a cloud provider for AI polish, your transcribed text goes straight from your Mac to that provider, under your own API key. There is no Envious Labs server anywhere in that path, so there is nothing for us to see. Audio is never sent to a polish provider, only text. See "AI Polish and Cloud Data" for what each provider receives.
