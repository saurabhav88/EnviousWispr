import EnviousWisprCore
import Foundation

/// Static "What's New" content, decoupled from the view layer.
/// Update WhatsNewConstants.currentContentVersion in Core whenever entries change.
enum WhatsNewContent {
  enum Category: String, CaseIterable, Identifiable {
    case newFeatures = "New Features"
    case smarterAIPolish = "Smarter AI Polish"
    case betterOllamaSupport = "Better Ollama Support"
    case fasterAndMoreReliable = "Faster and More Reliable"
    case qualityOfLife = "Quality of Life"
    case privacyAndSecurity = "Privacy and Security"

    var id: String { rawValue }
    var title: String { rawValue }
  }

  struct Entry: Identifiable, Hashable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let category: Category
    let version: String
  }

  static let entries: [Entry] = [
    // MARK: - v2.3.2

    Entry(
      id: "chosen-microphone-recording-failure",
      icon: "mic.circle",
      title: "Fixed: recording could fail every time on a specific microphone",
      description:
        "If you picked a microphone by name instead of leaving it on Automatic, and that microphone was running at a sample rate other than the usual one, EnviousWispr could fail to record with the message \"XPC audio service is unreachable.\" It did not clear up on its own, and reinstalling or updating the app did not help, because the setting that caused it lives in macOS rather than in EnviousWispr. The app now reads the microphone's real settings before it starts listening, so recording works whatever rate your microphone is set to. If you have been stuck on this, updating is enough to fix it.",
      category: .fasterAndMoreReliable,
      version: "2.3.2"
    ),

    // MARK: - v2.3.1

    Entry(
      id: "reliable-first-run-download",
      icon: "arrow.down.circle",
      title: "First-run setup downloads are far more reliable",
      description:
        "Setting up EnviousWispr downloads a speech model, and on some networks that download could stall and leave you stuck before you ever got to dictate. We rebuilt how the app fetches it: the download now resumes on its own if your connection drops, falls back to a backup source when needed, and can no longer hang forever. If setup gets interrupted, reopening the app picks up right where it left off instead of starting over.",
      category: .fasterAndMoreReliable,
      version: "2.3.1"
    ),

    // MARK: - v2.3.0

    Entry(
      id: "eg1-native-polish",
      icon: "sparkles",
      title: "Meet EG-1, our new recommended polish engine",
      description:
        "EnviousWispr now ships its own AI polish model, trained specifically for dictation, and it is remarkably strong: a 94.7% pass rate across our 1,890-case benchmark, edging out the big cloud models. It shines exactly where built-in Apple Intelligence falls short: turning spoken lists into real lists, honoring your mid-sentence self-corrections, and breaking long dictations into clean paragraphs. It is fast, typically polishing a dictation in under a second, and completely offline: download it once and it runs entirely on your Mac, no account, no API key, no internet after setup. EG-1 is our recommended engine going forward.",
      category: .newFeatures,
      version: "2.3.0"
    ),
    Entry(
      id: "whisperkit-engine-redesign",
      icon: "waveform.badge.mic",
      title: "The All Languages engine, redesigned",
      description:
        "We rebuilt the All Languages engine from the ground up to transcribe live while you speak as well as in one pass at the end of a recording. Your text now lands almost immediately when you stop, no matter how long you talked, first words come through quicker, and the redesign makes the engine more robust: fewer imagined phrases like a stray \"thank you\" during quiet moments, and no more text going missing or repeating in longer recordings. To stream live, pick a specific language in Settings; with Auto-detect on, the engine waits for the full recording so it can identify your language accurately.",
      category: .newFeatures,
      version: "2.3.0"
    ),
    Entry(
      id: "settings-redesign",
      icon: "paintbrush",
      title: "Settings got a full visual refresh",
      description:
        "We updated the Settings page to be easier to read and navigate. Settings and History now share one polished, unified look, with roomier spacing, easier-to-read text, and a redesigned AI Polish tab where each engine has its own card with everything you need to set it up.",
      category: .qualityOfLife,
      version: "2.3.0"
    ),
    Entry(
      id: "ollama-misconfig-fix",
      icon: "checkmark.seal",
      title: "Smoother behavior when Ollama polish is not set up right",
      description:
        "If Ollama polish is selected but not properly set up, say the model is missing or Ollama is not running, the app no longer misbehaves. It tells you clearly what is wrong and delivers your unpolished text right away.",
      category: .betterOllamaSupport,
      version: "2.3.0"
    ),
    Entry(
      id: "ordinal-numbers-fix",
      icon: "textformat.123",
      title: "Smarter built-in number handling",
      description:
        "We improved the always-on, non-AI part of the pipeline that formats spoken numbers. Phrases like \"two hundredth anniversary\" and \"third-largest city\" now come out exactly right instead of turning into odd digit mixes.",
      category: .fasterAndMoreReliable,
      version: "2.3.0"
    ),

    // MARK: - v2.2.1

    Entry(
      id: "tail-clip-recovery",
      icon: "waveform.badge.checkmark",
      title: "Long dictations keep every last word",
      description:
        "Fixed a long-standing bug where the end of a longer dictation could go missing if you paused mid-sentence near the finish. The speech engine now catches and recovers those moments, so your closing words always land.",
      category: .fasterAndMoreReliable,
      version: "2.2.1"
    ),
    Entry(
      id: "cloud-polish-facelift",
      icon: "cloud.bolt",
      title: "Cloud AI polish got a facelift",
      description:
        "If you bring your own OpenAI or Gemini key, polish just got a major upgrade. We rewrote the prompt from the ground up and benchmarked it across 1,890 real dictation cases: pass rates jumped from about 70% to about 92%. You'll notice the difference most in paragraph breaks when you change topics, spoken lists becoming real lists, cleaner handling of mid-sentence self-corrections, grammar fixes, and emoji staying exactly where you put them.",
      category: .smarterAIPolish,
      version: "2.2.1"
    ),

    // MARK: - v2.2.0

    Entry(
      id: "dark-mode",
      icon: "circle.lefthalf.filled",
      title: "Dark mode has arrived",
      description:
        "EnviousWispr now has a dark mode. Match your system automatically, or pick light or dark yourself in Settings. Easier on the eyes for late-night dictation.",
      category: .newFeatures,
      version: "2.2.0"
    ),
    Entry(
      id: "hour-long-recordings",
      icon: "clock",
      title: "Record for up to an hour at a time",
      description:
        "You can now record for up to a full hour in one go. As you near the limit you get a gentle heads-up, and recording stops cleanly on its own so you never lose what you said.",
      category: .newFeatures,
      version: "2.2.0"
    ),
    Entry(
      id: "sharper-on-device-polish",
      icon: "wand.and.stars",
      title: "Sharper on-device polish",
      description:
        "The built-in, fully on-device polish got a real tune-up. It cleans up filler and phrasing more reliably, keeps the natural way you start a sentence, and leaves your wording alone when it should.",
      category: .smarterAIPolish,
      version: "2.2.0"
    ),
    Entry(
      id: "emoji-stay-put",
      icon: "face.smiling",
      title: "Your emoji stay put",
      description:
        "Dictate an emoji and it now stays exactly where you placed it after polish runs. No more emoji going missing or landing in the wrong spot.",
      category: .smarterAIPolish,
      version: "2.2.0"
    ),
    Entry(
      id: "clearer-polish-failure-reasons",
      icon: "exclamationmark.bubble",
      title: "Clearer reasons when polish can't finish",
      description:
        "If cloud or on-device AI polish ever cannot finish, EnviousWispr now tells you specifically what happened and what to do, instead of a vague notice. Either way, your clean transcription is always delivered.",
      category: .smarterAIPolish,
      version: "2.2.0"
    ),
    Entry(
      id: "crash-recovery",
      icon: "arrow.clockwise.circle",
      title: "Your words survive an unexpected quit",
      description:
        "If the app ever closes in the middle of a dictation, your recording is no longer lost. When you reopen EnviousWispr it quietly picks up where it left off and finishes turning your words into text.",
      category: .fasterAndMoreReliable,
      version: "2.2.0"
    ),
    Entry(
      id: "ap-style-numbers",
      icon: "textformat.123",
      title: "Numbers written the way you would write them",
      description:
        "Numbers now come out the way you would actually type them: small ones spelled out, larger ones as digits, following the same style most newsrooms use. That means less cleanup for you.",
      category: .fasterAndMoreReliable,
      version: "2.2.0"
    ),
    Entry(
      id: "no-clipped-last-words",
      icon: "waveform",
      title: "No more clipped last words",
      description:
        "We fixed a case where a quick, energetic word or two at the very end of a dictation could get trimmed off. Your full sentence now makes it through.",
      category: .fasterAndMoreReliable,
      version: "2.2.0"
    ),
    Entry(
      id: "paste-never-waits-on-history",
      icon: "checkmark.circle",
      title: "Pasting never waits on saving",
      description:
        "Even if saving a dictation to your History runs into a snag, your words still land where you are typing. Delivery no longer waits on the archive.",
      category: .fasterAndMoreReliable,
      version: "2.2.0"
    ),
    Entry(
      id: "voiceover-and-keyboard",
      icon: "accessibility",
      title: "Built for VoiceOver and keyboard navigation",
      description:
        "EnviousWispr now reads cleanly with VoiceOver and is fully operable from the keyboard. Its hotkey recorders, buttons, and update prompts announce themselves clearly and respond to keyboard control.",
      category: .qualityOfLife,
      version: "2.2.0"
    ),
    Entry(
      id: "clearer-polish-on-older-macs",
      icon: "sparkles",
      title: "Clearer polish on older Macs",
      description:
        "On Macs that cannot run Apple's on-device polish, EnviousWispr no longer shows a confusing \"polish failed\" note. It simply hands you your clean transcription, and onboarding now explains your polish options up front.",
      category: .qualityOfLife,
      version: "2.2.0"
    ),
    Entry(
      id: "words-stay-out-of-diagnostics",
      icon: "lock.shield",
      title: "Your words stay out of diagnostics",
      description:
        "We added another layer to make sure your dictated words can never end up in crash reports or diagnostics. What you say stays yours.",
      category: .privacyAndSecurity,
      version: "2.2.0"
    ),
    Entry(
      id: "open-source-and-verifiable",
      icon: "chevron.left.forwardslash.chevron.right",
      title: "Open source, and easy to verify",
      description:
        "EnviousWispr is open source under the GPLv3 license, and every download now points you straight to the full source. You can see exactly what the app does.",
      category: .privacyAndSecurity,
      version: "2.2.0"
    ),

    // MARK: - v2.1.4

    Entry(
      id: "paste-works-in-word-excel-pages",
      icon: "doc.richtext",
      title: "Pasting now lands in Word, Excel, and more",
      description:
        "We fixed an issue where in some apps (Word, Excel, Pages, Numbers, OneNote, Sublime Text, Firefox) your dictation would say \"Copied\" but never actually paste. Your words now land in the document like everywhere else.",
      category: .fasterAndMoreReliable,
      version: "2.1.4"
    ),
    Entry(
      id: "small-ui-tweaks",
      icon: "sparkles",
      title: "Small UI tweaks for a cleaner experience",
      description:
        "A tidier sidebar status card, History columns that stay readable in small windows, more reliable update delivery, and an AI badge that only appears when AI actually ran.",
      category: .qualityOfLife,
      version: "2.1.4"
    ),

    // MARK: - v2.1.3

    Entry(
      id: "import-names-from-contacts",
      icon: "person.crop.circle.badge.plus",
      title: "Bring in the names of people you know",
      description:
        "One tap on \"Import from Contacts\" adds the people in your address book to your custom words, so a coworker's or friend's hard-to-spell name comes out right the first time. Everything stays on your Mac. Your contacts are never uploaded. EnviousWispr also quietly learns the common ways each name gets misheard, so it catches those too.",
      category: .newFeatures,
      version: "2.1.3"
    ),
    Entry(
      id: "vocabulary-packs",
      icon: "books.vertical",
      title: "Vocabulary packs for brands and jargon",
      description:
        "Turn on a pack and EnviousWispr recognizes those words and capitalizes them the way they're meant to be written (AngularJS, Nivea, Acosta). Each pack has a searchable list, so you can see every word it covers and the spoken variants it catches.",
      category: .newFeatures,
      version: "2.1.3"
    ),
    Entry(
      id: "no-swallowed-press-after-idle",
      icon: "clock.arrow.circlepath",
      title: "No more swallowed first press after a break",
      description:
        "If you left the app idle for a while, your next recording could get eaten while it flashed a \"warming up\" notice, even though it was basically ready. It now quietly re-wakes in a fraction of a second and captures your words, including the very first one.",
      category: .fasterAndMoreReliable,
      version: "2.1.3"
    ),
    Entry(
      id: "simpler-settings-performance",
      icon: "slider.horizontal.3",
      title: "One less Settings tab to hunt through",
      description:
        "The \"Performance\" tab held just one control: how long to keep the engine loaded between recordings. It now sits at the bottom of the Transcription screen, right where it belongs, so Settings has one less place to look.",
      category: .qualityOfLife,
      version: "2.1.3"
    ),

    // MARK: - v2.1.2

    Entry(
      id: "automatic-update-checks",
      icon: "sparkles",
      title: "EnviousWispr keeps itself current",
      description:
        "The app now looks for new versions on its own: when you open it, when you come back to it, and quietly in the background. So a waiting improvement finds you instead of you having to go looking. There's also a clear \"Check for Updates\" control in Settings if you ever want to look right now.",
      category: .newFeatures,
      version: "2.1.2"
    ),
    Entry(
      id: "soft-and-distant-speech-captured",
      icon: "waveform",
      title: "Soft and distant speech no longer gets dropped",
      description:
        "If you spoke quietly, whispered, or sat back from your mic, EnviousWispr would sometimes capture nothing at all. It now hears those faint and far-away words and writes them down, including a soft first word that used to get clipped off the start.",
      category: .fasterAndMoreReliable,
      version: "2.1.2"
    ),
    Entry(
      id: "no-false-warming-up-notice",
      icon: "bolt.badge.checkmark",
      title: "No more false \"warming up\" notice",
      description:
        "Tapping record again right after a quick tap or a \"changed my mind\" cancel could flash the \"warming up\" notice as if the app were starting cold, even though it was already warm and ready. That stray notice is gone: a warm app just records.",
      category: .qualityOfLife,
      version: "2.1.2"
    ),
    Entry(
      id: "removed-recording-environment-picker",
      icon: "slider.horizontal.3",
      title: "Removed a setting that promised something it didn't do",
      description:
        "The \"Recording Environment\" choice (Quiet, Normal, Noisy) sounded like it changed how well the app hears you in different surroundings. It never did that. We removed it so Settings only shows controls that actually do what they say.",
      category: .qualityOfLife,
      version: "2.1.2"
    ),

    // MARK: - v2.1.1

    Entry(
      id: "speak-naturally-see-it-written",
      icon: "textformat.123",
      title: "Speak it naturally, see it written",
      description:
        "EnviousWispr now formats what you dictate the way you actually mean it, automatically: phone numbers, money, percentages, years, dates, times, ordinals, decimals, number ranges, emails, and web addresses. Say \"five five five, one two three, four five six seven\" and you get 555-123-4567; \"eighty million dollars\" becomes $80 million; \"nineteen eighty seven\" becomes 1987. It even works when AI polish is turned off.",
      category: .newFeatures,
      version: "2.1.1"
    ),
    Entry(
      id: "more-reliable-updates",
      icon: "arrow.triangle.2.circlepath",
      title: "More reliable updates",
      description:
        "We improved how EnviousWispr installs new versions, so updates land cleanly instead of getting stuck partway. And if an update ever has trouble, the copy you already have keeps working.",
      category: .fasterAndMoreReliable,
      version: "2.1.1"
    ),

    // MARK: - v2.1.0

    Entry(
      id: "polish-keeps-your-words",
      icon: "checkmark.shield",
      title: "Polish keeps your words, not your commands",
      description:
        "Dictate something that sounds like an instruction, like \"draft a Slack to Matt about the launch\", and on-device polish used to sometimes go write that message instead of cleaning up what you said. It now recognizes the difference and keeps your actual words.",
      category: .smarterAIPolish,
      version: "2.1.0"
    ),
    Entry(
      id: "honest-warm-up-then-instant",
      icon: "gauge.with.dots.needle.33percent",
      title: "An honest warm-up, then instant presses",
      description:
        "Right after launch the speech engine takes a moment to warm up. You now see a clear indicator while that happens, instead of a start that looks frozen. Once it is warm, every press begins instantly with no flicker.",
      category: .fasterAndMoreReliable,
      version: "2.1.0"
    ),
    Entry(
      id: "whisperkit-on-gpu",
      icon: "bolt",
      title: "Faster WhisperKit transcription",
      description:
        "We moved the WhisperKit speech engine from your Mac's Neural Engine onto its GPU. In our testing that is the faster path for WhisperKit, so transcription warms up and finishes quicker.",
      category: .fasterAndMoreReliable,
      version: "2.1.0"
    ),
    Entry(
      id: "steadier-under-the-hood-2-1",
      icon: "wrench.and.screwdriver",
      title: "A steadier app under the hood",
      description:
        "We finished a major rebuild of how EnviousWispr is assembled and packaged. You won't see it directly, but it makes the app sturdier and lets us ship improvements to you faster and more safely.",
      category: .fasterAndMoreReliable,
      version: "2.1.0"
    ),

    // MARK: - v2.0.3

    Entry(
      id: "spoken-emoji",
      icon: "face.smiling",
      title: "Speak an emoji",
      description:
        "Say the emoji's name followed by the word \"emoji\" while you dictate, like \"smiley face emoji\" or \"thumbs up emoji\", and EnviousWispr drops the glyph right in.",
      category: .newFeatures,
      version: "2.0.3"
    ),
    Entry(
      id: "smart-language-detection",
      icon: "globe",
      title: "Smarter language detection",
      description:
        "On the Multi-Language speech engine, EnviousWispr now notices when you keep dictating in the same non-English language and offers to lock it in. A fixed language makes transcription both faster and more accurate.",
      category: .newFeatures,
      version: "2.0.3"
    ),
    Entry(
      id: "newer-ai-polish-models",
      icon: "sparkles",
      title: "Newer AI Polish models",
      description:
        "AI Polish now works with the latest models. We recommend Gemini 3.5 Flash, or OpenAI 5.4 mini or nano, for the best balance of speed and quality.",
      category: .smarterAIPolish,
      version: "2.0.3"
    ),
    Entry(
      id: "steadier-under-the-hood",
      icon: "wrench.and.screwdriver",
      title: "A steadier app under the hood",
      description:
        "We continued a major rebuild of how the app manages itself internally. You won't see it directly, but it makes EnviousWispr more stable and quicker for us to improve.",
      category: .fasterAndMoreReliable,
      version: "2.0.3"
    ),

    // MARK: - v2.0.2

    Entry(
      id: "right-option-push-to-talk",
      icon: "keyboard",
      title: "One key to talk",
      description:
        "Push-to-talk now defaults to a single tap of Right Option. Faster to reach than a two-key combo, and easier to remember. You can still remap it in Settings.",
      category: .qualityOfLife,
      version: "2.0.2"
    ),
    Entry(
      id: "ai-polish-keys-in-keychain",
      icon: "lock.shield",
      title: "AI Polish keys live in your keychain",
      description:
        "Your API keys for AI Polish are now stored in your Mac's keychain, the same secure place your other passwords live. Existing keys were moved over automatically.",
      category: .privacyAndSecurity,
      version: "2.0.2"
    ),
    Entry(
      id: "cleaner-audio-settings",
      icon: "slider.horizontal.3",
      title: "Cleaner audio settings",
      description:
        "Removed the noise suppression toggle. It wasn't doing what its name suggested, and a quieter settings panel is one less thing to wonder about.",
      category: .qualityOfLife,
      version: "2.0.2"
    ),
    Entry(
      id: "update-banner-stays-put",
      icon: "arrow.down.circle",
      title: "Update reminder stays put",
      description:
        "When a new version is ready, the in-app banner now stays visible until you install. No more dismissing it and forgetting it was there.",
      category: .qualityOfLife,
      version: "2.0.2"
    ),

    // MARK: - v2.0.1

    Entry(
      id: "better-error-logging",
      icon: "doc.text.magnifyingglass",
      title: "Better error logging",
      description:
        "Improved our error logging so we can spot issues and enhance your experience faster.",
      category: .fasterAndMoreReliable,
      version: "2.0.1"
    ),

    // MARK: - v2.0.0

    Entry(
      id: "welcome-to-2-0",
      icon: "sparkles",
      title: "Welcome to EnviousWispr 2.0",
      description:
        "EnviousWispr 2.0 is about trust. Better text on the first try, sharper memory for your words, and fewer moments where you have to step in.",
      category: .newFeatures,
      version: "2.0.0"
    ),
    Entry(
      id: "your-words-has-a-real-home",
      icon: "books.vertical",
      title: "\"Your Words\" has a real home now",
      description:
        "Learning, Vocab Packs, and Custom Terms each have their own section in Settings. Easier to see what EnviousWispr remembers, what you added yourself, and where to tune it.",
      category: .newFeatures,
      version: "2.0.0"
    ),
    Entry(
      id: "afm-dual-mode-polish",
      icon: "wand.and.stars",
      title: "Apple Intelligence keeps your voice and your precision",
      description:
        "On-device polish keeps your voice and your precision. Casual notes keep your tone. Code, jargon, and careful business writing keep their precision. Six months of tuning underpins this.",
      category: .smarterAIPolish,
      version: "2.0.0"
    ),
    Entry(
      id: "custom-terms-survive-on-device-polish",
      icon: "tag.circle",
      title: "Your custom terms now survive on-device polish",
      description:
        "Words you teach EnviousWispr now carry through to Apple Intelligence polish, not just cloud polish. Product names, client names, and domain terms are far less likely to get cleaned into the wrong thing.",
      category: .smarterAIPolish,
      version: "2.0.0"
    ),
    Entry(
      id: "less-fiddling-better-polish",
      icon: "slider.horizontal.3",
      title: "Less fiddling, better polished text",
      description:
        "Formal, Standard, and Friendly are gone. They rarely changed the result and could quietly bypass smart routing on Apple Intelligence. There is now one quality-tuned default that delivers more consistently.",
      category: .smarterAIPolish,
      version: "2.0.0"
    ),
    Entry(
      id: "pick-polish-model-faster",
      icon: "list.bullet.rectangle",
      title: "Pick the right polish model faster",
      description:
        "Polish models are now grouped by provider with a short note on what each one is good at. Less hunting, better choices.",
      category: .smarterAIPolish,
      version: "2.0.0"
    ),
    Entry(
      id: "smarter-new-word-suggestions",
      icon: "quote.bubble",
      title: "Adding a new word is smarter now",
      description:
        "When you add a custom term, EnviousWispr suggests likely spellings and pronunciations to catch. Repetitive or low-quality suggestions are filtered out more aggressively.",
      category: .smarterAIPolish,
      version: "2.0.0"
    ),
    Entry(
      id: "cleaner-transcription-before-polish",
      icon: "waveform",
      title: "Cleaner transcription before polish",
      description:
        "The speech engine is now faster and steadier, especially on longer recordings. Fewer odd substitutions and cleaner raw text before polish even runs.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "no-more-phantom-thank-you",
      icon: "speaker.slash",
      title: "No more phantom \"Thank you\"",
      description:
        "Silent endings used to occasionally produce a fake \"Thank you.\" That hallucination is now suppressed at the source.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "first-word-stays",
      icon: "text.cursor",
      title: "Your first word stays in the transcript",
      description:
        "The opening word of a recording could sometimes disappear. Fixed. Dictation now starts where you start.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "auto-language-actually-works",
      icon: "globe",
      title: "Auto language detection actually works",
      description:
        "Leave language on Auto and EnviousWispr will detect what you spoke instead of assuming English. Short clips also decide faster, so quick commands feel snappier.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "stuck-model-loads-recover-sooner",
      icon: "arrow.clockwise.circle",
      title: "Stuck model loads recover sooner",
      description:
        "If a speech model gets wedged while loading, EnviousWispr now notices earlier and recovers without the long wait. Slow but healthy loads are left alone.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "custom-words-fast-at-scale",
      icon: "speedometer",
      title: "Custom Words stays fast at scale",
      description:
        "Even very large custom-word lists now stay responsive during polish. Long replacements that used to get dropped now apply correctly, and a failed save no longer throws away what you typed.",
      category: .fasterAndMoreReliable,
      version: "2.0.0"
    ),
    Entry(
      id: "auto-paste-clear-help",
      icon: "hand.raised",
      title: "Clear help when auto-paste needs access",
      description:
        "If Accessibility permission is missing, EnviousWispr now tells you exactly why paste could not happen and gives you a quick path to fix it. No more silent fallback to the clipboard.",
      category: .qualityOfLife,
      version: "2.0.0"
    ),
    Entry(
      id: "update-when-ready",
      icon: "arrow.down.circle",
      title: "Update when you are ready",
      description:
        "New versions show up as a quiet in-app banner instead of an interrupting popup. You stay in flow, then update on your schedule.",
      category: .qualityOfLife,
      version: "2.0.0"
    ),
    Entry(
      id: "stronger-privacy-by-default",
      icon: "lock.shield",
      title: "Stronger privacy, by default",
      description:
        "Cloud polish now opts out of training storage where supported. Crash reports scrub sensitive details before they leave your Mac. Stored files have tighter permissions. Gemini request logging is off. The Privacy section explains what each cloud provider keeps.",
      category: .privacyAndSecurity,
      version: "2.0.0"
    ),

    // MARK: - v1.9.4

    Entry(
      id: "smoother-model-switching",
      icon: "arrow.triangle.swap",
      title: "Smoother model switching",
      description:
        "Switching between local AI polish models now frees up the previous model cleanly, so your Mac stays responsive and recordings keep working.",
      category: .betterOllamaSupport,
      version: "1.9.4"
    ),
    Entry(
      id: "more-reliable-recordings",
      icon: "waveform.badge.checkmark",
      title: "More reliable recordings",
      description:
        "Fewer silent failures. The audio helper now recovers cleanly from a rare crash class, and the microphone bounces back better from bad states after long idle periods or audio interruptions.",
      category: .fasterAndMoreReliable,
      version: "1.9.4"
    ),
    Entry(
      id: "ollama-download-progress",
      icon: "arrow.down.circle",
      title: "Ollama downloads show progress and can be cancelled",
      description:
        "The Manage Models row now shows a live progress bar while an Ollama model downloads, plus a Cancel button. No more wondering whether the download is stuck or how big it is.",
      category: .betterOllamaSupport,
      version: "1.9.4"
    ),
    Entry(
      id: "faster-polish-after-pause",
      icon: "bolt.horizontal",
      title: "Faster first polish after a pause",
      description:
        "Your first dictation after a quiet stretch now gets polished faster. The pre-warm probe talks to the LLM the same way a real polish does, so the first real call doesn't pay a cold-start tax.",
      category: .fasterAndMoreReliable,
      version: "1.9.4"
    ),
    Entry(
      id: "paste-chromium-electron",
      icon: "doc.on.clipboard",
      title: "Paste works in more apps",
      description:
        "Dictating into Chrome, Slack, Discord, VS Code, and other Electron-based apps now pastes cleanly even when the focused text field isn't fully reported. Previously the text would sometimes sit on the clipboard instead of landing in place.",
      category: .fasterAndMoreReliable,
      version: "1.9.4"
    ),
    Entry(
      id: "gemma-3-nano",
      icon: "cpu",
      title: "Gemma 3 Nano joins the Ollama lineup",
      description:
        "Google's 4B Gemma 3 Nano is now available in the Ollama model picker. A tight on-device option for AI polish when you want speed and privacy and don't need a large model.",
      category: .betterOllamaSupport,
      version: "1.9.4"
    ),

    // MARK: - v1.9.3

    Entry(
      id: "gemma4-polish-fixed",
      icon: "checkmark.seal",
      title: "Gemma 4 polish works again",
      description:
        "Local AI polish with Gemma 4 was quietly falling back to the raw transcript on every dictation. It now produces cleaned-up output reliably. Fillers are removed, punctuation is added, and lists are formatted, all running offline on your Mac.",
      category: .betterOllamaSupport,
      version: "1.9.3"
    ),
    Entry(
      id: "thinking-models-supported",
      icon: "brain",
      title: "Better support for reasoning models",
      description:
        "Thinking models like Gemma 4, Qwen 3, QwQ, DeepSeek R1, and gpt-oss now have enough room to finish reasoning and still produce a clean polished answer. Smaller local models still run on the tight budget that keeps them fast and reliable.",
      category: .smarterAIPolish,
      version: "1.9.3"
    ),

    // MARK: - v1.9.2

    Entry(
      id: "multilingual-auto-detect",
      icon: "globe",
      title: "Dictate in 99 languages",
      description:
        "EnviousWispr now auto-detects the language you are speaking and transcribes accordingly. German, Japanese, Arabic, Tamil, Mandarin and 95 others work out of the box with no setting change needed.",
      category: .newFeatures,
      version: "1.9.2"
    ),
    Entry(
      id: "apple-intelligence-multilingual",
      icon: "sparkles",
      title: "Apple Intelligence polish stays in your language",
      description:
        "AI polish with Apple Intelligence now preserves the language you spoke in. German stays German, Korean stays Korean. Languages Apple Intelligence cannot handle are quietly skipped so you always get your raw transcript instead of a silent failure.",
      category: .smarterAIPolish,
      version: "1.9.2"
    ),
    Entry(
      id: "whisperkit-full-capture",
      icon: "text.badge.checkmark",
      title: "WhisperKit captures every word",
      description:
        "Fixed an issue where the last few words of a dictation could be silently dropped when using WhisperKit. Every word now reaches your clipboard.",
      category: .fasterAndMoreReliable,
      version: "1.9.2"
    ),
    Entry(
      id: "ollama-long-dictation",
      icon: "timer",
      title: "Ollama handles long dictations",
      description:
        "Local AI polish with large models like Gemma 4 no longer times out on longer recordings. Timeout budgets now adapt to your provider.",
      category: .betterOllamaSupport,
      version: "1.9.2"
    ),

    // MARK: - v1.9.1

    Entry(
      id: "whats-new-tab",
      icon: "sparkle.magnifyingglass",
      title: "What's New tab",
      description:
        "See what changed after every update, right here in Settings. The sidebar icon glows rainbow when there are unread notes.",
      category: .newFeatures,
      version: "1.9.1"
    ),
    Entry(
      id: "smarter-paste-detection",
      icon: "doc.on.clipboard",
      title: "Smarter paste detection",
      description:
        "Transcribed text now pastes correctly into Slack, Discord, and other Electron apps that were previously missed.",
      category: .qualityOfLife,
      version: "1.9.1"
    ),
    Entry(
      id: "clipboard-fallback-overlay",
      icon: "rectangle.on.rectangle",
      title: "Clipboard fallback overlay",
      description:
        "When no text field is selected, your transcription is copied to the clipboard and a notification tells you to press Cmd+V.",
      category: .qualityOfLife,
      version: "1.9.1"
    ),

    // MARK: - v1.9.0

    Entry(
      id: "context-aware-prompts",
      icon: "brain.head.profile",
      title: "Context-aware prompts",
      description:
        "Each AI provider now gets prompts optimized for its strengths, producing better polish results.",
      category: .smarterAIPolish,
      version: "1.9.0"
    ),
    Entry(
      id: "apple-intelligence-guardrails",
      icon: "sparkles",
      title: "Apple Intelligence guardrails",
      description:
        "AI polish no longer over-edits your text or answers questions instead of polishing them. Five protective rules keep your words intact.",
      category: .smarterAIPolish,
      version: "1.9.0"
    ),
    Entry(
      id: "repolish-from-history",
      icon: "arrow.clockwise",
      title: "Re-polish from History",
      description:
        "The Enhance button on existing transcripts now works correctly for all speech engine types.",
      category: .smarterAIPolish,
      version: "1.9.0"
    ),
    Entry(
      id: "auto-discover-models",
      icon: "server.rack",
      title: "Auto-discover models",
      description:
        "New Ollama models appear automatically once downloaded. No more hardcoded lists.",
      category: .betterOllamaSupport,
      version: "1.9.0"
    ),
    Entry(
      id: "warmup-indicator",
      icon: "gauge.with.dots.needle.33percent",
      title: "Warm-up indicator",
      description:
        "See when your Ollama model is loading into GPU memory with a live status spinner.",
      category: .betterOllamaSupport,
      version: "1.9.0"
    ),
    Entry(
      id: "native-ollama-api",
      icon: "bolt.horizontal",
      title: "Native API",
      description:
        "Switched to Ollama's native API for better compatibility with reasoning models like Gemma 4.",
      category: .betterOllamaSupport,
      version: "1.9.0"
    ),
    Entry(
      id: "instant-first-press",
      icon: "hare",
      title: "Instant first press",
      description:
        "Eliminated the delay on your very first recording. The speech engine warms up at launch.",
      category: .fasterAndMoreReliable,
      version: "1.9.0"
    ),
    Entry(
      id: "no-phantom-text",
      icon: "waveform.slash",
      title: "No more phantom text",
      description:
        "Fixed the #1 reported issue: holding the record button in silence no longer produces hallucinated words.",
      category: .fasterAndMoreReliable,
      version: "1.9.0"
    ),
    Entry(
      id: "whispered-speech",
      icon: "ear",
      title: "Whispered speech captured",
      description:
        "Quiet sensitivity mode now correctly captures whispered speech that was previously dropped.",
      category: .fasterAndMoreReliable,
      version: "1.9.0"
    ),
    Entry(
      id: "paste-back-fix",
      icon: "doc.on.clipboard",
      title: "Paste-back fix",
      description:
        "Fixed a macOS 14+ issue where transcribed text sometimes failed to paste into the target app.",
      category: .fasterAndMoreReliable,
      version: "1.9.0"
    ),
    Entry(
      id: "configurable-engine-timeout",
      icon: "timer",
      title: "Configurable engine timeout",
      description:
        "Choose how long to keep the microphone warm between recordings: 10s, 30s, 60s, or always.",
      category: .qualityOfLife,
      version: "1.9.0"
    ),
    Entry(
      id: "better-error-messages",
      icon: "exclamationmark.bubble",
      title: "Better error messages",
      description:
        "Clearer notifications when something goes wrong, with distinct warnings for partial vs. complete failures.",
      category: .qualityOfLife,
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

  /// Entries grouped by version (newest first), then by category within each version.
  static var groupedByVersion:
    [(version: String, sections: [(category: Category, entries: [Entry])])]
  {
    versions.map { version in
      let versionEntries = entries.filter { $0.version == version }
      let sections = Category.allCases.compactMap { category -> (Category, [Entry])? in
        let items = versionEntries.filter { $0.category == category }
        return items.isEmpty ? nil : (category, items)
      }
      return (version, sections)
    }
  }
}
