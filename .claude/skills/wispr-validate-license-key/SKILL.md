---
name: wispr-validate-license-key
description: "Use when implementing or auditing license key validation logic in EnviousWispr: online validation, JWT caching, offline grace period, and trial anti-reset."
---

# Validate License Key

> STUB — Implementation details TBD. Read `.claude/knowledge/accounts-licensing.md` first.

## Overview

Implements and verifies the full license validation lifecycle in `LicenseValidator.swift`.

## Key Format

```
WISPR-XXXXX-XXXXX-XXXXX-XXXXX
```

Character set: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no ambiguous chars). See accounts-licensing.md for full spec.

## Validation Flow

```
User enters key
      ↓
Validate format locally (regex)
      ↓
POST /v1/licenses/validate with key + device_id
      ↓ 200 OK
Cache JWT in Keychain ("license-token")
Store tier in UserDefaults ("com.enviouswispr.tier")
Store validation timestamp in UserDefaults
      ↓
Activate entitlements
```

## Format Validation (local, no network)

```swift
// Returns true if key matches WISPR-XXXXX-XXXXX-XXXXX-XXXXX pattern
static func isValidFormat(_ key: String) -> Bool {
    let pattern = #"^WISPR-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}-[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{5}$"#
    return key.range(of: pattern, options: .regularExpression) != nil
}
```

## Online Validation

- Endpoint: `POST https://api.enviouswispr.com/v1/licenses/validate`
- Require `device_id` (SHA-256 of IOPlatformUUID — never raw hardware ID)
- On 200: cache JWT in Keychain, update tier in UserDefaults
- On 422: surface user-friendly error, do NOT crash

## Offline Grace Period

1. On launch: attempt re-validation if online; skip if offline
2. If offline: check cached JWT `exp` claim
3. If JWT not expired: continue at current tier
4. If JWT expired: check `com.enviouswispr.license.last-validated` timestamp
5. If within 7 days: continue at current tier (grace period)
6. If beyond 7 days: silently downgrade to Free tier

## Audit Checklist

- [ ] License key never logged — only log validation status code
- [ ] JWT stored in Keychain (`"license-token"`), not UserDefaults
- [ ] Device ID is SHA-256 hashed before transmission
- [ ] Offline grace period capped at 7 days
- [ ] Downgrade to Free is silent (no crash, no lockout message unless UX requires)
- [ ] `LicenseValidator` is `actor` or `@MainActor` (no data races)

## Pass Criteria

- Valid key → tier activated, JWT cached, `UserDefaults` tier updated
- Invalid key → user-friendly error shown, no state change
- Network offline with fresh JWT → entitlements active
- Network offline with expired JWT past grace → downgrade to Free silently
