# Feature: Offline LLM (Ollama + Apple Intelligence)

**ID:** 009
**Category:** AI & Post-Processing
**Priority:** High
**Inspired by:** Handy — Ollama (local) + Apple Intelligence (macOS 26+, no API key)
**Status:** Ready for Implementation

## Problem

LLM polish currently requires an internet connection and a paid API key (OpenAI or Gemini). Users who want fully offline operation or don't want to pay for API access cannot use the polish feature.

## Proposed Solution

Add two new `TranscriptPolisher` implementations:

1. **OllamaConnector** — connects to a local Ollama instance at `http://localhost:11434/v1/chat/completions` (OpenAI-compatible endpoint). Free, offline, user controls model choice.
2. **AppleIntelligenceConnector** — uses the `FoundationModels` framework (`LanguageModelSession`) on macOS 26+. Free, offline, no API key. Guarded by `#if canImport(FoundationModels)` and `@available(macOS 26.0, *)`.

Both are added as new cases on `LLMProvider` and integrated through the existing `TranscriptPolisher` protocol without changing any other pipeline logic.

## Architecture Decisions

- Both connectors are pure `struct` values conforming to `TranscriptPolisher: Sendable`
- `OllamaConnector` reuses the OpenAI chat completions wire format — Ollama natively supports it at `/v1/chat/completions`
- `AppleIntelligenceConnector` is fully behind a compile-time `#if canImport(FoundationModels)` guard so the build succeeds on macOS 14 targets where the framework is absent
- `LLMProvider` gains `.ollama` and `.appleIntelligence` cases; `LLMProviderConfig.apiKeyKeychainId` is left empty for both (no key needed)
- Ollama model list is fetched from `http://localhost:11434/api/tags` at validation time; Apple Intelligence uses `SystemLanguageModel.default`
- `LLMModelDiscovery` is extended with handlers for both new providers
- `polishTranscript` in `TranscriptionPipeline` dispatches to the new connectors based on `llmProvider`
- Settings: the existing `LLMSettingsView` Picker gains the two new provider tags; a new `OllamaSettingsSection` shows model discovery; Apple Intelligence shows an availability badge

## Files to Modify

### Existing Files

| File | Change |
| ---- | ------ |
| `Sources/EnviousWispr/Models/LLMResult.swift` | Add `.ollama` and `.appleIntelligence` cases to `LLMProvider`; add `providerUnavailable` handling note |
| `Sources/EnviousWispr/LLM/LLMProtocol.swift` | No protocol change needed; add `LLMError.modelNotFound` case |
| `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift` | Add `fetchOllamaModels()`, `probeOllama()` methods; extend `discoverModels(provider:apiKey:)` switch |
| `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift` | Extend `polishTranscript(_:)` switch to dispatch `.ollama` → `OllamaConnector`, `.appleIntelligence` → `AppleIntelligenceConnector` |
| `Sources/EnviousWispr/App/AppState.swift` | Add `ollamaModel: String` persisted setting; extend `validateKeyAndDiscoverModels` for new providers; wire `ollamaModel` to pipeline |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Add `.ollama` and `.appleIntelligence` tags to Provider Picker; add `OllamaSettingsSection` and `AppleIntelligenceSettingsSection` inside `LLMSettingsView` |

### New Files

| File | Purpose |
| ---- | ------- |
| `Sources/EnviousWispr/LLM/OllamaConnector.swift` | `struct OllamaConnector: TranscriptPolisher` — posts to Ollama's OpenAI-compatible endpoint |
| `Sources/EnviousWispr/LLM/AppleIntelligenceConnector.swift` | `struct AppleIntelligenceConnector: TranscriptPolisher` — uses `FoundationModels.LanguageModelSession`, fully guarded |

## New Types and Properties

### `LLMProvider` additions (in `LLMResult.swift`)

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case gemini
    case ollama
    case appleIntelligence
    case none
}
```

### `LLMError` additions (in `LLMProtocol.swift`)

```swift
enum LLMError: LocalizedError, Sendable, Equatable {
    // ... existing cases ...
    case modelNotFound(String)   // Ollama: model not pulled
    case frameworkUnavailable    // Apple Intelligence: macOS < 26 or non-Apple-Silicon
}
```

### `OllamaConnector` (new file)

```swift
struct OllamaConnector: TranscriptPolisher {
    private let baseURL: String

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult
}
```

### `AppleIntelligenceConnector` (new file)

```swift
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligenceConnector: TranscriptPolisher {
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult
}
```

### AppState additions

```swift
var ollamaModel: String {
    didSet {
        UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
        pipeline.llmModel = ollamaModel  // reuse existing llmModel slot when provider is .ollama
    }
}
// Loaded in init():
// ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"
```

## Implementation Plan

### Step 1 — Extend `LLMProvider` and `LLMError`

In `Sources/EnviousWispr/Models/LLMResult.swift`, add the two new enum cases:

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case gemini
    case ollama
    case appleIntelligence
    case none
}
```

