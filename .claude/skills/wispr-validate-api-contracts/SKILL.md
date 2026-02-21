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
