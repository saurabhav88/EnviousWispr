---
name: wispr-flag-sensitive-logging
description: "Use when reviewing LLM connectors, KeychainManager, or SettingsView for log statements that could leak API keys, auth tokens, or full API response bodies in EnviousWispr."
---

# Flag Sensitive Logging

## Files to Scan

Priority targets (highest risk of sensitive data in logs):
- `Sources/EnviousWispr/LLM/OpenAIConnector.swift`
- `Sources/EnviousWispr/LLM/GeminiConnector.swift`
- `Sources/EnviousWispr/LLM/KeychainManager.swift`
- `Sources/EnviousWispr/Views/Settings/SettingsView.swift`
- `Sources/EnviousWispr/App/AppState.swift`

## Grep Commands

```bash
# Find all print / NSLog / os_log / Logger statements
grep -rn "print(\|NSLog(\|os_log(\|\.debug(\|\.info(\|\.error(\|\.warning(" \
  Sources/EnviousWispr/LLM/ \
  Sources/EnviousWispr/Views/Settings/
```

Review every match manually for the patterns below.

## Unsafe Logging Patterns

### API key in log
```swift
// UNSAFE
print("Using key: \(apiKey)")
Logger.shared.debug("OpenAI key: \(openAIKey)")
```

### Full request body logged (may include key in Authorization header)
```swift
// UNSAFE
print("Request: \(urlRequest)")       // URLRequest prints headers including Authorization
print("Headers: \(request.allHTTPHeaderFields!)")
```

### Full API response body logged (may include completion text with user data)
```swift
// UNSAFE
print("Response: \(responseBody)")   // could be large; leaks user transcription + LLM output
```

### Keychain value in error path
```swift
// UNSAFE
print("Saved value: \(value) for key: \(key)")
```

## Safe Logging Patterns

```swift
// HTTP status code only
print("OpenAI response status: \(httpResponse.statusCode)")

// Latency
print("LLM polish took \(latency)ms")

// Token counts (metadata, not content)
print("Usage: prompt=\(usage.promptTokens) completion=\(usage.completionTokens)")

// Keychain: status code only
print("Keychain save status: \(status)")

// Boolean success
print("API key loaded: \(key != nil)")   // reveals presence, not value
```

## Rules

1. Never interpolate a variable named `key`, `apiKey`, `token`, `secret`, `password`, `bearer`, or `authorization` into a log string.
2. Never log `URLRequest` objects directly — they include Authorization headers.
3. Never log full response `Data` or decoded response bodies from LLM APIs.
4. Logging the character count of a response is acceptable: `"Response length: \(body.count)"`.
5. `os_log` with `.private` formatter (`%{private}@`) is acceptable for debug builds but still not ideal.

## On a Finding

Remove the sensitive interpolation. Replace with a safe alternative from the patterns above. If the information is genuinely needed for debugging, gate it behind `#if DEBUG` and use `.private` formatting.