In `Sources/EnviousWispr/LLM/LLMProtocol.swift`, add two new error cases:

```swift
case modelNotFound(String)
case frameworkUnavailable

// errorDescription additions:
case .modelNotFound(let model):
    return "Ollama model '\(model)' is not pulled. Run: ollama pull \(model)"
case .frameworkUnavailable:
    return "Apple Intelligence requires macOS 26+ on Apple Silicon."
```

Also update `Equatable` synthesis — since `modelNotFound` has an associated value, add:

```swift
static func == (lhs: LLMError, rhs: LLMError) -> Bool {
    switch (lhs, rhs) {
    case (.invalidAPIKey, .invalidAPIKey),
         (.rateLimited, .rateLimited),
         (.emptyResponse, .emptyResponse),
         (.providerUnavailable, .providerUnavailable),
         (.frameworkUnavailable, .frameworkUnavailable):
        return true
    case (.requestFailed(let a), .requestFailed(let b)),
         (.modelNotFound(let a), .modelNotFound(let b)):
        return a == b
    default:
        return false
    }
}
```

### Step 2 — Create `OllamaConnector.swift`

Ollama exposes an OpenAI-compatible chat completions endpoint. The implementation is nearly identical to `OpenAIConnector` with these differences: no `Authorization` header, base URL is localhost, and a 60-second timeout (local models are slower).

```swift
// Sources/EnviousWispr/LLM/OllamaConnector.swift
import Foundation

/// Ollama local LLM connector. Uses Ollama's OpenAI-compatible endpoint.
/// Requires Ollama to be running: https://ollama.com
struct OllamaConnector: TranscriptPolisher {
    private let baseURL: String

    init(baseURL: String = "http://localhost:11434") {
        self.baseURL = baseURL
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
        let endpointURL = "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpointURL) else {
            throw LLMError.requestFailed("Invalid Ollama URL: \(endpointURL)")
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": instructions.systemPrompt],
            ["role": "user",   "content": text],
        ]

        let body: [String: Any] = [
            "model":      config.model,
            "messages":   messages,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "stream":     false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // Local models can be slow — 60s timeout
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
                                              || urlError.code == .timedOut {
            throw LLMError.providerUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200: break
        case 404:
            // Ollama returns 404 when the model hasn't been pulled
            throw LLMError.modelNotFound(config.model)
        default:
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .ollama,
            model: config.model
        )
    }
}
```

### Step 3 — Create `AppleIntelligenceConnector.swift`

The entire implementation is wrapped in `#if canImport(FoundationModels)` so the file compiles cleanly on macOS 14 where the framework does not exist. The `@available` annotation prevents calling it at runtime on older systems.

```swift
// Sources/EnviousWispr/LLM/AppleIntelligenceConnector.swift
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence connector using the on-device FoundationModels framework.
/// Requires macOS 26+ on Apple Silicon. No API key, no internet connection.
struct AppleIntelligenceConnector: TranscriptPolisher {

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig
    ) async throws -> LLMResult {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw LLMError.frameworkUnavailable
        }
        return try await polishWithFoundationModels(text: text, instructions: instructions)
#else
        throw LLMError.frameworkUnavailable
#endif
    }

#if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func polishWithFoundationModels(
        text: String,
        instructions: PolishInstructions
    ) async throws -> LLMResult {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LLMError.frameworkUnavailable
        }

        let session = LanguageModelSession(model: model)

        // Combine system prompt and user text into a single prompt since
        // LanguageModelSession uses a single-turn API in the initial release.
        let fullPrompt = """
            \(instructions.systemPrompt)

            ---

            \(text)
            """

        let response = try await session.respond(to: Prompt(fullPrompt))
        let content = response.content

        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse
        }

        return LLMResult(
            polishedText: content.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: .appleIntelligence,
            model: "apple-intelligence"
        )
    }
#endif
}
```

### Step 4 — Extend `LLMModelDiscovery`

Add Ollama model fetching. Apple Intelligence has no model list — it exposes a single `SystemLanguageModel.default`.

