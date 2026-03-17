# Wispr Flow Deep Scan Report
## Static Analysis — Competitive Intelligence for EnviousWispr
### March 2026

---

## Executive Summary

Wispr Flow (v1.4.484) is an Electron app with a native Swift helper for accessibility operations. Their ASR is 100% cloud-based — no local models. They've built an impressive feature set around text polishing, personalization styles, and contextual nudges, but their architecture carries the weight and security surface of Electron. Our native Swift approach is fundamentally leaner and more private.

---

## 1. Architecture: Electron + Swift Helper

This is not a native app. Wispr Flow is an Electron app with a separate native Swift helper for accessibility/paste operations.

- Main app: Electron (Node.js + Chromium), webpack-bundled, 6.5MB main JS bundle
- Swift helper (swift-helper-app-dist/): 6.5MB native binary, LSUIElement=true (hidden), handles AX tree inspection, clipboard, and audio interruption monitoring
- Bundle ID: com.electron.wispr-flow (main), com.electron.wispr-flow.accessibility-mac-app (helper)
- Min OS: macOS 12.0 (we require 14+ — tighter but more modern)
- Update mechanism: Squirrel framework (similar to our Sparkle)
- Database: SQLite via Sequelize ORM, 58 migrations since May 2024

The Swift helper contains these key types:
- AXElementWithProperties — AX tree traversal
- AudioInterruptionMonitor — handles audio route changes
- DelayedClipboardProvider — clipboard with delay (interesting pattern)
- EditedTextManager / EditedTextManager2 — text extraction from apps (v2 suggests a rewrite)
- FocusChangeDetector — tracks active app/window
- KeyboardService — key event handling
- VolumeManager — audio volume control
- IPCClient — communicates with Electron main process via IPC
- FeatureFlagCache — caches PostHog feature flags locally

---

## 2. ASR: 100% Cloud-Based

No local models. No WhisperKit. No CoreML. All audio goes to their servers.

API endpoints discovered:
- api.wisprflow.ai (primary)
- api-east.wisprflow.ai (east coast region)
- staging.wisprflow.ai (staging environment)
- cloud.wisprflow.ai / cloud.flowvoice.ai

Audio capture: Their AudioWorklet captures at 640-sample chunks (40ms at 16kHz) and streams to their API. The recorder worklet handles multiple input streams with synchronization checks.

Fallback system: Their database schema reveals fallback ASR tracking — usedFallbackAsr, usedFallbackFormatting, desiredAsr, fallbackAsrText, fallbackLevel — suggesting multiple ASR backends on their server with automatic failover.

Quality monitoring: They track divergence scores between ASR providers (fallbackAsrDivergenceScore) and between raw and formatted text (formattingDivergenceScore). They also store averageLogProb for confidence tracking.

Our advantage: We run ASR locally (Parakeet + WhisperKit). Zero network latency for transcription, works fully offline, no per-word cost, no privacy concerns from sending audio to external servers.

---

## 3. Text Processing Pipeline

Their pipeline flow is:

asrText -> formattedText (AI formatting) -> editedText (user edits) -> toneMatchedText (style matching) -> polishedText (Polish feature)

Each stage is tracked separately in the database with timestamps, word counts, and quality metrics.

---

## 4. Feature Map

### PTT (Push-to-Talk)
Hold Fn key to dictate. Their primary input mode, equivalent to our main hotkey.

### POPO — Polish in Place (Space + Fn)
Select existing text and polish it in-place using AI. This is essentially our EnviousType concept. They track it as a separate database table (Polish) with:
- polishInitialText / polishedText
- Word counts before and after
- Processing time
- Status enum: succeeded, long_text, short_text, timeout, error, cancelled, no_changes, not_editable, no_text, no_instructions
- Undo tracking (polishUndone)
- Custom instruction per polish
- Configurable polish instructions: "Make more concise", "Clarify main point", "Maintain your tone", "Reword for clarity", "Reorder for readability", "Refine phrasing for impact", "Add structure for readability"

### Flow Lens (Ctrl + Fn)
AI assistant with full AX context + screenshots. Stores multi-turn conversations with:
- role (user/assistant/system)
- Structured content (JSON)
- App context and URL
- AX text and AX HTML of the focused element
- Screenshot references
- Tool usage tracking

### Command Mode
Voice commands via wake word ("Hey Flow"). Tracks as transcriptCommand enum: ptt, popo, lens, command.

### Personalization Styles
Context-aware formality settings:
- Categories: work, email, personal, other
- Styles: formal, casual, default
- Stored per-transcript in personalizationStyleSettings JSON
- Onboarding flow to set initial preferences

### Auto-Cleanup Levels
Three tiers: low, medium, high. Controls how aggressively AI reformats dictated text. Includes a diff view with usage counting (diffShownCount).

### Dictionary / Custom Words
- Custom word corrections stored in Dictionary table
- Team sync support (lastTeamDictionarySyncTime)
- Auto-learn toggle (shouldAutoLearnWords)
- Source tracking per entry
- Snippets: Dictionary entries with isSnippet=true flag — trigger phrases that expand to longer text

### Notes
Built-in note-taking with sync:
- Title, content, contentPreview
- Sync status tracking
- Soft delete support

### Typing Reminder
Nudges users when they type instead of dictate. Configurable with mute option. Three escalating nudge variants.

### Voice Profile
Learns speaking patterns over time. Tracks:
- Processing status
- Superpower title/description (gamification)
- Peak time analysis
- Catch phrase detection
- Onboarding baseline words

---

## 5. Sound Design: 12 Iterations

