---
name: check-api-key-storage
description: "Use when auditing how API keys are stored and retrieved, modifying LLM connector initialization, or reviewing SettingsView persistence logic in EnviousWispr."
---

# Check API Key Storage

## Required Storage Path

All API keys must flow through `KeychainManager` with:
- Service identifier: `"com.enviouswispr.api-keys"`
- Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

**Never** store API keys in `UserDefaults`, `@AppStorage`, plist files, or source code.

## Files to Audit

### 1. KeychainManager
`Sources/EnviousWispr/LLM/KeychainManager.swift`

Verify:
- `store(key:value:)` uses `kSecClassGenericPassword`
- `retrieve(key:)` queries with `kSecAttrService: "com.enviouswispr.api-keys"`
- `delete(key:)` called before `store` to prevent duplicate-item errors
- Accessibility attribute is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

### 2. OpenAIConnector
`Sources/EnviousWispr/LLM/OpenAIConnector.swift`

Verify:
- API key is retrieved via `KeychainManager.retrieve(key: "openai-api-key")` (or equivalent)
- Key is NOT stored as a `let` constant initialized from a string literal
- Key is NOT read from `UserDefaults`

### 3. GeminiConnector
`Sources/EnviousWispr/LLM/GeminiConnector.swift`

Same checks as OpenAIConnector with key name `"gemini-api-key"` (or equivalent).

### 4. SettingsView / AI Polish Tab
`Sources/EnviousWispr/Views/Settings/SettingsView.swift`

Verify:
- Saving an API key field calls `KeychainManager.store(key:value:)`
- Loading for display calls `KeychainManager.retrieve(key:)` (masked for UI)
- No `@AppStorage` binding to an API key property

## Grep Commands

```bash
# Should return zero results — API keys in UserDefaults
grep -rn "UserDefaults.*[Kk]ey\|AppStorage.*[Kk]ey" Sources/EnviousWispr/LLM/ Sources/EnviousWispr/Views/Settings/

# Confirm KeychainManager is the only SecItem caller
grep -rn "SecItemAdd\|SecItemCopyMatching\|SecItemUpdate\|SecItemDelete" Sources/EnviousWispr/ | grep -v KeychainManager
# Should return zero results
```

## Pass Criteria

- All `SecItem*` calls are inside `KeychainManager` only.
- LLM connectors retrieve keys at request time, not at init time (avoids stale keys).
- Settings UI masks key display (e.g., `String(repeating: "•", count: 8)` or SecureField).