```swift
// In LLMModelDiscovery.discoverModels(provider:apiKey:):
switch provider {
case .gemini:
    modelIDs = try await fetchGeminiModels(apiKey: apiKey)
case .openAI:
    modelIDs = try await fetchOpenAIModels(apiKey: apiKey)
case .ollama:
    modelIDs = try await fetchOllamaModels()
case .appleIntelligence:
    return appleIntelligenceModelInfo()
case .none:
    return []
}

// New methods:

private func fetchOllamaModels() async throws -> [(id: String, displayName: String)] {
    guard let url = URL(string: "http://localhost:11434/api/tags") else {
        throw LLMError.requestFailed("Invalid Ollama URL")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5  // Fast timeout — Ollama must be running locally

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw LLMError.providerUnavailable
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let models = json?["models"] as? [[String: Any]] else { return [] }

        return models.compactMap { model -> (id: String, displayName: String)? in
            guard let name = model["name"] as? String else { return nil }
            // Strip tag suffix for display: "llama3.2:latest" → "Llama 3.2"
            let base = name.components(separatedBy: ":").first ?? name
            let display = base.replacingOccurrences(of: "-", with: " ")
                             .replacingOccurrences(of: ".", with: " ")
                             .split(separator: " ")
                             .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                             .joined(separator: " ")
            return (id: name, displayName: display)
        }
    } catch let urlError as URLError
              where urlError.code == .cannotConnectToHost || urlError.code == .timedOut {
        throw LLMError.providerUnavailable
    }
}

private func appleIntelligenceModelInfo() -> [LLMModelInfo] {
#if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        let available = SystemLanguageModel.default.isAvailable
        return [LLMModelInfo(
            id: "apple-intelligence",
            displayName: "Apple Intelligence (On-Device)",
            provider: .appleIntelligence,
            isAvailable: available
        )]
    }
#endif
    return [LLMModelInfo(
        id: "apple-intelligence",
        displayName: "Apple Intelligence (Requires macOS 26+)",
        provider: .appleIntelligence,
        isAvailable: false
    )]
}
```

### Step 5 — Extend `TranscriptionPipeline.polishTranscript`

```swift
private func polishTranscript(_ text: String) async throws -> String {
    let polisher: any TranscriptPolisher = switch llmProvider {
    case .openAI:             OpenAIConnector(keychainManager: keychainManager)
    case .gemini:             GeminiConnector(keychainManager: keychainManager)
    case .ollama:             OllamaConnector()
    case .appleIntelligence:  AppleIntelligenceConnector()
    case .none:               throw LLMError.providerUnavailable
    }

    let keychainId: String = switch llmProvider {
    case .openAI:  "openai-api-key"
    case .gemini:  "gemini-api-key"
    default:       ""   // Ollama and Apple Intelligence need no key
    }

    // Ollama is slower; give it more time
    let maxTokens = llmProvider == .ollama ? 4096 : 2048

    let config = LLMProviderConfig(
        provider: llmProvider,
        model: llmModel,
        apiKeyKeychainId: keychainId,
        maxTokens: maxTokens,
        temperature: 0.3
    )

    let result = try await polisher.polish(
        text: text,
        instructions: .default,
        config: config
    )
    return result.polishedText
}
```

### Step 6 — Extend `AppState`

```swift
// New property in AppState:
var ollamaModel: String {
    didSet {
        UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
        if llmProvider == .ollama {
            pipeline.llmModel = ollamaModel
        }
    }
}

// In init():
ollamaModel = defaults.string(forKey: "ollamaModel") ?? "llama3.2"

// Extend validateKeyAndDiscoverModels to handle new providers:
func validateKeyAndDiscoverModels(provider: LLMProvider) async {
    keyValidationState = .validating
    isDiscoveringModels = true

    // Ollama and Apple Intelligence need no API key
    let apiKey: String
    if provider == .ollama || provider == .appleIntelligence {
        apiKey = ""
    } else {
        let keychainId = provider == .openAI ? "openai-api-key" : "gemini-api-key"
        guard let key = try? keychainManager.retrieve(key: keychainId), !key.isEmpty else {
            keyValidationState = .invalid("No API key found")
            isDiscoveringModels = false
            return
        }
        apiKey = key
    }

    let discovery = LLMModelDiscovery()
    do {
        let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
        discoveredModels = models
        if provider != .appleIntelligence {
            cacheModels(models, for: provider)
        }
        keyValidationState = .valid

        if !models.contains(where: { $0.id == llmModel && $0.isAvailable }) {
            if let firstAvailable = models.first(where: { $0.isAvailable }) {
                llmModel = firstAvailable.id
                if provider == .ollama { ollamaModel = firstAvailable.id }
            }
        }
    } catch LLMError.providerUnavailable {
        keyValidationState = .invalid(
            provider == .ollama
                ? "Ollama is not running. Start it with: ollama serve"
                : "Apple Intelligence not available on this system."
        )
        discoveredModels = []
    } catch let error as LLMError where error == .invalidAPIKey {
        keyValidationState = .invalid("Invalid API key")
        discoveredModels = []
    } catch {
        keyValidationState = .invalid(error.localizedDescription)
        discoveredModels = []
    }

    isDiscoveringModels = false
}
```

