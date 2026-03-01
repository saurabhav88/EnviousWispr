---
name: wispr-validate-api-contracts
description: Use when the OpenAI or Gemini API may have changed, after updating LLM connector code, when a polish request returns unexpected errors, or when verifying auth method and JSON shapes are still correct against the live API spec.
---

# Validate API Contracts Skill

Files: `Sources/EnviousWispr/LLM/OpenAIConnector.swift`, `GeminiConnector.swift`

## OpenAI Chat Completions

**Endpoint:** `POST https://api.openai.com/v1/chat/completions`
**Auth:** `Authorization: Bearer <key>` header — NOT a query param
**Validate:** `GET https://api.openai.com/v1/models` (same auth) → 200

Request body fields: `model`, `messages[{role,content}]`, `max_tokens`, `temperature`
Response extraction: `choices[0].message.content`
Token count: `usage.total_tokens`

Status codes: 200 = parse, 401 = `.invalidAPIKey`, 429 = `.rateLimited`, other = `.requestFailed`

## Google Gemini generateContent

**Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=<apiKey>`
**Auth:** `key` query parameter — NOT a header
**Validate:** `GET https://generativelanguage.googleapis.com/v1beta/models?key=<apiKey>` → 200

Request body fields: `contents[{parts:[{text}]}]`, `generationConfig.{temperature, maxOutputTokens}`
Note: system prompt and user text are concatenated into a single `text` field separated by `\n\n---\n\n`
Response extraction: `candidates[0].content.parts[0].text`
Token count: `usageMetadata.totalTokenCount`

Status codes: 200 = parse, 400+body `"API_KEY_INVALID"` = `.invalidAPIKey`, 429 = `.rateLimited`, other = `.requestFailed`
**Important:** Gemini signals an invalid key via HTTP 400 (not 401) with `"API_KEY_INVALID"` in the body.

## Verification Steps

1. Web-search for breaking changes before auditing code:
   - `OpenAI chat completions API changes 2026`
   - `Gemini generateContent v1beta API changes 2026`

2. Confirm field names in request/response match the shapes above — flag any renames,
   newly required fields, or deprecated fields.

3. Confirm auth method is unchanged (OpenAI = header, Gemini = query param).

4. If discrepancy found: update the connector, then run the `run-smoke-test` skill.

## Rate Limit Handling

Both connectors must handle 429 responses with retry logic.

### OpenAI

- Check for `Retry-After` header (seconds) on 429 responses
- If present, wait that many seconds before retrying
- If absent, use exponential backoff: 1s, 2s, 4s
- **Max 3 retries** — after 3 failures, surface `.rateLimited` error to user
- Log each retry at `.debug` level with attempt number and wait duration

### Gemini

- Gemini 429 does not include `Retry-After` — always use exponential backoff: 1s, 2s, 4s
- **Max 3 retries** — same cap as OpenAI
- Gemini may also return 429 for per-minute quota exceeded — treat identically

### Verification

- Confirm both connectors implement retry loops with the max retry cap
- Confirm backoff durations are reasonable (not sub-second, not over 30s)
- Confirm retries are logged but API keys in headers/params are NOT logged

## API Deprecation Strategy

Monitor for upstream API changes that could silently break the app.

### Changelog Monitoring

- During each contract validation, web-search for recent API changelog entries:
  - `OpenAI API changelog 2026`
  - `Gemini API changelog 2026`
- Flag any deprecation notices, sunset dates, or version bumps

### Gemini v1beta Migration

- Current endpoint uses `v1beta` — Google may promote to `v1` or change the beta version
- If `v1beta` returns 404 or redirect, check whether `v1` is now the stable endpoint
- Migration path: update `geminiBaseURL` in `GeminiConnector.swift`, verify request/response shapes unchanged
- **Do not auto-migrate** — flag the issue and let the user confirm before changing endpoints

### Model Availability

- Models can be removed without warning (especially preview/experimental models)
- If a `generateContent` or `chat/completions` call returns 404 with a model-not-found error body, surface a user-visible error suggesting they update their model selection in Settings
- Check `LLMModelInfo` lists in `GeminiConnector.swift` and `OpenAIConnector.swift` against the live model list endpoint during validation
