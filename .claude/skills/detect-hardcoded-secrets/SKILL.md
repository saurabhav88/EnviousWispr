---
name: detect-hardcoded-secrets
description: "Use when reviewing any commit, pull request, or new file for accidentally hardcoded API keys, tokens, or credentials in EnviousWispr source code."
---

# Detect Hardcoded Secrets

## Grep Patterns to Run

Run all commands from the repository root.

### OpenAI API keys (prefix: `sk-`)
```bash
grep -rn '"sk-' Sources/ Tests/
grep -rn "'sk-" Sources/ Tests/
```
Any match is a critical finding. Variable assignments like `let key = keychainManager.load(...)` are safe — flag string literals only.

### Google / Gemini API keys (prefix: `AIza`)
```bash
grep -rn '"AIza' Sources/ Tests/
grep -rn "'AIza" Sources/ Tests/
```

### Bearer tokens in Authorization headers
```bash
grep -rn 'Bearer [^\\]' Sources/ Tests/ | grep -v '"Bearer \\'  | grep -v 'Bearer \\('"'"
```
Safe pattern: `"Bearer \(apiKey)"` where `apiKey` is a variable. Flag: `"Bearer sk-abc123..."`.

### Key in URL query string
```bash
grep -rn 'key=[A-Za-z0-9_-]\{20,\}' Sources/ Tests/
```
Flag any literal value longer than 20 chars after `key=`.

### Generic long base64/hex literals (potential tokens)
```bash
grep -rn '"[A-Za-z0-9+/=_-]\{40,\}"' Sources/ Tests/
```
Review each match — many will be model identifiers or safe constants.

## False Positives to Ignore

- Model name strings: `"openai/whisper-large-v3"`, `"mlx-community/parakeet-..."` — not secrets
- URL base strings without embedded keys: `"https://api.openai.com/v1/chat/completions"` — safe
- SHA hashes in comments or test fixtures — document and ignore
- `kSecAttrService: "com.enviouswispr.api-keys"` — this is a keychain service label, not a key

## Files with Elevated Risk

- `Sources/EnviousWispr/LLM/OpenAIConnector.swift`
- `Sources/EnviousWispr/LLM/GeminiConnector.swift`
- `Sources/EnviousWispr/Views/Settings/SettingsView.swift`
- `Sources/EnviousWispr/LLM/KeychainManager.swift`
- Any file in `fixtures/` (test audio should not have embedded metadata with tokens)

## On a Finding

1. Remove the literal immediately.
2. Replace with a `KeychainManager.load(key:)` call.
3. Rotate the exposed credential — a committed key must be considered compromised.
4. Add file to `.gitignore` if it is a config file that should never be committed.
