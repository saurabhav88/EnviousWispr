---
name: wispr-configure-analytics
description: "Use when implementing or auditing analytics collection in EnviousWispr: opt-in consent, event schema, anonymous identifiers, and provider selection."
---

# Configure Analytics

> STUB — Implementation details TBD. Read `.claude/knowledge/accounts-licensing.md` first.

## Overview

Implements privacy-respecting opt-in analytics in `Sources/EnviousWispr/Services/AnalyticsService.swift`.

## Privacy Rules (Non-Negotiable)

1. No telemetry without explicit user opt-in at first launch
2. No PII — no email, name, or identifying string
3. No transcript text content ever
4. No API keys or tokens in events
5. No file paths, usernames, or system identifiers

## File to Create

```
Sources/EnviousWispr/Services/AnalyticsService.swift
```

## Service Interface

```swift
@MainActor
actor AnalyticsService {
    static let shared = AnalyticsService()

    func track(_ event: AnalyticsEvent) async
    func optIn()
    func optOut()  // Also fires DELETE to backend
    var isOptedIn: Bool { get }
}
```

## Event Schema

```swift
enum AnalyticsEvent {
    case appLaunched(tier: String, version: String)
    case recordingStarted(trigger: RecordingTrigger, asrBackend: String)
    case transcriptionCompleted(durationMs: Int, wordCount: Int, hadPolish: Bool)
    case polishUsed(provider: String, latencyMs: Int)
    case trialExpired(daysUsed: Int, featuresUsedCount: Int)
    case licenseActivated(tier: String)
    case settingsChanged(settingKey: String)  // value NEVER included
}
```

## Opt-In Persistence

```swift
// Store in UserDefaults — not a secret
UserDefaults.standard.set(true, forKey: "com.enviouswispr.analytics.opted-in")

// Anonymous install ID generated once at first launch
if UserDefaults.standard.string(forKey: "com.enviouswispr.analytics.install-id") == nil {
    UserDefaults.standard.set(UUID().uuidString, forKey: "com.enviouswispr.analytics.install-id")
}
```

## Batching

- Buffer events locally in memory (max 100 events)
- Flush to backend at most once per hour, or on app quit
- If offline: retain buffer across sessions (write to a local JSON file in App Support)
- Discard buffer after successful flush

## Provider Options

Preferred (in order):
1. **TelemetryDeck** — Apple-ecosystem focused, GDPR-compliant by design, no IP logging
2. **PostHog** (self-hosted) — open source, full control, EU data residency possible

Do NOT use: Mixpanel, Amplitude, Firebase Analytics, Google Analytics.

## Wiring Into AppState

```swift
// AppState.swift
let analytics = AnalyticsService.shared

// Example call site (TranscriptionPipeline)
await appState.analytics.track(.transcriptionCompleted(
    durationMs: elapsed,
    wordCount: words,
    hadPolish: polished
))
```

## Opt-In Prompt

Show at first launch via a sheet or alert before any event is tracked. Must include:
- What is collected (list the event types)
- That no personal data or content is collected
- How to opt out later (Settings → Privacy)

## Audit Checklist

- [ ] No event fires before opt-in consent
- [ ] No transcript text in any event payload
- [ ] Install ID is a random UUID, not hardware-derived
- [ ] `settingsChanged` event includes key only, never value
- [ ] DELETE on opt-out removes data from backend
- [ ] `AnalyticsService` is `actor` — no data races on event buffer

## Pass Criteria

- First launch: no events tracked before consent screen is shown and confirmed
- Opted-out: zero network calls to analytics endpoint
- Opted-in: events batched and flushed, no PII in payload
