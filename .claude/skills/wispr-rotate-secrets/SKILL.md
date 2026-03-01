# wispr-rotate-secrets

Rotate an API key or secret end-to-end: identify, generate, store, verify, revoke old.

## When to Use

- Suspected key compromise or leak detected by `wispr-detect-hardcoded-secrets`
- Scheduled rotation (quarterly, per-policy)
- Onboarding a new LLM provider or changing credentials

## Prerequisites

- Read `.claude/knowledge/gotchas.md` (API Keys section) before proceeding
- Identify which provider's key needs rotation: OpenAI, Gemini, or Ollama (local, no key)

## Procedure

### 1. Identify the Key

Determine which key to rotate:

| Provider | Storage key | Stored via |
|----------|-------------|------------|
| OpenAI | `openai-api-key` | `KeychainManager.store(key:service:)` |
| Gemini | `gemini-api-key` | `KeychainManager.store(key:service:)` |

Verify current key exists:

```swift
// In code — KeychainManager.retrieve(service:)
// From shell — check file exists at ~/.enviouswispr-keys/<key-name>
```

### 2. Generate New Key

- **OpenAI**: Generate at https://platform.openai.com/api-keys
- **Gemini**: Generate at https://aistudio.google.com/app/apikey
- Never generate keys programmatically from this skill — user must create via provider dashboard

### 3. Update Local Storage

Replace the key in `KeychainManager`:

```swift
try KeychainManager.store(key: "<new-key>", service: "com.enviouswispr.api-keys", account: "<provider>-api-key")
```

In debug builds, this writes to `~/.enviouswispr-keys/<provider>-api-key` (0600 permissions).
In release builds, this writes to macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

### 4. Update GitHub Secrets (if applicable)

For CI/CD secrets used in `.github/workflows/release.yml`:

```bash
# List current secrets
gh secret list

# Update a secret
gh secret set <SECRET_NAME> --body "<new-value>"
```

Relevant CI secrets: `DEVELOPER_ID_CERT_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_TEAM_NAME`, `SPARKLE_EDDSA_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY`

### 5. Verify New Key Works

Run a lightweight API call to confirm the new key is valid:

- **OpenAI**: `GET /v1/models` with new Bearer token — expect 200
- **Gemini**: `GET /v1beta/models?key=<new-key>` — expect 200

Use `wispr-validate-api-contracts` skill for structured verification.

### 6. Revoke Old Key

- **OpenAI**: Delete old key at https://platform.openai.com/api-keys
- **Gemini**: Delete old key at https://aistudio.google.com/app/apikey
- **GitHub secrets**: Old values are overwritten in step 4 (no separate revocation needed)

### 7. Post-Rotation Verification

1. Rebuild the app: `swift build -c release`
2. Run smoke test: invoke `wispr-run-smoke-test`
3. Confirm LLM polish works end-to-end with the new key

## Security Rules

- Never log the old or new key value
- Never store keys in UserDefaults, source code, or commit history
- If a key was committed to git, treat it as compromised — rotate immediately
- After rotation, run `wispr-detect-hardcoded-secrets` to confirm no leakage

## Rollback

If the new key fails verification (step 5):
1. Re-store the old key via `KeychainManager`
2. Verify old key still works
3. Investigate why new key failed before retrying