They have 12 versioned sound packs, each containing: dictation-start.wav, dictation-stop.wav, paste.wav, popo-lock.wav, Notification.wav, achievement.wav.

Evolution trend:
- v1-v6: Larger files (~137KB each), included achievement sounds
- v7-v9: Dropped achievement sound, same sizes
- v10: Same structure
- v11-v11.4: Smaller dictation-start (43KB vs 137KB) — snappier feedback
- v12 (latest): All sounds resized — dictation-stop 80KB, paste 42KB, new Notification 81KB

---

## 6. Notification and Nudge System

90+ distinct notification types, each with rate limiting (lastShownTime + numTimesShown).

Categories:
- Error states: NoAudio, MicDisconnected, TranscriptionEmpty, TranscriptionError, DatabaseCorruptionError, DatabaseStorageFull, AudioWorkletLoadError, AudioQualityIssue
- Permission issues: NoMicrophonePerms, NoAccessibilityPerms, MicrophonePermissionRevoked, AccessibilityPermissionRevoked
- Feature discovery nudges: SuggestPOPO, MouseFlowDiscovery, CursorIntegrationSuggestion, PolishActivationNudge, SmartFormatting variants
- Monetization CTAs: ProTrialUpgradeCTA, TeamCTA, BasicUpgradeCTA, CommandModeUpgradeToPro, WeeklyWordsLimitReached, SugarDaddyCTA
- Engagement nudges: TypingReminder, ContextualNudge, UseCaseAppDictationNudge (3 variants), WiggleContextualNudge
- Polish-specific: PolishTextFailed, PolishTimeout, PolishEmptyResponse, PolishTextLessWords, PolishMaxWords, PolishTextNoChanges, PolishCancelled, PolishRunningWarning
- Paste-specific: PasteFailed, PasteBlocked, PostOnboardingFailedPaste
- Onboarding: OnboardingContinueNudge, PostOnboardingInAppDictation, PersonalizationOnboarding

---

## 7. Backend Services and Infrastructure

| Service | Purpose |
|---|---|
| Supabase (dodjkfqhwrzqjwkfnthl.supabase.co) | Auth, user data, team management, dictionary sync |
| PostHog (EU) | Analytics, feature flags, A/B testing |
| Sentry (2 orgs) | Crash reporting for both Electron and Swift helper |
| Squirrel | macOS auto-update framework |
| Stripe | Payment processing |

URL scheme: wispr-flow:// (for deep linking / OAuth callbacks)

---

## 8. Monetization Model

- Plan: FLOW_PRO_MONTHLY
- Trial: 14 days
- Free tier gating: WeeklyWordsLimitReached — they cap words per week for free users
- Team plans with domain-based grouping and admin join requests
- Student discount (isStudent flag)
- Referral system with codes
- Gift cards
- Trial extension system with daily reminders and goal tracking

---

## 9. Entitlements and Security

Their entitlements:
- com.apple.security.cs.allow-jit — required for V8 engine
- com.apple.security.cs.allow-unsigned-executable-memory
- com.apple.security.cs.disable-library-validation — can load any dylib
- com.apple.security.cs.allow-dyld-environment-variables
- com.apple.security.device.audio-input
- com.apple.security.device.camera — unclear why they need camera access

These are very permissive — necessary for Electron but a significant security surface area. Our native Swift app needs far fewer entitlements.

Signed by: Developer ID Application: Wispr AI INC (C9VQZ78H85), notarized and stapled.

---

## 10. Onboarding Flow

17 onboarding pages:
1. welcome-basic
2. about-yourself
3. spend-time-typing
4. introduction
5. work-environment
6. social-proof
7. privacy
8. permissions
9. microphone-test
10. shortcut
11. language
12. try-it-yourself
13. time-savings-nice-job
14. time-savings-speed-comparison
15. time-savings-final
16. flow-pro (upsell)
17. referral

Post-onboarding has additional steps with use-case selection and personalization style setup.

---

## 11. Key Takeaways for EnviousWispr

### Validate: Things they got right that we should learn from

1. POPO (Polish in Place) is their killer feature — validates our EnviousType direction
2. Personalization styles per context (work vs personal vs email) is smart UX
3. Sound design matters — 12 iterations shows this was high priority
4. Divergence score tracking between ASR outputs is clever quality monitoring
5. Comprehensive error notification system handles every edge case

### Differentiate: Where we win

1. Native Swift vs Electron — leaner, more secure, more responsive
2. Local ASR — zero latency, works offline, no privacy concerns
3. No word count gating — core functionality is not throttled
4. Simpler architecture — no IPC bridge between processes

### Consider: Features worth evaluating

1. Flow Lens (AI assistant with AX context)
2. Dictionary with team sync (maps to feature request #008)
3. Typing reminder nudges
4. Voice Profile / gamification
5. App-specific formatting rules

---

## Appendix: Database Schema Summary

### Tables
- History — main transcript storage (35+ columns)
- Dictionary — custom words + snippets with team sync
- Polish — text polishing history
- FlowLensHistory — AI assistant conversations
- Notes — built-in note-taking
- RemoteNotifications — push notification tracking

### Key History Columns
transcriptEntityId, asrText, formattedText, editedText, toneMatchedText, timestamp, audio (BLOB), screenshot (BLOB), additionalContext (JSON), status, app, url, e2eLatency, duration, numWords, language, detectedLanguage, averageLogProb, micDevice, conversationId, builtInAudio (BLOB), formattingDivergenceScore, pastedText, axText, axHTML, opusChunks (JSON), transcriptCommand, personalizationStyleSettings (JSON), clientNetworkLatency, fallbackLevel, speechDuration
