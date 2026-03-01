# Accounts & Licensing — EnviousWispr

Reference for user-management agent. Covers tier design, payment options, license key format, trial rules, and analytics privacy.

---

## Tier Matrix

| Feature | Free | Pro | Team |
|---------|------|-----|------|
| Transcription (Whisper local) | Yes | Yes | Yes |
| LLM polish | No | Yes | Yes |
| Custom word corrections | 10 entries | Unlimited | Unlimited |
| Transcription history | Last 20 | Unlimited | Unlimited |
| Offline mode (no network) | Yes | Yes | Yes |
| AI polish providers | — | OpenAI, Gemini | OpenAI, Gemini |
| Multiple language support | Yes | Yes | Yes |
| Priority model downloads | No | Yes | Yes |
| Team seat management | — | — | Yes (up to 25) |
| Centralized billing | — | — | Yes |
| SSO / managed accounts | — | — | Roadmap |
| Support tier | Community | Email | Priority |
| Price (suggested) | $0 | $8/mo or $72/yr | $15/seat/mo |

### Entitlement Identifiers

Use these string constants as entitlement keys in `UserDefaults` / Keychain:

```swift
enum Entitlement: String {
    case llmPolish       = "entitlement.llm-polish"
    case unlimitedWords  = "entitlement.unlimited-word-corrections"
    case unlimitedHistory = "entitlement.unlimited-history"
    case priorityModels  = "entitlement.priority-model-downloads"
    case teamManagement  = "entitlement.team-management"
}
```

Store the current tier as a non-sensitive string in `UserDefaults`:
```swift
UserDefaults.standard.set("pro", forKey: "com.enviouswispr.tier")
// Values: "free" | "pro" | "team"
```

Store license validation token in Keychain:
```swift
KeychainManager.store(key: "license-token", value: jwt)
```

---

## Payment Provider Options

### Option A — Stripe

**Pros:**
- Industry standard, developer-friendly API
- Full control over pricing, checkout, and webhook handling
- Works with Direct Sales model (no App Store cut)
- Excellent subscription management and proration
- Stripe Checkout embeds in a WKWebView or redirects to browser

**Cons:**
- Requires backend server for webhook processing and license issuance
- No native macOS SDK — web-based checkout flow
- 2.9% + $0.30 per transaction
- Must handle PCI compliance for card storage

**Best for:** Direct-to-consumer sales outside the Mac App Store (current plan).

---

### Option B — RevenueCat

**Pros:**
- Cross-platform entitlement management SDK
- Abstracts App Store Connect In-App Purchases
- Built-in analytics (MRR, churn, trials)
- Offline entitlement caching via SDK

**Cons:**
- Requires Mac App Store distribution (or custom implementation)
- 1% revenue fee above $2.5k/mo
- Tightly coupled to App Store payment flow
- Less control over checkout UX

**Best for:** If / when EnviousWispr ships on the Mac App Store with native IAP.

---

### Option C — Paddle

**Pros:**
- Merchant of Record — handles VAT/GST/sales tax globally
- No backend needed for tax compliance
- Supports direct distribution (no App Store)
- Flat 5% + $0.50 per transaction (includes tax handling)
- Native macOS overlay checkout available

**Cons:**
- Less developer ecosystem than Stripe
- Checkout UX slightly more limited
- Slower webhook delivery compared to Stripe

**Best for:** International sales where tax compliance complexity is a concern.

---

### Recommendation

**Phase 1 (launch):** Stripe — direct distribution, full control, best developer tooling.
**Phase 2 (App Store):** Add RevenueCat for in-app purchase flow alongside Stripe for direct.
**Phase 3 (international):** Evaluate Paddle for markets with complex tax requirements.

---

## License Key Format

### Structure

```
WISPR-XXXXX-XXXXX-XXXXX-XXXXX
```

- Prefix: `WISPR-` (product identifier)
- 4 groups of 5 alphanumeric characters (uppercase, no ambiguous chars: `0`, `O`, `I`, `1`)
- Character set: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (32 chars, Crockford-inspired)
- Total entropy: ~25 bits per group × 4 = ~100 bits

### Validation

License keys are validated against a backend endpoint. Do not embed validation secrets in the binary.

```
POST https://api.enviouswispr.com/v1/licenses/validate
Authorization: Bearer <device-token>
Body: { "key": "WISPR-XXXXX-XXXXX-XXXXX-XXXXX", "device_id": "<uuid>" }

Response 200: { "valid": true, "tier": "pro", "expires_at": "2027-01-01T00:00:00Z", "jwt": "<signed-token>" }
Response 422: { "valid": false, "reason": "already_activated|expired|revoked" }
```

