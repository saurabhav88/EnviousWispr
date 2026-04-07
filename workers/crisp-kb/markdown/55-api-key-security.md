If you use a cloud LLM provider (OpenAI or Gemini) for AI polish, you provide your own API key. Here is how that key is stored.

### POSIX-Secured File Storage

API keys are stored as files in `~/.enviouswispr-keys/` with strict POSIX permissions:

* Directory permissions: `0700` (owner read/write/execute only)
* File permissions: `0600` (owner read/write only)

No other user on the system can read your keys.

### Why Not macOS Keychain?

The macOS Data Protection Keychain requires entitlements unavailable to non-sandboxed, ad-hoc-signed apps. The legacy Keychain causes password prompts on every app rebuild. File-based storage with strict POSIX permissions is standard practice for non-sandboxed macOS apps and avoids both issues.

### Key Safety

* API keys are never logged.
* API keys are never included in telemetry data.
* API keys are never sent anywhere except to the provider you configured (OpenAI or Gemini) as part of the authentication header.