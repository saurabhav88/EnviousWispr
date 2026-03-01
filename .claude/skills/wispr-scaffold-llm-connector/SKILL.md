---
name: wispr-scaffold-llm-connector
description: >
  Use when adding a new LLM provider for transcript polishing — e.g., a new API
  vendor, a local model endpoint, or any struct that must conform to
  TranscriptPolisher and be selectable from the AI Polish settings tab.
---

# Scaffold a New LLM Connector

## Step 1 — Create the connector file

Create `Sources/EnviousWispr/LLM/<Name>Connector.swift`.
The struct must be `Sendable` (store no mutable state; use `KeychainManager` for keys).

```swift
import Foundation
// Use @preconcurrency for any provider SDK that is not fully Sendable-annotated.
// Example: @preconcurrency import SomeProviderSDK

struct <Name>Connector: TranscriptPolisher {
    private let keychainManager: KeychainManager

    // Keychain key used to retrieve the API key — must match the string
    // registered in Step 4 and displayed in LLMSettingsView (Step 5).
    private let keychainId = "<provider>-api-key"
    private let baseURL = "https://<provider-api-url>"

    init(keychainManager: KeychainManager = KeychainManager()) {
        self.keychainManager = keychainManager
    }

    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
        let apiKey = try getAPIKey()

        // Build URLRequest, serialize body, set auth header
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        // request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Use LLMNetworkSession for HTTP/2 multiplexing and TLS session resumption.
        let session = LLMNetworkSession.shared.session
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }
        switch httpResponse.statusCode {
        case 200: break
        case 401: throw LLMError.invalidAPIKey
        case 429: throw LLMError.rateLimited
        default:
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        // Parse response JSON and extract polished text.
        // If onToken is non-nil, deliver fragments via onToken as they arrive (SSE/streaming).
        let polishedText = "" // replace with actual parsing
        guard !polishedText.isEmpty else { throw LLMError.emptyResponse }

        return LLMResult(
            polishedText: polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func getAPIKey() throws -> String {
        do {
            return try keychainManager.retrieve(key: keychainId)
        } catch {
            throw LLMError.invalidAPIKey
        }
    }
}
```

## Step 2 — Add case to LLMProvider enum

File: `Sources/EnviousWispr/Models/LLMResult.swift`

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case gemini
    case <caseName>   // ADD THIS
    case none
}
```

## Step 3 — Wire into TranscriptionPipeline

File: `Sources/EnviousWispr/Pipeline/TranscriptionPipeline.swift`

In `polishTranscript(_:)`, extend the switch:
```swift
let polisher: any TranscriptPolisher = switch llmProvider {
case .openAI:    OpenAIConnector(keychainManager: keychainManager)
case .gemini:    GeminiConnector(keychainManager: keychainManager)
case .<caseName>: <Name>Connector(keychainManager: keychainManager)  // ADD
case .none:      throw LLMError.providerUnavailable
}
```

Also update the `LLMProviderConfig` keychainId mapping if it is hardcoded:
```swift
apiKeyKeychainId: llmProvider == .openAI ? "openai-api-key"
                : llmProvider == .<caseName> ? "<provider>-api-key"
                : "gemini-api-key"
```

## Step 4 — Register Keychain slot

The Keychain key string (e.g. `"<provider>-api-key"`) is the only slot needed —
`KeychainManager` uses service `"com.enviouswispr.api-keys"` automatically. No
additional registration is required; just keep the string consistent across the
connector, pipeline, and settings view.

## Step 5 — Add settings section in LLMSettingsView

File: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

1. Add `.tag(LLMProvider.<caseName>)` to the `Picker("Provider", ...)`.
2. Add a `Section("<Name> API Key") { ... }` block following the Gemini pattern:
   - `@State private var <name>Key: String = ""`
   - `SecureField` / `TextField` toggle, Save / Clear buttons
   - `.onAppear` load: `<name>Key = (try? appState.keychainManager.retrieve(key: "<provider>-api-key")) ?? ""`

## Step 6 — Verify

```bash
swift build
```

## Protocol reference

```swift
protocol TranscriptPolisher: Sendable {
    func polish(
        text: String,
        instructions: PolishInstructions,
        config: LLMProviderConfig,
        onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult
}
```

`onToken` is `nil` for batch mode. For streaming, deliver each text fragment via `onToken` as it arrives (e.g. SSE chunks).

`LLMResult` has a single field: `polishedText: String`.

## Gotchas

- **No `validateCredentials()`**: `TranscriptPolisher` has no such method — do not add it. Credential errors surface via `LLMError.invalidAPIKey` from `polish()`.
- **`LLMResult` is minimal**: Only `polishedText: String`. No `originalText`, `provider`, `model`, `tokensUsed`, or `latency` fields.
- **Use `LLMNetworkSession.shared.session`**, not `URLSession.shared` — ensures HTTP/2 multiplexing and correct timeouts.
- **`@preconcurrency` imports**: Required for any provider SDK that is not fully Sendable-annotated (see `.claude/rules/swift-patterns.md`).
- **`Sendable` struct**: Store no mutable state in the connector. Keys go through `KeychainManager` only.