### Offline Grace Period

- Cache the JWT locally in Keychain after successful validation.
- JWT includes `exp` claim (default: 30 days from activation).
- App re-validates on launch if online; uses cached JWT if offline.
- If JWT is expired AND offline: enforce 7-day grace period via a `UserDefaults` timestamp.
- After 7-day grace: downgrade to Free tier silently (no crash, no lockout).

```swift
UserDefaults.standard.set(Date(), forKey: "com.enviouswispr.license.last-validated")
```

---

## Trial Rules

### Trial Parameters (defaults, configurable server-side)

| Parameter | Value |
|-----------|-------|
| Duration | 14 days |
| Trial tier | Pro (full feature access) |
| Credit card required | No |
| Trial resets | Not allowed (keyed to hardware UUID) |
| Extension | Support can issue 7-day extensions via license key with prefix `TRIAL-` |

### Trial State Machine

```
[New Install]
      ↓
[Trial Active]  ← 14-day countdown from first launch
      ↓ (expires)
[Trial Expired] → Prompt to purchase → [Pro] or [Free downgrade]
      ↓ (purchase)
[Pro/Team Active]
```

### Trial State Persistence

```swift
// Non-sensitive — store in UserDefaults
UserDefaults.standard.set(Date(), forKey: "com.enviouswispr.trial.start-date")
UserDefaults.standard.set("active", forKey: "com.enviouswispr.trial.state")
// Values: "active" | "expired" | "converted"
```

### Anti-Trial-Reset

- Generate `device_id` from `IORegistryEntryCreateCFProperty` (IOPlatformUUID).
- Hash with SHA-256 before sending to backend.
- Backend rejects trial activation if device_id seen before.

---

## Analytics Privacy

### Data Collection Principles

1. **Opt-in only.** No telemetry collected without explicit user consent at first launch.
2. **No PII.** Never collect email, name, or any identifying string.
3. **Anonymized identifiers.** Use a random UUID generated at install, not hardware UUID.
4. **Local aggregation.** Batch events locally; flush at most once per hour.
5. **Deletable.** "Delete my data" in Settings triggers a DELETE call to analytics endpoint.

### Events Collected (when opted-in)

| Event | Properties | Purpose |
|-------|-----------|---------|
| `app_launched` | `tier`, `version` | Retention / DAU |
| `recording_started` | `trigger: hotkey\|button`, `asr_backend` | Feature adoption |
| `transcription_completed` | `duration_ms`, `word_count`, `had_polish` | Quality |
| `polish_used` | `provider: openai\|gemini\|ollama`, `latency_ms` | LLM adoption |
| `trial_expired` | `days_used`, `features_used_count` | Conversion funnel |
| `license_activated` | `tier` | Revenue |
| `settings_changed` | `setting_key` (no value) | Feature discovery |

### Events Never Collected

- Transcript text content
- API keys or tokens
- Microphone audio or samples
- File paths or usernames

### Analytics Storage

```swift
// Analytics opt-in — UserDefaults
UserDefaults.standard.set(true, forKey: "com.enviouswispr.analytics.opted-in")

// Anonymous install ID — UserDefaults (not Keychain — not a secret)
UserDefaults.standard.set(UUID().uuidString, forKey: "com.enviouswispr.analytics.install-id")
```

### Recommended Provider

**PostHog** (self-hostable, open source, privacy-friendly) or **TelemetryDeck** (Apple-focused, GDPR-compliant by design). Do not use Mixpanel, Amplitude, or Firebase Analytics — these are not GDPR-compliant by default.

---

## Key Storage Summary

| Data | Storage | Key |
|------|---------|-----|
| License JWT | Keychain | `"license-token"` |
| Current tier | UserDefaults | `"com.enviouswispr.tier"` |
| Trial start date | UserDefaults | `"com.enviouswispr.trial.start-date"` |
| Trial state | UserDefaults | `"com.enviouswispr.trial.state"` |
| Last validation timestamp | UserDefaults | `"com.enviouswispr.license.last-validated"` |
| Analytics opt-in | UserDefaults | `"com.enviouswispr.analytics.opted-in"` |
| Anonymous install ID | UserDefaults | `"com.enviouswispr.analytics.install-id"` |
| API keys (OpenAI, Gemini) | Keychain | `"openai-api-key"`, `"gemini-api-key"` |
