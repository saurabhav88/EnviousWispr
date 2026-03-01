---
name: wispr-scaffold-account-system
description: "Use when implementing the initial account system skeleton for EnviousWispr: user registration, login, session persistence, tier entitlements, and trial state machine."
---

# Scaffold Account System

> STUB — Implementation details TBD. Read `.claude/knowledge/accounts-licensing.md` first.

## Overview

Scaffolds the core account and entitlement infrastructure in `Sources/EnviousWispr/UserManagement/`.

## Files to Create

```
Sources/EnviousWispr/UserManagement/
    AccountManager.swift          # @MainActor actor — session, tier, entitlement checks
    EntitlementStore.swift        # Reads tier from UserDefaults, checks feature gates
    TrialManager.swift            # Trial state machine, expiry logic, anti-reset
    LicenseValidator.swift        # Online validation + offline JWT grace period
    UserManagementTypes.swift     # Tier enum, Entitlement enum, LicenseState enum
```

## Dependency Wiring

- `AccountManager` is a `let` property on `AppState` (follows DI pattern from `.claude/knowledge/conventions.md`)
- `EntitlementStore` is injected into any component that gates features
- `LicenseValidator` calls backend endpoint (see accounts-licensing.md for API contract)

## Tier Enum

```swift
enum Tier: String, Codable {
    case free = "free"
    case pro  = "pro"
    case team = "team"
}
```

## Entitlement Check Pattern

```swift
// At feature boundary (e.g., before LLM polish call)
guard await accountManager.entitlementStore.isEnabled(.llmPolish) else {
    // Show upgrade prompt
    return
}
```

## Key Storage Rules

- License JWT → Keychain via `KeychainManager` (key: `"license-token"`)
- Tier string → `UserDefaults` (key: `"com.enviouswispr.tier"`)
- Trial dates → `UserDefaults` (keys in accounts-licensing.md Key Storage Summary)

## Coordination

After scaffolding:
1. Message `auditor` (quality-security) to review Keychain usage and actor isolation
2. Message `builder` (build-compile) to validate build
3. Message `macos-platform` to scaffold the Account settings tab
