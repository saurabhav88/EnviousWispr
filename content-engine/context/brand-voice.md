# EnviousWispr Brand Voice & Messaging

This document defines the EnviousWispr brand voice, tone, and messaging framework. Reference this when writing all content to ensure consistency.

## Voice Pillars

### 1. Privacy without paranoia

- **What it means:** Privacy is a product fact, not a fear campaign. EnviousWispr should explain exactly what stays local, what doesn't, and when exceptions apply. The voice should build trust through specificity, not ominous warnings.
- **How it sounds:**
  - Calm, factual, explicit
  - Clear about data flow
  - User-choice centered: "unless you explicitly configure..."
  - Never preachy or conspiratorial
- **Example:** "Your recordings never leave your Mac unless you explicitly configure an external API."
- **What to avoid:**
  - Fearmongering: "Big Tech is always listening"
  - Empty trust claims: "military-grade privacy"
  - Overstating: "100% offline" if optional cloud integrations exist
  - Vague hand-waving: "we take privacy seriously"

### 2. Technical clarity that stays readable

- **What it means:** EnviousWispr should name the real implementation when it matters--WhisperKit, Core ML, Apple Silicon, local LLMs--but always in service of user understanding. It should sound like a builder explaining how the system works, not a marketer hiding behind buzzwords.
- **How it sounds:**
  - Specific, literate, grounded
  - Technical nouns are welcome
  - Explanations stay tied to outcomes
  - Assumes the reader is smart, not necessarily specialized
- **Example:** "Transcription happens locally using WhisperKit, which runs Apple's Whisper model natively via Core ML."
- **What to avoid:**
  - Acronym soup without context
  - Over-explaining basics to technical readers
  - Buzzword stacking: "edge-native multimodal AI pipeline"
  - Treating implementation details like flexes

### 3. Practical over promotional

- **What it means:** Talk about what the product does in real workflows. Focus on actions, speed, setup, and everyday usefulness. The brand sounds like a toolmaker, not a hype machine.
- **How it sounds:**
  - Workflow-first
  - Concrete verbs
  - Real examples: Slack, terminal, writing app, clipboard
  - Benefits shown through usage, not adjectives
- **Example:** "Hold a hotkey, speak, release. A second or two later, the text is on your clipboard or pasted into the app you're already using."
- **What to avoid:**
  - "Revolutionary"
  - "Game-changing"
  - "Seamless productivity platform"
  - Feature dumping with no user scenario

### 4. Opinionated simplicity

- **What it means:** The voice should confidently reject false trade-offs and complexity for its own sake. EnviousWispr is for people who want a tool that is powerful but straightforward. When you simplify, sound intentional, not minimal for marketing reasons.
- **How it sounds:**
  - Direct
  - Slightly sharp when pointing out bad trade-offs
  - Uses contrast well: "either/or," "both," "without compromise"
  - Comfortable saying what not to do
- **Example:** "We got tired of the trade-off: either use a fast cloud tool or an offline tool that feels like it was designed in 2012."
- **What to avoid:**
  - Being snarky for the sake of it
  - Being vague about why simplicity matters
  - Sounding anti-feature or anti-power-user
  - Pretending all trade-offs disappear in every case

### 5. Open-source honesty

- **What it means:** Open source is not just a licensing detail. It shapes the tone: transparent, inspectable, community-aware, and low-ego. The brand should sound accessible to contributors and respectful to users.
- **How it sounds:**
  - Straightforward
  - Welcoming but not performative
  - Proud of being free/open source without self-congratulation
  - Honest about setup, limitations, and rough edges
- **Example:** "No account, no API key, no subscription. EnviousWispr is free and open source."
- **What to avoid:**
  - Tribal rhetoric: "Unlike closed-source sellouts..."
  - Fake community language: "Join the movement"
  - Overpromising support beyond capacity
  - Hiding rough edges to seem polished

## General Tone

The EnviousWispr tone is that of a senior engineer explaining a brilliant open-source tool to a respected peer. It is confident, direct, and entirely devoid of marketing fluff. We write with a focus on problem-solving, acknowledging the frustrations of modern software (trade-offs, subscriptions, privacy violations) and offering a clean, technical solution. We don't boast; we simply state what the app does, how fast it does it, and how it works under the hood. It's professional but distinctly anti-corporate.

## Tone Variations by Content Type

### How-to guides

**Primary tone:** calm, procedural, reassuring
**Goal:** reduce friction and get the user to success quickly

- Step-by-step
- Specific about buttons, settings, permissions, models
- Reassure around anything that takes time or looks unusual
- Anticipate likely failure points

**Use lines like:**
- "On first launch, macOS will ask for microphone access."
- "The first model download takes a few minutes. After that, you're done."
- "If paste isn't working, check Accessibility permissions first."

**Avoid:**
- Big-picture philosophy up top
- Long intros before the first actionable step
- Vague troubleshooting

