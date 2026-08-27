import EnviousWisprCore
import Foundation

/// Static "What's New" content, decoupled from the view layer.
///
/// The invariant is that the newest group MATCHES `WhatsNewConstants.currentContentVersion`,
/// not that the constant is bumped whenever entries change. Adding an entry to the
/// already-open group needs no Core edit; bumping it there would invent a release.
/// Bump only when starting a group for a version beyond the current one.
/// `WhatsNewContentTests.newestGroupIsCurrentVersion` enforces the match.
enum WhatsNewContent {
  struct Entry: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let version: String
  }

  static let entries: [Entry] = [
    // MARK: - v2.4.6

    // #2376. FIRST in the 2.4.6 group because order is the hierarchy
    // (whats-new-protocol.md RULE: whats-new-content-rules): headline feature,
    // then supporting features, then fixes. This is the feature; the entry below
    // is a removal.
    //
    // The 2.4.6 group is already open and already matches
    // `WhatsNewConstants.currentContentVersion`, so this needs no Core edit —
    // bumping it here would invent a release.
    //
    // **The copy names what a user GAINS, not what moved underneath.** Most of
    // this phase is a refactor nobody should be able to see, and saying so would
    // be talking about our code on a page about their app. What is genuinely new
    // is a choice they did not have and a meter most of them have never seen: it
    // has shipped since #2216 with exactly one construction site, inside the live
    // preview pill, so only users who can and do run that feature have ever laid
    // eyes on it.
    //
    // It deliberately does NOT promise the meter to everyone: it is one of two
    // options, and the capsule stays the default so nobody's pill changes on
    // upgrade. No dash characters, per GR-NO-DASHES.
    //
    // TITLE NOT YET FOUNDER-EDITED. He read and edited every title in the 2.4.5
    // group by hand on 2026-08-20; this one was written without him and is the
    // obvious thing for him to change.
    Entry(
      id: "recording-pill-designs",
      icon: "waveform.badge.mic",
      title: "Choose how your recording pill looks",
      description:
        "The pill that appears while you dictate now comes in more than one shape, and you pick which one you see. Appearance settings has a new Recording Pill section with two groups: pills that show your words as you speak, and pills that do not. Alongside the capsule you already know there is a new Level Rail, a wider pill carrying your timer beside a live rainbow meter of your voice. That meter has been in the app for a while, but until now only people running Live Preview ever saw it. Each group remembers its own choice, so if you switch Live Preview off and on again you get back the pill you picked for each. The group that does not apply to you right now stays visible and greyed, and tells you why rather than leaving you to guess.",
      version: "2.4.6"
    ),

    // #1831. OPENS THE 2.4.6 GROUP, and that placement is load-bearing.
    //
    // v2.4.5 shipped 2026-08-20. Anyone who has opened What's New since
    // then has `lastSeenWhatsNewVersion == "2.4.5"`, and the unread badge
    // is `lastSeen != currentContentVersion` (SettingsManager.swift:633),
    // so an entry added to the 2.4.5 group is never surfaced to exactly the
    // population it is written for. An earlier revision of this change put
    // it there; cloud review caught it.
    //
    // Bumping `currentContentVersion` from a feature PR is the established
    // shape, not an invented release: #2027 opened 2.4.5 the same way after
    // 2.4.4 shipped, touching WhatsNewConstants and NOT Info.plist. The
    // marketing version stays 2.4.5 until a release PR moves it.
    //
    // This entry exists because a REMOVAL is the case where saying nothing is
    // worst. The user who deliberately turned this on will not file a bug; they
    // will notice the switch is gone, assume their polish changed, and trust the
    // app less. Stating the measurement is what makes that a decision they can
    // check rather than something done to them quietly.
    //
    // The numbers are the #1832 thinking-level run: 100 topic_shift cases from
    // type_b_parakeet, gemini-3.7-flash, arms low/medium/high, one judge. NOT
    // the 1,462-case sealed_v1 run — that one compared MODELS at a fixed `low`
    // and is where 93.5% comes from. An earlier draft of this entry merged the
    // two and cloud review caught it; they are different corpora answering
    // different questions.
    //
    // Measured: 57.0 / 58.0 / 61.0% pass, McNemar exact two-sided p=0.42 for
    // low vs high, so the nominal edge is not distinguishable from chance at
    // n=100; p90 2.83x. Full table in the run's README.
    //
    // The copy deliberately does NOT promise unchanged output. Every arm here is
    // Gemini; #1831 also moves OpenAI reasoning models from medium to low and
    // that combination was never measured, so "your polish will read the same"
    // would be a claim about an unmeasured provider. No dash characters, per
    // GR-NO-DASHES.
    Entry(
      id: "deep-reasoning-retired",
      icon: "slider.horizontal.3",
      title: "One less switch to think about",
      description:
        "The AI Polish page used to carry a Deep reasoning switch, which asked cloud models to think harder before polishing your text. We finally measured it, on the hundred hardest dictations we test with, using the Gemini model the app ships with. Thinking harder did not produce a difference we could tell apart from chance, and it made polishing take close to three times as long on the slower dictations. So the switch is gone. Every model now always uses the setting it was already using for virtually everyone, because it shipped off and stayed off for practically all of you. If you were one of the few who turned it on, polishing will finish noticeably sooner. Nothing else about polishing changes, and no other setting moves.",
      version: "2.4.6"
    ),

    // #2465. LAST in the 2.4.6 group, because order is the hierarchy
    // (whats-new-protocol.md RULE: whats-new-content-rules) and this is a fix
    // rather than a feature: the shortcut was always meant to work here.
    //
    // **The entry exists because the change WRITES to the user's clipboard**,
    // which the feature never did before. A user who notices two new rows in
    // their clipboard history and finds no mention of it anywhere has been
    // surprised by their own dictation app. So the copy states the side effect
    // plainly and names the switch, rather than only announcing the win.
    //
    // It names no app class as the culprit. WhatsApp is the case the founder
    // reported and terminals are the other one, but naming them dates the entry
    // the moment either starts publishing a selection, and it is a diagnosis of
    // software we did not inspect. No dash characters, per GR-NO-DASHES.
    Entry(
      id: "quick-add-reads-more-apps",
      icon: "text.viewfinder",
      title: "Adding a word from your selection works in more apps",
      description:
        "Highlighting a word and pressing your Quick Add keybind did nothing in some apps, because they will not tell other apps what you have selected. Messaging apps built for iPad and terminals are the common ones. In those apps EnviousWispr now asks a second way: it copies your selection, reads it, and puts your clipboard back exactly as it was. It only does that where the ordinary way found nothing, so in every app that already worked your clipboard is never touched. If you copy something yourself while the panel is opening, your copy wins and yours is left alone. Your clipboard history will show the copy and the restore, which we do not try to hide. If you would rather it never touched your clipboard, there is a new switch in Clipboard settings, and it is off automatically in remote desktop and virtual machine apps.",
      version: "2.4.6"
    ),

    // MARK: - v2.4.5
    //
    // Order is the hierarchy (whats-new-protocol.md RULE: whats-new-content-rules):
    // headline feature first, then supporting features, then fixes, then the
    // one collected entry. Founder read and edited every title in this group on
    // 2026-08-20; do not reorder without him.

    // #2087. Founder's title and body. "Are now recoverable" states a
    // CAPABILITY rather than promising we will do it, which is what keeps the
    // header true for the majority who never switch the feature on.
    Entry(
      id: "escape-recovery-cancelled-dictations",
      icon: "arrow.uturn.backward.circle",
      title: "Cancelled dictations are now recoverable!",
      description:
        "Pressing your cancel keybind used to discard your recording instantly. Turn on Escape Recovery, and your dictation is preserved instead. The app finishes transcribing and polishing, then displays a small pill offering an Undo button for three seconds, staying visible as long as your pointer rests on it. If you let it fade, the text waits in your History for 24 hours, where a Keep button makes it permanent. Only the text transcript is retained, never the audio. Escape Recovery is disabled by default. You can enable it in the Keybinds settings menu.",
      version: "2.4.5"
    ),

    // #2059, #2113, #2137, #2198. Deliberately positive per founder direction
    // 2026-08-20: lead with the ask being met, do not enumerate what the
    // feature declines to do. The closing sentence is the one he called out as
    // important — a lagging preview costs the user nothing, because the pasted
    // text is decoded from the whole recording after the stop.
    Entry(
      id: "live-preview-words-while-you-speak",
      icon: "eye",
      title: "You asked for this: see your words as you speak",
      description:
        "This is the one you have been asking for. The recording pill now shows your words as you speak them. The box starts compact and grows to five lines, then scrolls so the newest thing you said is always in view, and the pill has been rebuilt around it with a live meter, a cleaner header and the hands-free timer back where you can see it. Choose the engine that suits your Mac: Apple's is built into macOS 26 and needs no preview model, though some languages ask macOS for a language pack first, or take the universal one, a 217 MB download that runs on macOS 14 and later and covers far more languages. You pick your language on the Live Preview page, and you can switch the whole thing on or off whenever you like. Your finished text is as good as ever: when you stop, Parakeet or WhisperKit transcribes the whole recording from the very first word, then your custom words and polish run on top. So there is no need to let the preview catch up before you stop talking. Everything you said is already captured.",
      version: "2.4.5"
    ),

    // #2044. Scoped to Parakeet on the founder's correction: WhisperKit always
    // honoured the picker, so "works on both engines" would have read as though
    // both gained something. The promise is also held to what the mechanism
    // does — the filter partitions by SCRIPT, so it suppresses foreign
    // alphabets and cannot separate two languages that share one.
    Entry(
      id: "parakeet-language-selection",
      icon: "character.bubble",
      title: "Language selection now available on Parakeet",
      description:
        "If you dictate in a language other than English, telling the app which language you speak now actually does something on Parakeet, the engine most people dictate with. It could not before: Parakeet has no language detection and no way of being told, so it worked purely from the sounds. Setting your language narrows what it produces to your own alphabet, so a German dictation stops coming back with stray Greek or Cyrillic characters in it. It cannot separate languages that share an alphabet, so it will not tell German from Dutch. If you use WhisperKit you could already set this, and nothing changes for you.",
      version: "2.4.5"
    ),

    // #2051, #2054. Eight names read off the shipped source list. "Without
    // changing them" is load-bearing and true: the obvious read-only approach
    // was rejected during the build because it modified one app's files.
    Entry(
      id: "smart-import-five-more-apps",
      icon: "square.and.arrow.down",
      title: "Bring your words across from five more dictation apps",
      description:
        "Switching from another dictation app used to mean retyping your vocabulary one word at a time. EnviousWispr can now read custom words out of Vox, TypeWhisper, Spokenly, Juno and Handy, on top of FluidVoice, Superwhisper and Wispr Flow. Eight apps in all. It reads their files without changing them, and shows you every word it found before anything joins your library.",
      version: "2.4.5"
    ),

    // #2096, #2106, #2124. Figures read off the campaign record, not the issue
    // summary. The "fewer critical errors" result is deliberately ABSENT: the
    // record marks it suggestive rather than established, because the arms were
    // graded in separate runs and the gap sits inside that noise.
    Entry(
      id: "eg1-retrained-on-weakest-spots",
      icon: "sparkles",
      title: "EG-1 has been retrained on its two weakest spots",
      description:
        "We spent this cycle retraining our built-in AI cleanup on the two things it was worst at, and both moved a long way. When you announce a list out loud, EG-1 used to hand you one long line almost every time: in our testing it built a real list under 1% of the time, and it now does it 83% of the time. When you change your mind mid-sentence, saying something like \"send it to Marcus, sorry, to Priya\", it keeps what you meant and drops what you took back 78% of the time, up from 71%, which puts it level with the frontier cloud models we measure ourselves against. It is also around 14% faster than the version it replaces. Those figures come from our own testing, on cases the model never trained on. Nothing changes about how you dictate. If you already use EG-1 the new version updates itself in the background the next time you open the app, with dictation working normally throughout, and you can pause that download and pick it up later from AI Polish settings, which now also shows which version you are on.",
      version: "2.4.5"
    ),

    // #2111. "OpenAI's newer models" is deliberate scoping, not vagueness: the
    // measured arm was a newer model, and on the shipped older default the new
    // prompt does not improve things (#2112, open). A blanket "OpenAI got
    // better" would be untrue for part of the audience reading it.
    Entry(
      id: "cloud-polish-prompt-v7",
      icon: "cloud",
      title: "Cloud AI polish got a better set of instructions",
      description:
        "If you bring your own OpenAI, Claude or Gemini key, we rewrote the instructions we send along with your dictation, and it is the biggest gain we have measured on the cloud path. On our benchmark Claude went from 80% to 88%, OpenAI's newer models from 88% to 94%, and Gemini from 88% to 91%, with critical errors down by a third to a half across all three. Spoken lists moved furthest: on OpenAI, announcing a list out loud produced a real list 57% of the time before and 93% of the time now. New Gemini setups also start on 3.7 Flash, which scored highest of the three Gemini models we tested and costs about 29% less to run than the one it replaces. Nothing changes about how you dictate, and if you have already picked a model we leave your choice exactly as it is.",
      version: "2.4.5"
    ),

    // #2027, #1998. Founder retitled this on 2026-08-20; body unchanged.
    Entry(
      id: "ollama-model-recommendations-from-tests",
      icon: "checkmark.seal",
      title: "Revised Ollama recommendations",
      description:
        "Ollama model labels used to be based on model size, which did not show how well they cleaned up dictation. They now reflect our own cleanup tests and explain what went wrong. New Ollama setups now start with qwen2.5:3b, the best result among the local models we offer. There is also a new option, qwen3:0.6b, which earned a Recommended label from a download about a quarter the size, so a small download no longer means poor cleanup. Models that produced no acceptable result ask before downloading.",
      version: "2.4.5"
    ),

    // #2025. "Not one ever succeeded" is the measured production figure across
    // 2.4.0-2.4.4: 14 stall events on virtual transports, ZERO successful
    // takes. The closing sentence is the point of the entry — this is the only
    // note in the release that can reach somebody who already gave up on us.
    Entry(
      id: "virtual-microphone-silence-fixed",
      icon: "mic.badge.xmark",
      title: "If dictation was recording silence, that is fixed",
      description:
        "If your Mac's default microphone was a virtual one, the kind that Krisp, Loopback, BlackHole, an aggregate device or a meeting app installs, EnviousWispr took it at its word and recorded digital silence. Not quieter audio, nothing at all, every single time. Across the four releases we have data for, not one dictation on a device like that ever succeeded. The app now reads what the device actually is before binding to it, and picks a real microphone over one of these whenever you have one. If a virtual device is genuinely the only input on your Mac, it is still used, because refusing it would leave you with nothing to record with at all. If you tried EnviousWispr, got nothing back, and assumed it was broken: it was, and it is worth another go.",
      version: "2.4.5"
    ),


    // #2181, #2174, #2192, #2197, #2032, #2200, #2076, #1999, #2001, #2006.
    // A COLLECTED entry, permitted by whats-new-protocol.md
    // RULE: whats-new-content-rules only when it is LAST, every other entry is
    // specifically titled, and the title is written fresh. "Fixes you should
    // never notice" is spent on v2.4.4; this title is likewise now spent and
    // must NOT be reused. Its members are visible improvements rather than
    // invisible ones, so the title deliberately does not claim invisibility.
    Entry(
      id: "smaller-wins-2-4-5",
      icon: "wrench.and.screwdriver",
      title: "The smaller wins",
      description:
        "A handful of smaller improvements. The Shortcuts page is now called Keybinds, and everywhere that used to say \"hotkey\" now says \"keybind\", so one thing has one name. Live transcription is now called Faster Transcription, because changing when your text lands is what it actually does. Noisy rooms no longer eat the start of your sentence, though if you use auto-stop its timing will move in those rooms: usually stopping sooner, and on the half-second setting sometimes waiting longer or not stopping on its own at all. Pasting is around four times quicker, down from roughly 265 milliseconds to under 60 in most apps, because your dictation no longer waits on the clipboard handover before counting itself done. Dictating into a terminal no longer quietly gives up part way through a session, where the only cure used to be quitting and reopening the app. Recordings are no longer cut short as though nothing was heard, which could happen when a quiet opening ate the app's patience before you had really started. Dragging a pill no longer leaves a ghost copy of it stranded on screen. Changing your dictation keybind can no longer set a recording going by accident. A single modifier key now works as your cancel keybind, where before it would save and display and then quietly do nothing. And if you run EnviousWispr straight from your Downloads folder, its offer to move itself into Applications now actually works.",
      version: "2.4.5"
    ),

    // MARK: - v2.4.4

    Entry(
      id: "globe-key-dictation-hotkey",
      icon: "globe",
      title: "Use the Globe key, or Fn, as your dictation keybind",
      description:
        "You can now use the Globe key, marked Fn on many Macs, as your dictation keybind. Right Option stays exactly as it is unless you choose Globe. If macOS also opens emoji, switches your keyboard language, or starts its own dictation when you press it, go to System Settings, then Keyboard, then Press 🌐 key to, and choose Do Nothing.",
      version: "2.4.4"
    ),

    Entry(
      id: "ollama-cloud-models-appear-automatically",
      icon: "cloud",
      title: "Ollama Cloud models now appear automatically",
      description:
        "Ollama Cloud models used to appear in Manage Models only after you added them on that Mac. The full lineup now appears there automatically on every install and after every update. The button now says Add instead of Download because nothing is downloading, and cloud models can no longer be deleted. For 30 days after the August 5, 2026 check, the models available without a paid Ollama plan are listed first. After that the list returns to a neutral order.",
      version: "2.4.4"
    ),

    Entry(
      id: "ollama-cloud-supported-end-to-end",
      icon: "checkmark.icloud",
      title: "Ollama Cloud models are now properly supported end to end",
      description:
        "If you polish with an Ollama Cloud model, EnviousWispr used to treat it as a small model running on your Mac. It gave the model too little room to work, spent your cloud quota on warm-up calls it did not need, and when something failed it told you to start Ollama even though Ollama was already running. Cloud models are now recognised for what they are, and if you are signed out of Ollama the message says so. Models that run on your own Mac also get a prompt written for them, replacing one that was quietly working against itself on most dictations.",
      version: "2.4.4"
    ),

    Entry(
      id: "ollama-settings-stay-accurate",
      icon: "arrow.clockwise.circle",
      title: "Ollama settings and the model list now stay accurate",
      description:
        "The Ollama status in Settings could get stuck: still saying it was starting after it was ready, or still saying ready after you had quit Ollama. It now keeps itself current while you have the panel open. The model picker also showed two different models under one identical name, so there was no way to tell them apart. Each one is now labelled so you can.",
      version: "2.4.4"
    ),

    Entry(
      id: "continuation-casing-eleven-languages",
      icon: "character.book.closed",
      title: "Dictating into the middle of a sentence now works in eleven more languages",
      description:
        "When you type part of a sentence and dictate the rest, EnviousWispr matches the capitalisation you would have used yourself. Until now that only worked in English, so every other language got a capital letter dropped into the middle of your sentence. It now works in German, French, Italian, Spanish, Portuguese, Dutch, Danish, Swedish, Finnish, Russian and Turkish. Measured against real published writing, this went from right 7% of the time to right 94%. We also found several ways to make it more accurate everywhere, so it now works reliably in far more of the places you dictate.",
      version: "2.4.4"
    ),

    Entry(
      id: "fewer-transcription-errors",
      icon: "exclamationmark.bubble",
      title: "Fewer transcription errors",
      description:
        "A quick press with no dictation used to fire an error that had nothing to explain. No more. And a microphone that sent no audio at all now asks you to check your mic, instead of blaming transcription for something transcription never saw.",
      version: "2.4.4"
    ),

    Entry(
      id: "fixes-you-should-never-notice",
      icon: "checkmark.shield",
      title: "Fixes you should never notice",
      description:
        "Custom Words saves are now much more resilient to an app crash or a power cut. After an update, a leftover model file can no longer be mistaken for a good one. And the speech engine has picked up newer transcription repairs from upstream. All real, all invisible unless something goes wrong.",
      version: "2.4.4"
    ),

    // MARK: - v2.4.3

    Entry(
      id: "cursor-aware-capitalization",
      icon: "textformat",
      title: "Dictating after an incomplete sentence properly considers capitalization",
      description:
        "If you type part of a sentence and then dictate the rest, EnviousWispr now looks at the words already there before it writes. It matches the capitalization and spacing you would have used, so you no longer get a capital letter in the middle of your own sentence. If the dictation repeats a word you just typed, the duplicate is removed. This also works in your terminal when Claude Code, Codex or Gemini CLI is running.",
      version: "2.4.3"
    ),

    Entry(
      id: "spoken-punctuation-is-now-a-choice",
      icon: "text.quote",
      title: "Added a toggle to control spoken punctuation",
      description:
        "Saying \"comma\" or \"period\" used to always insert the punctuation mark, even when you meant the word. There is now a toggle for it under Speech Engine, in the Cleanup section. It is off by default, because EnviousWispr already adds punctuation for you. Turn it on if you prefer to dictate punctuation out loud, and the help icon beside it lists every word you can say.",
      version: "2.4.3"
    ),

    Entry(
      id: "parakeet-final-words",
      icon: "waveform.badge.checkmark",
      title: "Improved how Parakeet hears the last few words of your dictation",
      description:
        "Parakeet, the default speech engine, would sometimes add a word you never said at the very end of a dictation. \"I was able to\" could come back as \"I was able to do that.\" That no longer happens. Your dictation ends where you stopped speaking.",
      version: "2.4.3"
    ),

    Entry(
      id: "bluetooth-wake-grace",
      icon: "headphones",
      title: "Further improved Bluetooth performance",
      description:
        "Bluetooth microphones take a moment to start listening after you press, and EnviousWispr was giving up too early. A first press on AirPods or a headset could come back with nothing at all. It now waits for the connection to wake up, so you can press and start talking.",
      version: "2.4.3"
    ),

    Entry(
      id: "audio-error-reporting",
      icon: "exclamationmark.bubble",
      title: "Improved audio error reporting",
      description:
        "When your microphone sent nothing usable, EnviousWispr showed a generic error with a Try Again button that would fail the same way. In one case it said nothing at all. You now get a plain sentence asking you to check your microphone. And if macOS loses track of your default microphone, EnviousWispr finds another connected one and carries on.",
      version: "2.4.3"
    ),

    Entry(
      id: "help-icons-introduced",
      icon: "questionmark.circle",
      title: "Began introducing help icons within the application",
      description:
        "We've recognized there's a lot of nuance to how our software works. You might start noticing help icons next to some toggles so you can better understand the features and capabilities.",
      version: "2.4.3"
    ),

    Entry(
      id: "gemini-latest-models",
      icon: "cloud.bolt",
      title: "Updated Gemini API to support latest models",
      description:
        "Google changed how its newer Gemini models accept requests, and several models in the picker had stopped working for cloud polish. They all work now. The default Gemini model has also been updated, since Google retired the previous one.",
      version: "2.4.3"
    ),

    Entry(
      // **"Live transcription" here is CORRECT and must not be renamed.** #2155
      // renamed that setting to Faster Transcription, and every other mention in
      // the app moved with it. This one is a shipped release note describing
      // v2.4.3, when the setting WAS called Live transcription. Rewriting it
      // would make the historical record describe a name that did not exist at
      // the time — the same exclude-list discipline dated audits and changelog
      // rows get (workflow-process.md RULE: self-review-and-grep-before-codex).
      // A future sweep for the old name will find this line; leave it.
      id: "smaller-repairs-recording-settings",
      icon: "wrench.and.screwdriver",
      title: "A handful of smaller repairs across recording and settings",
      description:
        "With Live transcription switched on, the last words you said could go missing while the transcript still looked complete. Settings could say your speech engine was ready before it actually was, so recording would not start. Hands-free mode could get stuck, leaving your keybind doing nothing. Recovering a recording that was interrupted is more dependable. And the app runs more steadily on the newest Macs.",
      version: "2.4.3"
    ),

    // MARK: - v2.4.1

    Entry(
      id: "import-words-from-another-app",
      icon: "arrow.down.doc",
      title: "Bring your words over from another dictation app",
      description:
        "Switching no longer means retyping your vocabulary. Pick the app you used before and your words come across, including the misspellings you had it watch for. FluidVoice, Superwhisper and Wispr Flow are supported today, with more on the way, and only apps actually installed on your Mac are offered. Nothing on your disk is touched until you choose one, and nothing is added to your words until you review and approve it. On Macs where Apple Intelligence is available, EnviousWispr also suggests sound-alike spellings for your new words automatically, so dictation picks them up without a second pass by hand.",
      version: "2.4.1"
    ),
    Entry(
      id: "import-words-from-file-or-paste",
      icon: "square.and.arrow.down",
      title: "Import words from a file, or just paste a list",
      description:
        "Upload a words file or a plain text file, or paste a list straight in. Every route lands on the same review screen, so you see exactly what will be added, what is already yours, and what clashes, before anything changes. On Macs where Apple Intelligence is available, new words can also get automatic sound-alike suggestions.",
      version: "2.4.1"
    ),
    Entry(
      id: "export-words-backup",
      icon: "square.and.arrow.up",
      title: "Export your words to a backup you own",
      description:
        "Save your whole vocabulary to a file. Useful for a backup, for moving to a new Mac, or for sharing a set of words with someone else.",
      version: "2.4.1"
    ),
    Entry(
      id: "claude-cloud-polish-provider",
      icon: "sparkles",
      title: "Claude joins OpenAI and Gemini for cloud polish",
      description:
        "Bring your own Anthropic key and let Claude clean up your dictation, with ten models to choose from. As always, it is your key and your account, and the app tells you exactly what gets sent.",
      version: "2.4.1"
    ),
    Entry(
      id: "bulk-select-delete-words",
      icon: "checklist",
      title: "Select and delete many words at once",
      description:
        "Tidy up your list without deleting one word at a time. If you are about to remove a lot, EnviousWispr offers to export them first so nothing disappears by accident.",
      version: "2.4.1"
    ),
    Entry(
      id: "revamped-crash-recovery",
      icon: "lifepreserver",
      title: "Revamped crash recovery",
      description:
        "Our crash recovery system is smarter now. It actively tries to rescue a failed dictation wherever it can while the app is still running, not only after a crash. If the speech engine stops responding while you are still talking, EnviousWispr keeps the audio it already captured and transcribes it rather than losing the dictation.",
      version: "2.4.1"
    ),
    Entry(
      id: "cloud-polish-longer-dictations",
      icon: "text.alignleft",
      title: "Better cloud polishing for long dictations",
      description:
        "We reworked the output limits across all three cloud AI providers, so even a very long dictation has the room it needs to be polished in full.",
      version: "2.4.1"
    ),
    Entry(
      id: "two-copies-share-words-safely",
      icon: "square.on.square",
      title: "Fixed: a rare issue when the app was running twice",
      description:
        "If you happened to have two copies of EnviousWispr running at the same time, your custom words could be affected. That is now handled properly.",
      version: "2.4.1"
    ),

    // MARK: - v2.4.0

    Entry(
      id: "model-download-improvements",
      icon: "arrow.down.circle",
      title: "Download improvements",
      description:
        "We revamped how the speech and polish models download, and where they are stored on disk. Downloads are faster, resume on their own if your connection drops, and can be cancelled if they stall.",
      version: "2.4.0"
    ),
    Entry(
      id: "bluetooth-usb-audio-support",
      icon: "waveform.badge.mic",
      title: "Proper Bluetooth and USB audio support",
      description:
        "EnviousWispr now properly supports Bluetooth and USB microphones, including on Mac mini. We also rebuilt the entire infrastructure around our sound capture engine to be far more robust, so recording no longer fails quietly when a microphone misbehaves.",
      version: "2.4.0"
    ),
    Entry(
      id: "recording-sound-cues",
      icon: "speaker.wave.2",
      title: "Customizable sound cues",
      description:
        "Optional chimes when recording starts and stops. Twelve to choose from, soft to loud. Off by default.",
      version: "2.4.0"
    ),
    Entry(
      id: "recording-pill-position",
      icon: "rectangle.topthird.inset.filled",
      title: "Choose your recording pill location",
      description:
        "Move the recording pill to the top or bottom of your screen and it remembers.",
      version: "2.4.0"
    ),
    Entry(
      id: "larger-menu-bar-icon",
      icon: "menubar.arrow.up.rectangle",
      title: "Larger menu bar icon",
      description:
        "The menu bar icon is now larger and easier to spot.",
      version: "2.4.0"
    ),
    Entry(
      id: "open-source-licenses",
      icon: "doc.text",
      title: "Open Source Licenses",
      description:
        "A new screen in Settings so the open source licenses EnviousWispr is built on are always available to read in the app.",
      version: "2.4.0"
    ),
    Entry(
      id: "openai-model-support",
      icon: "sparkles",
      title: "All OpenAI models now properly supported",
      description:
        "OpenAI changed how its API calls work. We fixed them so their full library of models can be used for cloud polishing. This also includes smaller fixes, such as making sure you are notified if you forget to enter your API key.",
      version: "2.4.0"
    ),
    Entry(
      id: "recording-timer-reset",
      icon: "timer",
      title: "Timer bug addressed",
      description:
        "The timer no longer resets when you swap between screens.",
      version: "2.4.0"
    ),

    // MARK: - v2.3.2

    Entry(
      id: "chosen-microphone-recording-failure",
      icon: "mic.circle",
      title: "Fixed: recording could fail every time on a specific microphone",
      description:
        "If you picked a microphone by name instead of leaving it on Automatic, and that microphone was running at a sample rate other than the usual one, EnviousWispr could fail to record with the message \"XPC audio service is unreachable.\" It did not clear up on its own, and reinstalling or updating the app did not help, because the setting that caused it lives in macOS rather than in EnviousWispr. The app now reads the microphone's real settings before it starts listening, so recording works whatever rate your microphone is set to. If you have been stuck on this, updating is enough to fix it.",
      version: "2.3.2"
    ),

    // MARK: - v2.3.1

    Entry(
      id: "reliable-first-run-download",
      icon: "arrow.down.circle",
      title: "First-run setup downloads are far more reliable",
      description:
        "Setting up EnviousWispr downloads a speech model, and on some networks that download could stall and leave you stuck before you ever got to dictate. We rebuilt how the app fetches it: the download now resumes on its own if your connection drops, falls back to a backup source when needed, and can no longer hang forever. If setup gets interrupted, reopening the app picks up right where it left off instead of starting over.",
      version: "2.3.1"
    ),

    // MARK: - v2.3.0

    Entry(
      id: "eg1-native-polish",
      icon: "sparkles",
      title: "Meet EG-1, our new recommended polish engine",
      description:
        "EnviousWispr now ships its own AI polish model, trained specifically for dictation, and it is remarkably strong: a 94.7% pass rate across our 1,890-case benchmark, edging out the big cloud models. It shines exactly where built-in Apple Intelligence falls short: turning spoken lists into real lists, honoring your mid-sentence self-corrections, and breaking long dictations into clean paragraphs. It is fast, typically polishing a dictation in under a second, and completely offline: download it once and it runs entirely on your Mac, no account, no API key, no internet after setup. EG-1 is our recommended engine going forward.",
      version: "2.3.0"
    ),
    Entry(
      id: "whisperkit-engine-redesign",
      icon: "waveform.badge.mic",
      title: "The All Languages engine, redesigned",
      description:
        "We rebuilt the All Languages engine from the ground up to transcribe live while you speak as well as in one pass at the end of a recording. Your text now lands almost immediately when you stop, no matter how long you talked, first words come through quicker, and the redesign makes the engine more robust: fewer imagined phrases like a stray \"thank you\" during quiet moments, and no more text going missing or repeating in longer recordings. To stream live, pick a specific language in Settings; with Auto-detect on, the engine waits for the full recording so it can identify your language accurately.",
      version: "2.3.0"
    ),
    Entry(
      id: "settings-redesign",
      icon: "paintbrush",
      title: "Settings got a full visual refresh",
      description:
        "We updated the Settings page to be easier to read and navigate. Settings and History now share one polished, unified look, with roomier spacing, easier-to-read text, and a redesigned AI Polish tab where each engine has its own card with everything you need to set it up.",
      version: "2.3.0"
    ),
    Entry(
      id: "ollama-misconfig-fix",
      icon: "checkmark.seal",
      title: "Smoother behavior when Ollama polish is not set up right",
      description:
        "If Ollama polish is selected but not properly set up, say the model is missing or Ollama is not running, the app no longer misbehaves. It tells you clearly what is wrong and delivers your unpolished text right away.",
      version: "2.3.0"
    ),
    Entry(
      id: "ordinal-numbers-fix",
      icon: "textformat.123",
      title: "Smarter built-in number handling",
      description:
        "We improved the always-on, non-AI part of the pipeline that formats spoken numbers. Phrases like \"two hundredth anniversary\" and \"third-largest city\" now come out exactly right instead of turning into odd digit mixes.",
      version: "2.3.0"
    ),

    // MARK: - v2.2.1

    Entry(
      id: "tail-clip-recovery",
      icon: "waveform.badge.checkmark",
      title: "Long dictations keep every last word",
      description:
        "Fixed a long-standing bug where the end of a longer dictation could go missing if you paused mid-sentence near the finish. The speech engine now catches and recovers those moments, so your closing words always land.",
      version: "2.2.1"
    ),
    Entry(
      id: "cloud-polish-facelift",
      icon: "cloud.bolt",
      title: "Cloud AI polish got a facelift",
      description:
        "If you bring your own OpenAI or Gemini key, polish just got a major upgrade. We rewrote the prompt from the ground up and benchmarked it across 1,890 real dictation cases: pass rates jumped from about 70% to about 92%. You'll notice the difference most in paragraph breaks when you change topics, spoken lists becoming real lists, cleaner handling of mid-sentence self-corrections, grammar fixes, and emoji staying exactly where you put them.",
      version: "2.2.1"
    ),

    // MARK: - v2.2.0

    Entry(
      id: "dark-mode",
      icon: "circle.lefthalf.filled",
      title: "Dark mode has arrived",
      description:
        "EnviousWispr now has a dark mode. Match your system automatically, or pick light or dark yourself in Settings. Easier on the eyes for late-night dictation.",
      version: "2.2.0"
    ),
    Entry(
      id: "hour-long-recordings",
      icon: "clock",
      title: "Record for up to an hour at a time",
      description:
        "You can now record for up to a full hour in one go. As you near the limit you get a gentle heads-up, and recording stops cleanly on its own so you never lose what you said.",
      version: "2.2.0"
    ),
    Entry(
      id: "sharper-on-device-polish",
      icon: "wand.and.stars",
      title: "Sharper on-device polish",
      description:
        "The built-in, fully on-device polish got a real tune-up. It cleans up filler and phrasing more reliably, keeps the natural way you start a sentence, and leaves your wording alone when it should.",
      version: "2.2.0"
    ),
    Entry(
      id: "emoji-stay-put",
      icon: "face.smiling",
      title: "Your emoji stay put",
      description:
        "Dictate an emoji and it now stays exactly where you placed it after polish runs. No more emoji going missing or landing in the wrong spot.",
      version: "2.2.0"
    ),
    Entry(
      id: "clearer-polish-failure-reasons",
      icon: "exclamationmark.bubble",
      title: "Clearer reasons when polish can't finish",
      description:
        "If cloud or on-device AI polish ever cannot finish, EnviousWispr now tells you specifically what happened and what to do, instead of a vague notice. Either way, your clean transcription is always delivered.",
      version: "2.2.0"
    ),
    Entry(
      id: "crash-recovery",
      icon: "arrow.clockwise.circle",
      title: "Your words survive an unexpected quit",
      description:
        "If the app ever closes in the middle of a dictation, your recording is no longer lost. When you reopen EnviousWispr it quietly picks up where it left off and finishes turning your words into text.",
      version: "2.2.0"
    ),
    Entry(
      id: "ap-style-numbers",
      icon: "textformat.123",
      title: "Numbers written the way you would write them",
      description:
        "Numbers now come out the way you would actually type them: small ones spelled out, larger ones as digits, following the same style most newsrooms use. That means less cleanup for you.",
      version: "2.2.0"
    ),
    Entry(
      id: "no-clipped-last-words",
      icon: "waveform",
      title: "No more clipped last words",
      description:
        "We fixed a case where a quick, energetic word or two at the very end of a dictation could get trimmed off. Your full sentence now makes it through.",
      version: "2.2.0"
    ),
    Entry(
      id: "paste-never-waits-on-history",
      icon: "checkmark.circle",
      title: "Pasting never waits on saving",
      description:
        "Even if saving a dictation to your History runs into a snag, your words still land where you are typing. Delivery no longer waits on the archive.",
      version: "2.2.0"
    ),
    Entry(
      id: "voiceover-and-keyboard",
      icon: "accessibility",
      title: "Built for VoiceOver and keyboard navigation",
      description:
        "EnviousWispr now reads cleanly with VoiceOver and is fully operable from the keyboard. Its keybind recorders, buttons, and update prompts announce themselves clearly and respond to keyboard control.",
      version: "2.2.0"
    ),
    Entry(
      id: "clearer-polish-on-older-macs",
      icon: "sparkles",
      title: "Clearer polish on older Macs",
      description:
        "On Macs that cannot run Apple's on-device polish, EnviousWispr no longer shows a confusing \"polish failed\" note. It simply hands you your clean transcription, and onboarding now explains your polish options up front.",
      version: "2.2.0"
    ),
    Entry(
      id: "words-stay-out-of-diagnostics",
      icon: "lock.shield",
      title: "Your words stay out of diagnostics",
      description:
        "We added another layer to make sure your dictated words can never end up in crash reports or diagnostics. What you say stays yours.",
      version: "2.2.0"
    ),
    Entry(
      id: "open-source-and-verifiable",
      icon: "chevron.left.forwardslash.chevron.right",
      title: "Open source, and easy to verify",
      description:
        "EnviousWispr is open source under the GPLv3 license, and every download now points you straight to the full source. You can see exactly what the app does.",
      version: "2.2.0"
    ),

    // MARK: - v2.1.4

    Entry(
      id: "paste-works-in-word-excel-pages",
      icon: "doc.richtext",
      title: "Pasting now lands in Word, Excel, and more",
      description:
        "We fixed an issue where in some apps (Word, Excel, Pages, Numbers, OneNote, Sublime Text, Firefox) your dictation would say \"Copied\" but never actually paste. Your words now land in the document like everywhere else.",
      version: "2.1.4"
    ),
    Entry(
      id: "small-ui-tweaks",
      icon: "sparkles",
      title: "Small UI tweaks for a cleaner experience",
      description:
        "A tidier sidebar status card, History columns that stay readable in small windows, more reliable update delivery, and an AI badge that only appears when AI actually ran.",
      version: "2.1.4"
    ),

    // MARK: - v2.1.3

    Entry(
      id: "import-names-from-contacts",
      icon: "person.crop.circle.badge.plus",
      title: "Bring in the names of people you know",
      description:
        "One tap on \"Import from Contacts\" adds the people in your address book to your custom words, so a coworker's or friend's hard-to-spell name comes out right the first time. Everything stays on your Mac. Your contacts are never uploaded. EnviousWispr also quietly learns the common ways each name gets misheard, so it catches those too.",
      version: "2.1.3"
    ),
    Entry(
      id: "vocabulary-packs",
      icon: "books.vertical",
      title: "Vocabulary packs for brands and jargon",
      description:
        "Turn on a pack and EnviousWispr recognizes those words and capitalizes them the way they're meant to be written (AngularJS, Nivea, Acosta). Each pack has a searchable list, so you can see every word it covers and the spoken variants it catches.",
      version: "2.1.3"
    ),
    Entry(
      id: "no-swallowed-press-after-idle",
      icon: "clock.arrow.circlepath",
      title: "No more swallowed first press after a break",
      description:
        "If you left the app idle for a while, your next recording could get eaten while it flashed a \"warming up\" notice, even though it was basically ready. It now quietly re-wakes in a fraction of a second and captures your words, including the very first one.",
      version: "2.1.3"
    ),
    Entry(
      id: "simpler-settings-performance",
      icon: "slider.horizontal.3",
      title: "One less Settings tab to hunt through",
      description:
        "The \"Performance\" tab held just one control: how long to keep the engine loaded between recordings. It now sits at the bottom of the Transcription screen, right where it belongs, so Settings has one less place to look.",
      version: "2.1.3"
    ),

    // MARK: - v2.1.2

    Entry(
      id: "automatic-update-checks",
      icon: "sparkles",
      title: "EnviousWispr keeps itself current",
      description:
        "The app now looks for new versions on its own: when you open it, when you come back to it, and quietly in the background. So a waiting improvement finds you instead of you having to go looking. There's also a clear \"Check for Updates\" control in Settings if you ever want to look right now.",
      version: "2.1.2"
    ),
    Entry(
      id: "soft-and-distant-speech-captured",
      icon: "waveform",
      title: "Soft and distant speech no longer gets dropped",
      description:
        "If you spoke quietly, whispered, or sat back from your mic, EnviousWispr would sometimes capture nothing at all. It now hears those faint and far-away words and writes them down, including a soft first word that used to get clipped off the start.",
      version: "2.1.2"
    ),
    Entry(
      id: "no-false-warming-up-notice",
      icon: "bolt.badge.checkmark",
      title: "No more false \"warming up\" notice",
      description:
        "Tapping record again right after a quick tap or a \"changed my mind\" cancel could flash the \"warming up\" notice as if the app were starting cold, even though it was already warm and ready. That stray notice is gone: a warm app just records.",
      version: "2.1.2"
    ),
    Entry(
      id: "removed-recording-environment-picker",
      icon: "slider.horizontal.3",
      title: "Removed a setting that promised something it didn't do",
      description:
        "The \"Recording Environment\" choice (Quiet, Normal, Noisy) sounded like it changed how well the app hears you in different surroundings. It never did that. We removed it so Settings only shows controls that actually do what they say.",
      version: "2.1.2"
    ),

    // MARK: - v2.1.1

    Entry(
      id: "speak-naturally-see-it-written",
      icon: "textformat.123",
      title: "Speak it naturally, see it written",
      description:
        "EnviousWispr now formats what you dictate the way you actually mean it, automatically: phone numbers, money, percentages, years, dates, times, ordinals, decimals, number ranges, emails, and web addresses. Say \"five five five, one two three, four five six seven\" and you get 555-123-4567; \"eighty million dollars\" becomes $80 million; \"nineteen eighty seven\" becomes 1987. It even works when AI polish is turned off.",
      version: "2.1.1"
    ),
    Entry(
      id: "more-reliable-updates",
      icon: "arrow.triangle.2.circlepath",
      title: "More reliable updates",
      description:
        "We improved how EnviousWispr installs new versions, so updates land cleanly instead of getting stuck partway. And if an update ever has trouble, the copy you already have keeps working.",
      version: "2.1.1"
    ),

    // MARK: - v2.1.0

    Entry(
      id: "polish-keeps-your-words",
      icon: "checkmark.shield",
      title: "Polish keeps your words, not your commands",
      description:
        "Dictate something that sounds like an instruction, like \"draft a Slack to Matt about the launch\", and on-device polish used to sometimes go write that message instead of cleaning up what you said. It now recognizes the difference and keeps your actual words.",
      version: "2.1.0"
    ),
    Entry(
      id: "honest-warm-up-then-instant",
      icon: "gauge.with.dots.needle.33percent",
      title: "An honest warm-up, then instant presses",
      description:
        "Right after launch the speech engine takes a moment to warm up. You now see a clear indicator while that happens, instead of a start that looks frozen. Once it is warm, every press begins instantly with no flicker.",
      version: "2.1.0"
    ),
    Entry(
      id: "whisperkit-on-gpu",
      icon: "bolt",
      title: "Faster WhisperKit transcription",
      description:
        "We moved the WhisperKit speech engine from your Mac's Neural Engine onto its GPU. In our testing that is the faster path for WhisperKit, so transcription warms up and finishes quicker.",
      version: "2.1.0"
    ),
    Entry(
      id: "steadier-under-the-hood-2-1",
      icon: "wrench.and.screwdriver",
      title: "A steadier app under the hood",
      description:
        "We finished a major rebuild of how EnviousWispr is assembled and packaged. You won't see it directly, but it makes the app sturdier and lets us ship improvements to you faster and more safely.",
      version: "2.1.0"
    ),

    // MARK: - v2.0.3

    Entry(
      id: "spoken-emoji",
      icon: "face.smiling",
      title: "Speak an emoji",
      description:
        "Say the emoji's name followed by the word \"emoji\" while you dictate, like \"smiley face emoji\" or \"thumbs up emoji\", and EnviousWispr drops the glyph right in.",
      version: "2.0.3"
    ),
    Entry(
      id: "smart-language-detection",
      icon: "globe",
      title: "Smarter language detection",
      description:
        "On the Multi-Language speech engine, EnviousWispr now notices when you keep dictating in the same non-English language and offers to lock it in. A fixed language makes transcription both faster and more accurate.",
      version: "2.0.3"
    ),
    Entry(
      id: "newer-ai-polish-models",
      icon: "sparkles",
      title: "Newer AI Polish models",
      description:
        "AI Polish now works with the latest models. We recommend Gemini 3.5 Flash, or OpenAI 5.4 mini or nano, for the best balance of speed and quality.",
      version: "2.0.3"
    ),
    Entry(
      id: "steadier-under-the-hood",
      icon: "wrench.and.screwdriver",
      title: "A steadier app under the hood",
      description:
        "We continued a major rebuild of how the app manages itself internally. You won't see it directly, but it makes EnviousWispr more stable and quicker for us to improve.",
      version: "2.0.3"
    ),

    // MARK: - v2.0.2

    Entry(
      id: "right-option-push-to-talk",
      icon: "keyboard",
      title: "One key to talk",
      description:
        "Push-to-talk now defaults to a single tap of Right Option. Faster to reach than a two-key combo, and easier to remember. You can still remap it in Settings.",
      version: "2.0.2"
    ),
    Entry(
      id: "ai-polish-keys-in-keychain",
      icon: "lock.shield",
      title: "AI Polish keys live in your keychain",
      description:
        "Your API keys for AI Polish are now stored in your Mac's keychain, the same secure place your other passwords live. Existing keys were moved over automatically.",
      version: "2.0.2"
    ),
    Entry(
      id: "cleaner-audio-settings",
      icon: "slider.horizontal.3",
      title: "Cleaner audio settings",
      description:
        "Removed the noise suppression toggle. It wasn't doing what its name suggested, and a quieter settings panel is one less thing to wonder about.",
      version: "2.0.2"
    ),
    Entry(
      id: "update-banner-stays-put",
      icon: "arrow.down.circle",
      title: "Update reminder stays put",
      description:
        "When a new version is ready, the in-app banner now stays visible until you install. No more dismissing it and forgetting it was there.",
      version: "2.0.2"
    ),

    // MARK: - v2.0.1

    Entry(
      id: "better-error-logging",
      icon: "doc.text.magnifyingglass",
      title: "Better error logging",
      description:
        "Improved our error logging so we can spot issues and enhance your experience faster.",
      version: "2.0.1"
    ),

    // MARK: - v2.0.0

    Entry(
      id: "welcome-to-2-0",
      icon: "sparkles",
      title: "Welcome to EnviousWispr 2.0",
      description:
        "EnviousWispr 2.0 is about trust. Better text on the first try, sharper memory for your words, and fewer moments where you have to step in.",
      version: "2.0.0"
    ),
    Entry(
      id: "your-words-has-a-real-home",
      icon: "books.vertical",
      title: "\"Your Words\" has a real home now",
      description:
        "Learning, Vocab Packs, and Custom Terms each have their own section in Settings. Easier to see what EnviousWispr remembers, what you added yourself, and where to tune it.",
      version: "2.0.0"
    ),
    Entry(
      id: "afm-dual-mode-polish",
      icon: "wand.and.stars",
      title: "Apple Intelligence keeps your voice and your precision",
      description:
        "On-device polish keeps your voice and your precision. Casual notes keep your tone. Code, jargon, and careful business writing keep their precision. Six months of tuning underpins this.",
      version: "2.0.0"
    ),
    Entry(
      id: "custom-terms-survive-on-device-polish",
      icon: "tag.circle",
      title: "Your custom terms now survive on-device polish",
      description:
        "Words you teach EnviousWispr now carry through to Apple Intelligence polish, not just cloud polish. Product names, client names, and domain terms are far less likely to get cleaned into the wrong thing.",
      version: "2.0.0"
    ),
    Entry(
      id: "less-fiddling-better-polish",
      icon: "slider.horizontal.3",
      title: "Less fiddling, better polished text",
      description:
        "Formal, Standard, and Friendly are gone. They rarely changed the result and could quietly bypass smart routing on Apple Intelligence. There is now one quality-tuned default that delivers more consistently.",
      version: "2.0.0"
    ),
    Entry(
      id: "pick-polish-model-faster",
      icon: "list.bullet.rectangle",
      title: "Pick the right polish model faster",
      description:
        "Polish models are now grouped by provider with a short note on what each one is good at. Less hunting, better choices.",
      version: "2.0.0"
    ),
    Entry(
      id: "smarter-new-word-suggestions",
      icon: "quote.bubble",
      title: "Adding a new word is smarter now",
      description:
        "When you add a custom term, EnviousWispr suggests likely spellings and pronunciations to catch. Repetitive or low-quality suggestions are filtered out more aggressively.",
      version: "2.0.0"
    ),
    Entry(
      id: "cleaner-transcription-before-polish",
      icon: "waveform",
      title: "Cleaner transcription before polish",
      description:
        "The speech engine is now faster and steadier, especially on longer recordings. Fewer odd substitutions and cleaner raw text before polish even runs.",
      version: "2.0.0"
    ),
    Entry(
      id: "no-more-phantom-thank-you",
      icon: "speaker.slash",
      title: "No more phantom \"Thank you\"",
      description:
        "Silent endings used to occasionally produce a fake \"Thank you.\" That hallucination is now suppressed at the source.",
      version: "2.0.0"
    ),
    Entry(
      id: "first-word-stays",
      icon: "text.cursor",
      title: "Your first word stays in the transcript",
      description:
        "The opening word of a recording could sometimes disappear. Fixed. Dictation now starts where you start.",
      version: "2.0.0"
    ),
    Entry(
      id: "auto-language-actually-works",
      icon: "globe",
      title: "Auto language detection actually works",
      description:
        "Leave language on Auto and EnviousWispr will detect what you spoke instead of assuming English. Short clips also decide faster, so quick commands feel snappier.",
      version: "2.0.0"
    ),
    Entry(
      id: "stuck-model-loads-recover-sooner",
      icon: "arrow.clockwise.circle",
      title: "Stuck model loads recover sooner",
      description:
        "If a speech model gets wedged while loading, EnviousWispr now notices earlier and recovers without the long wait. Slow but healthy loads are left alone.",
      version: "2.0.0"
    ),
    Entry(
      id: "custom-words-fast-at-scale",
      icon: "speedometer",
      title: "Custom Words stays fast at scale",
      description:
        "Even very large custom-word lists now stay responsive during polish. Long replacements that used to get dropped now apply correctly, and a failed save no longer throws away what you typed.",
      version: "2.0.0"
    ),
    Entry(
      id: "auto-paste-clear-help",
      icon: "hand.raised",
      title: "Clear help when auto-paste needs access",
      description:
        "If Accessibility permission is missing, EnviousWispr now tells you exactly why paste could not happen and gives you a quick path to fix it. No more silent fallback to the clipboard.",
      version: "2.0.0"
    ),
    Entry(
      id: "update-when-ready",
      icon: "arrow.down.circle",
      title: "Update when you are ready",
      description:
        "New versions show up as a quiet in-app banner instead of an interrupting popup. You stay in flow, then update on your schedule.",
      version: "2.0.0"
    ),
    Entry(
      id: "stronger-privacy-by-default",
      icon: "lock.shield",
      title: "Stronger privacy, by default",
      description:
        "Cloud polish now opts out of training storage where supported. Crash reports scrub sensitive details before they leave your Mac. Stored files have tighter permissions. Gemini request logging is off. The Privacy section explains what each cloud provider keeps.",
      version: "2.0.0"
    ),

    // MARK: - v1.9.4

    Entry(
      id: "smoother-model-switching",
      icon: "arrow.triangle.swap",
      title: "Smoother model switching",
      description:
        "Switching between local AI polish models now frees up the previous model cleanly, so your Mac stays responsive and recordings keep working.",
      version: "1.9.4"
    ),
    Entry(
      id: "more-reliable-recordings",
      icon: "waveform.badge.checkmark",
      title: "More reliable recordings",
      description:
        "Fewer silent failures. The audio helper now recovers cleanly from a rare crash class, and the microphone bounces back better from bad states after long idle periods or audio interruptions.",
      version: "1.9.4"
    ),
    Entry(
      id: "ollama-download-progress",
      icon: "arrow.down.circle",
      title: "Ollama downloads show progress and can be cancelled",
      description:
        "The Manage Models row now shows a live progress bar while an Ollama model downloads, plus a Cancel button. No more wondering whether the download is stuck or how big it is.",
      version: "1.9.4"
    ),
    Entry(
      id: "faster-polish-after-pause",
      icon: "bolt.horizontal",
      title: "Faster first polish after a pause",
      description:
        "Your first dictation after a quiet stretch now gets polished faster. The pre-warm probe talks to the LLM the same way a real polish does, so the first real call doesn't pay a cold-start tax.",
      version: "1.9.4"
    ),
    Entry(
      id: "paste-chromium-electron",
      icon: "doc.on.clipboard",
      title: "Paste works in more apps",
      description:
        "Dictating into Chrome, Slack, Discord, VS Code, and other Electron-based apps now pastes cleanly even when the focused text field isn't fully reported. Previously the text would sometimes sit on the clipboard instead of landing in place.",
      version: "1.9.4"
    ),
    Entry(
      id: "gemma-3-nano",
      icon: "cpu",
      title: "Gemma 3 Nano joins the Ollama lineup",
      description:
        "Google's 4B Gemma 3 Nano is now available in the Ollama model picker. A tight on-device option for AI polish when you want speed and privacy and don't need a large model.",
      version: "1.9.4"
    ),

    // MARK: - v1.9.3

    Entry(
      id: "gemma4-polish-fixed",
      icon: "checkmark.seal",
      title: "Gemma 4 polish works again",
      description:
        "Local AI polish with Gemma 4 was quietly falling back to the raw transcript on every dictation. It now produces cleaned-up output reliably. Fillers are removed, punctuation is added, and lists are formatted, all running offline on your Mac.",
      version: "1.9.3"
    ),
    Entry(
      id: "thinking-models-supported",
      icon: "brain",
      title: "Better support for reasoning models",
      description:
        "Thinking models like Gemma 4, Qwen 3, QwQ, DeepSeek R1, and gpt-oss now have enough room to finish reasoning and still produce a clean polished answer. Smaller local models still run on the tight budget that keeps them fast and reliable.",
      version: "1.9.3"
    ),

    // MARK: - v1.9.2

    Entry(
      id: "multilingual-auto-detect",
      icon: "globe",
      title: "Dictate in 99+ languages",
      description:
        "EnviousWispr now auto-detects the language you are speaking and transcribes accordingly. German, Japanese, Arabic, Tamil, Mandarin and 95 others work out of the box with no setting change needed.",
      version: "1.9.2"
    ),
    Entry(
      id: "apple-intelligence-multilingual",
      icon: "sparkles",
      title: "Apple Intelligence polish stays in your language",
      description:
        "AI polish with Apple Intelligence now preserves the language you spoke in. German stays German, Korean stays Korean. Languages Apple Intelligence cannot handle are quietly skipped so you always get your raw transcript instead of a silent failure.",
      version: "1.9.2"
    ),
    Entry(
      id: "whisperkit-full-capture",
      icon: "text.badge.checkmark",
      title: "WhisperKit captures every word",
      description:
        "Fixed an issue where the last few words of a dictation could be silently dropped when using WhisperKit. Every word now reaches your clipboard.",
      version: "1.9.2"
    ),
    Entry(
      id: "ollama-long-dictation",
      icon: "timer",
      title: "Ollama handles long dictations",
      description:
        "Local AI polish with large models like Gemma 4 no longer times out on longer recordings. Timeout budgets now adapt to your provider.",
      version: "1.9.2"
    ),

    // MARK: - v1.9.1

    Entry(
      id: "whats-new-tab",
      icon: "sparkle.magnifyingglass",
      title: "What's New tab",
      description:
        "See what changed after every update, right here in Settings. The sidebar icon glows rainbow when there are unread notes.",
      version: "1.9.1"
    ),
    Entry(
      id: "smarter-paste-detection",
      icon: "doc.on.clipboard",
      title: "Smarter paste detection",
      description:
        "Transcribed text now pastes correctly into Slack, Discord, and other Electron apps that were previously missed.",
      version: "1.9.1"
    ),
    Entry(
      id: "clipboard-fallback-overlay",
      icon: "rectangle.on.rectangle",
      title: "Clipboard fallback overlay",
      description:
        "When no text field is selected, your transcription is copied to the clipboard and a notification tells you to press Cmd+V.",
      version: "1.9.1"
    ),

    // MARK: - v1.9.0

    Entry(
      id: "context-aware-prompts",
      icon: "brain.head.profile",
      title: "Context-aware prompts",
      description:
        "Each AI provider now gets prompts optimized for its strengths, producing better polish results.",
      version: "1.9.0"
    ),
    Entry(
      id: "apple-intelligence-guardrails",
      icon: "sparkles",
      title: "Apple Intelligence guardrails",
      description:
        "AI polish no longer over-edits your text or answers questions instead of polishing them. Five protective rules keep your words intact.",
      version: "1.9.0"
    ),
    Entry(
      id: "repolish-from-history",
      icon: "arrow.clockwise",
      title: "Re-polish from History",
      description:
        "The Enhance button on existing transcripts now works correctly for all speech engine types.",
      version: "1.9.0"
    ),
    Entry(
      id: "auto-discover-models",
      icon: "server.rack",
      title: "Auto-discover models",
      description:
        "New Ollama models appear automatically once downloaded. No more hardcoded lists.",
      version: "1.9.0"
    ),
    Entry(
      id: "warmup-indicator",
      icon: "gauge.with.dots.needle.33percent",
      title: "Warm-up indicator",
      description:
        "See when your Ollama model is loading into GPU memory with a live status spinner.",
      version: "1.9.0"
    ),
    Entry(
      id: "native-ollama-api",
      icon: "bolt.horizontal",
      title: "Native API",
      description:
        "Switched to Ollama's native API for better compatibility with reasoning models like Gemma 4.",
      version: "1.9.0"
    ),
    Entry(
      id: "instant-first-press",
      icon: "hare",
      title: "Instant first press",
      description:
        "Eliminated the delay on your very first recording. The speech engine warms up at launch.",
      version: "1.9.0"
    ),
    Entry(
      id: "no-phantom-text",
      icon: "waveform.slash",
      title: "No more phantom text",
      description:
        "Fixed the #1 reported issue: holding the record button in silence no longer produces hallucinated words.",
      version: "1.9.0"
    ),
    Entry(
      id: "whispered-speech",
      icon: "ear",
      title: "Whispered speech captured",
      description:
        "Improved whispered-speech detection. Very quiet or clipped recordings may still be misheard.",
      version: "1.9.0"
    ),
    Entry(
      id: "paste-back-fix",
      icon: "doc.on.clipboard",
      title: "Paste-back fix",
      description:
        "Fixed a macOS 14+ issue where transcribed text sometimes failed to paste into the target app.",
      version: "1.9.0"
    ),
    Entry(
      id: "configurable-engine-timeout",
      icon: "timer",
      title: "Configurable engine timeout",
      description:
        "Choose how long to keep the microphone warm between recordings: 10s, 30s, 60s, or always.",
      version: "1.9.0"
    ),
    Entry(
      id: "better-error-messages",
      icon: "exclamationmark.bubble",
      title: "Better error messages",
      description:
        "Clearer notifications when something goes wrong, with distinct warnings for partial vs. complete failures.",
      version: "1.9.0"
    ),
  ]

  /// All distinct versions in the entries, sorted newest first.
  static var versions: [String] {
    let unique = Set(entries.map(\.version))
    return unique.sorted { lhs, rhs in
      lhs.compare(rhs, options: .numeric) == .orderedDescending
    }
  }

  /// Entries grouped by version (newest first). Within a version, entries render in
  /// SOURCE ORDER: the author controls the sequence by where they place the `Entry`
  /// in `entries`.
  ///
  /// There is no category tier. Each entry is its own titled card, so this order IS
  /// the hierarchy the user reads, in the app and in the generated GitHub release
  /// notes alike. Nothing re-sorts or groups it. Author each version
  /// headline-feature-first: the first entry is that release's pitch.
  static var entriesByVersion: [(version: String, entries: [Entry])] {
    versions.map { version in
      (version, entries.filter { $0.version == version })
    }
  }
}