### Step 7 — Extend `LLMSettingsView` in `SettingsView.swift`

Add the new provider tags to the existing Picker and append two conditional sections:

```swift
// In the "LLM Provider" Section Picker:
Picker("Provider", selection: $state.llmProvider) {
    Text("None").tag(LLMProvider.none)
    Text("OpenAI").tag(LLMProvider.openAI)
    Text("Google Gemini").tag(LLMProvider.gemini)
    Text("Ollama (Local)").tag(LLMProvider.ollama)
    Text("Apple Intelligence").tag(LLMProvider.appleIntelligence)
}

// New section shown when provider == .ollama:
if appState.llmProvider == .ollama {
    Section("Ollama") {
        HStack {
            Text("Status:")
            Spacer()
            switch appState.keyValidationState {
            case .valid:
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .invalid(let msg):
                Label(msg, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            case .validating:
                ProgressView().controlSize(.small)
            case .idle:
                Text("Not checked").foregroundStyle(.secondary)
            }

            Button {
                Task { await appState.validateKeyAndDiscoverModels(provider: .ollama) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Check Ollama status and refresh models")
        }

        Text("Ollama must be installed and running. Recommended model: llama3.2")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// New section shown when provider == .appleIntelligence:
if appState.llmProvider == .appleIntelligence {
    Section("Apple Intelligence") {
        HStack {
            Image(systemName: "apple.logo")
            Text("On-device model — no internet or API key required.")
        }

        if #available(macOS 26.0, *) {
            Button("Check Availability") {
                Task { await appState.validateKeyAndDiscoverModels(provider: .appleIntelligence) }
            }
        } else {
            Label("Requires macOS 26 or later.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
```

Also extend the `.onChange(of: appState.llmProvider)` handler to cover the new providers:

```swift
.onChange(of: appState.llmProvider) { _, newProvider in
    switch newProvider {
    case .none:
        appState.discoveredModels = []
        appState.keyValidationState = .idle
    case .ollama, .appleIntelligence:
        appState.discoveredModels = []
        appState.keyValidationState = .idle
        Task { await appState.validateKeyAndDiscoverModels(provider: newProvider) }
    default:
        appState.loadCachedModels(for: newProvider)
        appState.keyValidationState = .idle
    }
}
```

## Testing Strategy

### Manual Tests — Ollama

1. Start Ollama: `ollama serve` then `ollama pull llama3.2`
2. Set provider to "Ollama (Local)" in Settings → AI Polish
3. Verify model list populates with pulled models
4. Record a sentence and verify polished transcript appears
5. Stop Ollama (`pkill ollama`) and attempt polish — verify error message "Ollama is not running"
6. Pull a model with a typo (simulate 404) — verify `modelNotFound` error displays

### Manual Tests — Apple Intelligence

1. On macOS 14 (current build target): set provider to "Apple Intelligence" — verify "Requires macOS 26+" badge
2. On macOS 26+ (future): verify `SystemLanguageModel.default.isAvailable` returns true, polish works
3. Compile guard: run `swift build` on macOS 14 — confirm `AppleIntelligenceConnector.swift` compiles without errors

### Build Verification

```sh
swift build 2>&1 | grep -E "(error:|warning:)"
```

Expected: zero errors. The `#if canImport(FoundationModels)` guard ensures the `FoundationModels` import is absent on macOS 14 builds.

### Unit-level Verification

Provide a mock `URLSession` stub (or use `OllamaConnector(baseURL:)` with a local test server) to verify:

- 200 response → `LLMResult.provider == .ollama`
- 404 response → throws `LLMError.modelNotFound`
- Connection refused → throws `LLMError.providerUnavailable`

## Risks and Considerations

- **Ollama install burden**: users must install Ollama separately. The Settings UI provides the error message and a link to `https://ollama.com`.
- **Model quality**: local models (llama3.2 ~3B) produce noticeably lower-quality polish than GPT-4o. Recommend in UI that larger models (`llama3.2:70b`) give better results if the user has sufficient RAM.
- **Timeout**: local inference on CPU can take 30–90 seconds. The 60-second timeout covers most cases; a future iteration could make it configurable.
- **Apple Intelligence availability**: `FoundationModels` is not yet released (macOS 26 is in beta as of the plan date). The `#if canImport` guard is essential. Re-test when macOS 26 GM ships.
- **`LLMProviderConfig.apiKeyKeychainId` empty string**: callers that blindly call `keychainManager.retrieve(key: "")` would error. The `polishTranscript` switch now skips key retrieval for these providers — verify no other callsite reads `apiKeyKeychainId` unconditionally.
- **`CaseIterable` on `LLMProvider`**: adding new cases updates `LLMProvider.allCases`. Audit any code iterating `allCases` (currently only `LLMModelDiscovery`) to ensure the new cases are handled.