### Strategy content

**Primary tone:** sharper, more thesis-driven, still grounded
**Goal:** explain why the product exists and what trade-off it rejects

- Clear point of view
- Frames the market as trade-offs and design choices
- Uses strong but defensible language

**Use lines like:**
- "Voice tools shouldn't force you to choose between speed and privacy."
- "Local-first software doesn't have to feel like a fallback."

**Avoid:**
- Grand industry manifestos
- Generic startup rhetoric
- Dunking on competitors without evidence

### Product content

**Primary tone:** benefit-first, concrete, crisp
**Goal:** show what the product does and why it's worth using daily

- Start with the user action or job to be done
- Follow with the mechanism
- Emphasize workflow fit and speed

**Use lines like:**
- "Speak into Slack one way and your writing app another with per-app presets."
- "Hands-free mode lets EnviousWispr keep transcribing in the background."

**Avoid:**
- Dense capability lists
- "AI-powered" as a stand-in for explanation
- Overclaiming performance across all hardware

### Comparison content

**Primary tone:** fair, specific, unsentimental
**Goal:** help users choose based on trade-offs

- Respectful and factual
- Clear on where EnviousWispr wins and where others may fit better
- Uses concrete comparison axes: privacy, latency, setup, cost, customization

**Use lines like:**
- "Cloud tools usually win on zero-setup convenience. Local tools win on data control."
- "If you need dictation that works without sending recordings to a vendor, EnviousWispr is the better fit."

**Avoid:**
- Cheap shots
- "Best" without criteria
- Pretending there are no trade-offs

## Core Brand Messages

### Message 1: You shouldn't have to trade privacy for speed

- **Concept:** The central brand thesis: fast dictation and strong privacy can coexist.
- **Key points:**
  - Cloud speed vs. offline privacy is a false trade-off
  - EnviousWispr keeps transcription and post-processing on-device
  - External APIs are optional, not required
  - Privacy is default behavior, not a paid plan
- **Best used in:** Homepage hero, launch posts, comparison pages, privacy explainer

### Message 2: Local-first can feel modern

- **Concept:** EnviousWispr is not "good for an offline tool." It is fast, usable, and current.
- **Key points:**
  - Hold hotkey, speak, release
  - End-to-end in seconds on Apple Silicon
  - Simple UX, not retro utility-software UX
  - Local performance should feel practical, not ideological
- **Best used in:** Product pages, demos, landing page copy, feature overviews

### Message 3: Power when you want it, simplicity when you don't

- **Concept:** The product is easy by default but customizable for serious workflows.
- **Key points:**
  - Core loop is simple
  - Custom prompts, per-app presets, hands-free mode add depth
  - Users stay in control
  - Works for both casual dictation and tuned personal workflows
- **Best used in:** Feature pages, persona messaging, onboarding, release notes

### Message 4: Free, open source, and not trying to lock you in

- **Concept:** EnviousWispr is transparent and user-respecting by design.
- **Key points:**
  - No account, no subscription
  - No forced vendor backend
  - Open source means inspectable, modifiable, community-driven
- **Best used in:** GitHub README, pricing/about pages, FAQ, trust messaging

## Value Propositions by Persona

**Writer:** Dictate your drafts at the speed of thought, with a local LLM automatically fixing your punctuation and formatting to match your unique style.

**Parent:** Capture fleeting ideas hands-free while managing the kids, with zero risk of your family's background audio being uploaded to a corporate server.

**Coder:** Dictate terminal commands or code documentation effortlessly using per-app presets that automatically understand and format developer syntax.

**Exec:** Draft sensitive memos and emails instantly, with the absolute guarantee that your confidential company data never leaves your MacBook.

**Student:** Transcribe lectures and dictate essays with top-tier accuracy for free--no subscriptions, no API keys, and no account limits.

**Podcaster:** Generate highly accurate, private show notes and transcripts locally using the robust Whisper large-v3-turbo model.

**Accessibility User:** Navigate your Mac and write effortlessly with a continuous, hands-free background transcription mode that respects your privacy.

**Remote Worker:** Quickly dictate Slack replies between meetings without worrying about background noise or conversations being sent to the cloud.

## Writing Style

### Sentence structure

- Prefer short to medium sentences
- Use longer technical sentences only when they carry real information
- Favor contrast constructions: "either X or Y", "both X and Y", "without compromise", "unless you explicitly..."
- Use plain declarative sentences for confidence: "Transcription happens locally."
- Use fragments sparingly for emphasis: "That's it."
- Use contractions: "we're," "you'll," "doesn't"

### Paragraph structure

- One idea per paragraph
- Start with the user problem or trade-off, not company self-congratulation
- Keep paragraphs tight: usually 2-4 sentences
- When introducing features, follow this order: (1) user benefit, (2) feature name, (3) implementation detail if helpful
- Use bullets for feature lists and setup steps
- Use bold labels in lists for scannability: "**Hands-free mode** -- ..."

