# Dynamic LLM Model Selector with Validation

**Date:** 2026-02-18
**Status:** Approved

## Problem

The model selector in Settings is a free-text TextField. Users must know exact model IDs, have no visibility into which models are available on their API tier (free vs paid), and no feedback on whether their API key is valid.

## Solution

Replace the TextField with a dynamic dropdown that discovers available models from the API, probes each to determine free/paid availability, and shows an inline validation badge when API keys are saved.

## Data Model

```swift
struct LLMModelInfo: Codable, Identifiable, Sendable {
    let id: String          // e.g. "gemini-2.5-flash"
    let displayName: String // e.g. "Gemini 2.5 Flash"
    let provider: LLMProvider
    var isAvailable: Bool   // false = locked (needs paid tier)
}
```

Cached per-provider in UserDefaults alongside a `lastProbed: Date` timestamp.

## Model Discovery Service

New file: `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift`

### Responsibilities

- `discoverModels(provider:apiKey:) async throws -> [LLMModelInfo]`
- Queries the provider's model list endpoint
- Applies smart filters to exclude irrelevant models
- Probes each filtered model in parallel for availability
- Returns sorted list (available first, then locked)

### Filter Rules

Exclude models whose ID contains: `tts`, `image`, `robotics`, `computer-use`, `deep-research`, `gemma`, `exp-`, `-001`/`-002` suffixed duplicates, and `latest` aliases.

### Probing

Send a minimal generation request (`"Hi"`, maxTokens: 5) to each model:
- 200 response -> `isAvailable = true`
- 429 with `limit: 0` or 403 -> `isAvailable = false` (locked/paid)
- 401/400 API_KEY_INVALID -> propagate error (bad key)

### Provider Endpoints

**Gemini:**
- List: `GET /v1beta/models?key=<key>` — filter for `generateContent` in supportedGenerationMethods
- Probe: `POST /v1beta/models/{id}:generateContent?key=<key>`

**OpenAI:**
- List: `GET /v1/models` with `Authorization: Bearer <key>` — filter for `gpt-` prefix
- Probe: `POST /v1/chat/completions` with model + minimal message

## Settings UI Changes

### API Key Validation Badge

After saving an API key, auto-trigger validation + discovery. Show inline:
- Spinner (`ProgressView`) while validating
- Green checkmark + "Valid" on success
- Red X + error message on failure

### Model Dropdown

Replace `TextField("Model", ...)` with a `Picker`:
- Each row: model displayName
- Locked models: show lock icon, dimmed text
- Locked models are selectable but show a caption warning: "This model requires a paid API plan"
- If current llmModel is not in discovered list, auto-select first available model

### Refresh Button

Small `arrow.clockwise` icon button next to the model Picker. Triggers `discoverModels()` with a spinner overlay.

## Files Changed

| File | Change |
|------|--------|
| **New:** `LLM/LLMModelDiscovery.swift` | Discovery service with filter + probe logic |
| **Edit:** `Models/LLMResult.swift` | Add `LLMModelInfo` struct |
| **Edit:** `App/AppState.swift` | Add cached models array, discovery state, refresh method |
| **Edit:** `Views/Settings/SettingsView.swift` | Replace TextField with Picker, add validation badge, add refresh button |

## Behavior Summary

1. User enters API key and clicks Save
2. Key is stored in Keychain
3. Auto-validation fires: calls models list endpoint
4. If valid: inline green checkmark, discovery probes models in parallel
5. Model dropdown populates with discovered models (available first, locked with lock icon)
6. User selects a model from dropdown
7. If user picks a locked model, caption warns about paid tier
8. Refresh button re-runs discovery on demand