### Word choice

**Prefer:** runs, records, transcribes, pastes, choose, configure, local, on-device, clipboard, prompt, preset, pause, explicit

**Avoid or severely limit:** revolutionary, cutting-edge, seamless, innovative, world-class, enterprise-grade, magical, powerful (unless paired with something concrete), intuitive (show why instead)

### Point of view

- Use "we" for company/product decisions
- Use "you" for user outcomes and actions
- Avoid third person corporate speak
- Sound like builders talking directly to users

### Rhythm

The best EnviousWispr copy alternates between: (1) a strong claim about the problem, (2) a precise description of what the product does, (3) a short practical example.

Example:

1. "Most dictation tools make you choose between speed and privacy."
2. "EnviousWispr runs transcription and cleanup locally on your Mac."
3. "So you can dictate into Slack or Notes without sending recordings to a vendor."

## Terminology -- Say This, Not That

1. **on-device** -- not "AI-powered in the cloud"
2. **runs on your Mac** -- not "hosted on our platform"
3. **your recordings never leave your device** -- not "enterprise-grade privacy protections"
4. **local-first** -- not "fully offline forever" (unless truly zero network dependency)
5. **explicitly configure an external API** -- not "connect to our backend"
6. **transcription** -- not "voice intelligence"
7. **post-processing** -- not "AI magic"
8. **hold a hotkey, speak, release** -- not "seamless voice workflow"
9. **pastes into the app that has focus** -- not "deep workflow integration"
10. **per-app presets** -- not "smart adaptive contexts"
11. **custom prompts** -- not "personalized AI experiences"
12. **pause processing** -- not "go incognito mode"
13. **free and open source** -- not "community-powered solution"
14. **no account, no API key, no subscription** -- not "frictionless onboarding"
15. **Apple Silicon** -- not "any Mac" (when discussing performance)
16. **open an issue on GitHub** -- not "contact our support organization"
17. **choose a Whisper model** -- not "activate the AI engine"
18. **takes a second or two on Apple Silicon** -- not "blazing fast on all devices"
19. **local LLM of choice** -- not "our proprietary assistant"
20. **privacy by default** -- not "privacy-focused innovation"

## Voice Examples

### Excellent EnviousWispr Voice

"Most dictation apps still make the same bad trade-off: fast if you trust someone else's servers, private if you're willing to use something clunky. EnviousWispr avoids that split. Hold a hotkey, speak, release, and a second or two later your text is cleaned up and ready in the app you're already using. The recording stays on your Mac unless you decide otherwise."

**Why this works:**
- Opens with a real trade-off
- Sounds opinionated without being melodramatic
- Explains the workflow in concrete terms
- Privacy claim is specific and conditional
- No fluff, no generic "AI productivity" phrasing

### Not EnviousWispr Voice

"EnviousWispr is a revolutionary next-generation voice AI platform that seamlessly transforms spoken content into enterprise-ready text with cutting-edge privacy and best-in-class performance. Powered by advanced machine learning, it delivers an intuitive user experience that empowers modern professionals to unlock unprecedented productivity."

**Why this fails:**
- Pure buzzword density
- No actual workflow or product behavior
- Privacy claim is vague and unverifiable
- Sounds like generic SaaS copy, not an open-source Mac app
- "Enterprise-ready," "best-in-class," and "unprecedented" are empty superlatives
- Could describe almost any AI product

## Quality Checklist

Before publishing any content, verify:

- [ ] Did we explicitly state how the feature works under the hood (e.g., naming the framework or model)?
- [ ] Have we removed all marketing buzzwords (revolutionize, game-changer, magic, supercharge)?
- [ ] Is the privacy benefit explained as a technical reality rather than a corporate promise?
- [ ] Are the instructions formatted as direct, active commands (e.g., "Download the .dmg")?
- [ ] Did we use em-dashes correctly to break up complex sentences and add emphasis?
- [ ] Is the copy completely free of requests to "sign up," "subscribe," or "create an account"?
- [ ] Did we mention Apple Silicon when discussing speed or performance?
- [ ] Are the paragraphs short (3-4 sentences max) and easily scannable?
- [ ] Did we direct users to GitHub for feedback or issues instead of a generic support channel?
- [ ] Does this sound like a senior developer talking to a respected peer?
- [ ] Did we mention BOTH transcription backends (WhisperKit and Parakeet) when describing how transcription works?
- [ ] Did we add cross-links to at least 2 related blog posts?
- [ ] Did we use 'Core ML' (with space), not 'CoreML'?
- [ ] Are all cited statistics verifiable? No fabricated citations or hallucinated reports?
- [ ] Did we avoid 'change the game' and other variants of banned buzzwords?
