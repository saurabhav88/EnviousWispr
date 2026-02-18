# Dynamic LLM Model Selector — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the free-text model TextField in Settings with a dynamic dropdown that discovers models from the API, probes free/paid availability, shows a key validation badge, and includes a manual refresh button.

**Architecture:** New `LLMModelDiscovery` service handles API calls (list + probe). `AppState` owns cached model lists and discovery state. `LLMSettingsView` renders the Picker, validation badge, and refresh button. `LLMModelInfo` is the per-model data type.

**Tech Stack:** Swift 6, SwiftUI @Observable, URLSession async/await, UserDefaults caching, JSONSerialization

**Environment:** Build with `swift build` only (no Xcode, no XCTest). Verify compilation after each task. Use `@skill run-smoke-test` after final task.

---

### Task 1: Add `LLMModelInfo` to Models

**Files:**
- Modify: `Sources/EnviousWispr/Models/LLMResult.swift`

**Step 1: Add the struct after `LLMProviderConfig`**

Add this code after the closing brace of `LLMProviderConfig` (after line 27):

```swift
/// A discoverable LLM model with availability status.
struct LLMModelInfo: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    var isAvailable: Bool
}
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/EnviousWispr/Models/LLMResult.swift
git commit -m "feat(models): add LLMModelInfo struct for discoverable models"
```

---

### Task 2: Create `LLMModelDiscovery` service

**Files:**
- Create: `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift`

**Step 1: Create the discovery service**

Create `Sources/EnviousWispr/LLM/LLMModelDiscovery.swift` with:

```swift
import Foundation

/// Discovers available LLM models from provider APIs and probes their availability.
struct LLMModelDiscovery: Sendable {

    /// Exclusion patterns for model IDs that aren't useful for transcript polishing.
    private static let excludePatterns = [
        "tts", "image", "robotics", "computer-use", "deep-research",
        "gemma", "exp-", "embedding", "aqa", "vision", "nano-banana",
    ]

    /// Suffixes that indicate versioned duplicates (keep only the base model).
    private static let versionedSuffixes = ["-001", "-002", "-003"]

    /// Alias prefixes to exclude (keep specific versioned models only).
    private static let aliasPatterns = ["latest"]

    // MARK: - Public API

    /// Discover and probe models for the given provider.
    /// Returns models sorted: available first, then locked, alphabetically within each group.
    func discoverModels(provider: LLMProvider, apiKey: String) async throws -> [LLMModelInfo] {
        let modelIDs: [(id: String, displayName: String)]

        switch provider {
        case .gemini:
            modelIDs = try await fetchGeminiModels(apiKey: apiKey)
        case .openAI:
            modelIDs = try await fetchOpenAIModels(apiKey: apiKey)
        case .none:
            return []
        }

        let filtered = filterModels(modelIDs)

        // Probe all filtered models in parallel
        return await withTaskGroup(of: LLMModelInfo.self, returning: [LLMModelInfo].self) { group in
            for model in filtered {
                group.addTask {
                    let available = await probeModel(id: model.id, provider: provider, apiKey: apiKey)
                    return LLMModelInfo(
                        id: model.id,
                        displayName: model.displayName,
                        provider: provider,
                        isAvailable: available
                    )
                }
            }

            var results: [LLMModelInfo] = []
            for await result in group {
                results.append(result)
            }

            // Sort: available first, then by display name
            return results.sorted { lhs, rhs in
                if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
                return lhs.displayName < rhs.displayName
            }
        }
    }

    // MARK: - Gemini

    private func fetchGeminiModels(apiKey: String) async throws -> [(id: String, displayName: String)] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode == 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("API_KEY_INVALID") { throw LLMError.invalidAPIKey }
        }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let models = json?["models"] as? [[String: Any]] else { return [] }

        return models.compactMap { model -> (id: String, displayName: String)? in
            guard let name = model["name"] as? String,
                  let displayName = model["displayName"] as? String,
                  let methods = model["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            return (id: id, displayName: displayName)
        }
    }

    private func probeGemini(modelID: String, apiKey: String) async -> Bool {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return false }

        let body: [String: Any] = [
            "contents": [["parts": [["text": "Hi"]]]],
            "generationConfig": ["maxOutputTokens": 5],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else { return false }

        if httpResponse.statusCode == 200 { return true }
        if httpResponse.statusCode == 429 {
            // Check if quota limit is 0 (locked) vs temporary rate limit
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("limit: 0") { return false }
            // Temporary rate limit — assume available
            return true
        }
        return false
    }

    // MARK: - OpenAI

    private func fetchOpenAIModels(apiKey: String) async throws -> [(id: String, displayName: String)] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.requestFailed("Invalid response")
        }

        if httpResponse.statusCode == 401 { throw LLMError.invalidAPIKey }
        guard httpResponse.statusCode == 200 else {
            throw LLMError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let models = json?["data"] as? [[String: Any]] else { return [] }

        return models.compactMap { model -> (id: String, displayName: String)? in
            guard let id = model["id"] as? String else { return nil }
            // Only include chat-capable models (gpt- and o- prefixes)
            guard id.hasPrefix("gpt-") || id.hasPrefix("o-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") else { return nil }
            // Skip realtime, audio, and search models
            let skipPatterns = ["realtime", "audio", "search", "transcribe"]
            if skipPatterns.contains(where: { id.contains($0) }) { return nil }
            let displayName = id.replacingOccurrences(of: "-", with: " ")
                .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return (id: id, displayName: displayName)
        }
    }

    private func probeOpenAI(modelID: String, apiKey: String) async -> Bool {
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 5,
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse else { return false }

        return httpResponse.statusCode == 200
    }

    // MARK: - Shared Helpers

    private func probeModel(id: String, provider: LLMProvider, apiKey: String) async -> Bool {
        switch provider {
        case .gemini: return await probeGemini(modelID: id, apiKey: apiKey)
        case .openAI: return await probeOpenAI(modelID: id, apiKey: apiKey)
        case .none: return false
        }
    }

    private func filterModels(_ models: [(id: String, displayName: String)]) -> [(id: String, displayName: String)] {
        models.filter { model in
            let lowered = model.id.lowercased()

            // Exclude by pattern
            for pattern in Self.excludePatterns {
                if lowered.contains(pattern) { return false }
            }

            // Exclude versioned duplicates (-001, -002, etc.)
            for suffix in Self.versionedSuffixes {
                if lowered.hasSuffix(suffix) { return false }
            }

            // Exclude alias names containing "latest"
            for alias in Self.aliasPatterns {
                if lowered.contains(alias) { return false }
            }

            return true
        }
    }
}
```

**Step 2: Verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 3: Commit**

```bash
git add Sources/EnviousWispr/LLM/LLMModelDiscovery.swift
git commit -m "feat(llm): add LLMModelDiscovery service with dynamic model probing"
```

---

### Task 3: Add discovery state and caching to AppState

**Files:**
- Modify: `Sources/EnviousWispr/App/AppState.swift`

**Step 1: Add properties**

After the `audioCuesEnabled` property (after line 108), add:

```swift
    // Model discovery
    var discoveredModels: [LLMModelInfo] = []
    var isDiscoveringModels = false
    var keyValidationState: KeyValidationState = .idle

    enum KeyValidationState: Equatable {
        case idle
        case validating
        case valid
        case invalid(String)
    }
```

**Step 2: Add the discovery + validation methods**

After the `loadTranscripts()` method (after line 236), add:

```swift
    /// Validate an API key and discover available models for the given provider.
    func validateKeyAndDiscoverModels(provider: LLMProvider) async {
        keyValidationState = .validating
        isDiscoveringModels = true

        let keychainId = provider == .openAI ? "openai-api-key" : "gemini-api-key"
        guard let apiKey = try? keychainManager.retrieve(key: keychainId), !apiKey.isEmpty else {
            keyValidationState = .invalid("No API key found")
            isDiscoveringModels = false
            return
        }

        let discovery = LLMModelDiscovery()
        do {
            let models = try await discovery.discoverModels(provider: provider, apiKey: apiKey)
            discoveredModels = models
            cacheModels(models, for: provider)
            keyValidationState = .valid

            // Auto-select first available model if current selection is invalid
            if !models.contains(where: { $0.id == llmModel && $0.isAvailable }) {
                if let firstAvailable = models.first(where: { $0.isAvailable }) {
                    llmModel = firstAvailable.id
                }
            }
        } catch let error as LLMError where error == .invalidAPIKey {
            keyValidationState = .invalid("Invalid API key")
            discoveredModels = []
        } catch {
            keyValidationState = .invalid(error.localizedDescription)
            discoveredModels = []
        }

        isDiscoveringModels = false
    }

    /// Load cached models from UserDefaults for the given provider.
    func loadCachedModels(for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let models = try? JSONDecoder().decode([LLMModelInfo].self, from: data) else {
            discoveredModels = []
            return
        }
        discoveredModels = models
    }

    private func cacheModels(_ models: [LLMModelInfo], for provider: LLMProvider) {
        let key = "cachedModels_\(provider.rawValue)"
        if let data = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
```

**Step 3: Add `LLMError` Equatable conformance**

In `Sources/EnviousWispr/LLM/LLMProtocol.swift`, update the enum declaration from:

```swift
enum LLMError: LocalizedError, Sendable {
```

to:

```swift
enum LLMError: LocalizedError, Sendable, Equatable {
```

And update the `requestFailed` case comparison — since `requestFailed` has an associated value, add explicit Equatable:

Actually, the enum cases with associated String values already get auto-synthesized Equatable when all associated types are Equatable. String is Equatable, so this just works.

**Step 4: Verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 5: Commit**

```bash
git add Sources/EnviousWispr/App/AppState.swift Sources/EnviousWispr/LLM/LLMProtocol.swift
git commit -m "feat(state): add model discovery state, caching, and validation to AppState"
```

---

### Task 4: Update SettingsView — validation badge + model Picker + refresh button

**Files:**
- Modify: `Sources/EnviousWispr/Views/Settings/SettingsView.swift`

**Step 1: Replace the model TextField with a Picker + refresh button**

In `LLMSettingsView`, replace this block (lines 248-257):

```swift
                if appState.llmProvider != .none {
                    TextField("Model", text: $state.llmModel)
                        .textFieldStyle(.roundedBorder)

                    Text(appState.llmProvider == .openAI
                         ? "e.g., gpt-4o-mini, gpt-4o, gpt-4.1-nano"
                         : "e.g., gemini-2.0-flash, gemini-2.5-pro")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

With:

```swift
                if appState.llmProvider != .none {
                    HStack {
                        Picker("Model", selection: $state.llmModel) {
                            if appState.discoveredModels.isEmpty && !appState.isDiscoveringModels {
                                Text(appState.llmModel.isEmpty ? "Save API key to discover models" : appState.llmModel)
                                    .tag(appState.llmModel)
                            }

                            ForEach(appState.discoveredModels) { model in
                                HStack {
                                    Text(model.displayName)
                                    if !model.isAvailable {
                                        Image(systemName: "lock.fill")
                                            .font(.caption2)
                                    }
                                }
                                .tag(model.id)
                            }
                        }

                        if appState.isDiscoveringModels {
                            ProgressView()
                                .controlSize(.small)
                        } else if appState.llmProvider != .none {
                            Button {
                                Task { await appState.validateKeyAndDiscoverModels(provider: appState.llmProvider) }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh available models")
                        }
                    }

                    if let selectedModel = appState.discoveredModels.first(where: { $0.id == appState.llmModel }),
                       !selectedModel.isAvailable {
                        Text("This model requires a paid API plan.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
```

**Step 2: Add validation badge to the Save Key buttons**

Replace the Gemini "Save Key" button HStack (lines 318-328):

```swift
                    HStack {
                        Button("Save Key") {
                            saveKey(key: geminiKey, keychainId: "gemini-api-key")
                        }
                        .disabled(geminiKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "gemini-api-key")
                            geminiKey = ""
                        }
                    }
```

With:

```swift
                    HStack {
                        Button("Save Key") {
                            saveKey(key: geminiKey, keychainId: "gemini-api-key")
                            if appState.llmProvider == .gemini {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .gemini) }
                            }
                        }
                        .disabled(geminiKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "gemini-api-key")
                            geminiKey = ""
                            if appState.llmProvider == .gemini {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }
```

Replace the OpenAI "Save Key" HStack (lines 280-295):

```swift
                    HStack {
                        Button("Save Key") {
                            saveKey(key: openAIKey, keychainId: "openai-api-key")
                        }
                        .disabled(openAIKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "openai-api-key")
                            openAIKey = ""
                        }

                        if !validationStatus.isEmpty {
                            Text(validationStatus)
                                .font(.caption)
                                .foregroundStyle(validationStatus.contains("Saved") ? .green : .red)
                        }
                    }
```

With:

```swift
                    HStack {
                        Button("Save Key") {
                            saveKey(key: openAIKey, keychainId: "openai-api-key")
                            if appState.llmProvider == .openAI {
                                Task { await appState.validateKeyAndDiscoverModels(provider: .openAI) }
                            }
                        }
                        .disabled(openAIKey.isEmpty)

                        Button("Clear Key") {
                            clearKey(keychainId: "openai-api-key")
                            openAIKey = ""
                            if appState.llmProvider == .openAI {
                                appState.discoveredModels = []
                                appState.keyValidationState = .idle
                            }
                        }

                        validationBadge
                    }
```

**Step 3: Add the `validationBadge` computed property**

Add this inside `LLMSettingsView`, after the `clearKey` method (after line 355):

```swift
    @ViewBuilder
    private var validationBadge: some View {
        switch appState.keyValidationState {
        case .idle:
            if !validationStatus.isEmpty {
                Text(validationStatus)
                    .font(.caption)
                    .foregroundStyle(validationStatus.contains("Saved") ? .green : .red)
            }
        case .validating:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Validating...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .valid:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Valid")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .invalid(let message):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
```

**Step 4: Load cached models on appear**

Update the `.onAppear` block (lines 334-338) to also load cached models:

```swift
        .onAppear {
            openAIKey = (try? appState.keychainManager.retrieve(key: "openai-api-key")) ?? ""
            geminiKey = (try? appState.keychainManager.retrieve(key: "gemini-api-key")) ?? ""
            if appState.llmProvider != .none {
                appState.loadCachedModels(for: appState.llmProvider)
            }
        }
```

**Step 5: Reload models when provider changes**

Add `.onChange` after the `.onAppear`:

```swift
        .onChange(of: appState.llmProvider) { _, newProvider in
            if newProvider != .none {
                appState.loadCachedModels(for: newProvider)
                appState.keyValidationState = .idle
            } else {
                appState.discoveredModels = []
                appState.keyValidationState = .idle
            }
        }
```

**Step 6: Verify compilation**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

**Step 7: Commit**

```bash
git add Sources/EnviousWispr/Views/Settings/SettingsView.swift
git commit -m "feat(settings): replace model TextField with dynamic Picker, validation badge, refresh button"
```

---

### Task 5: Verify full build and smoke test

**Step 1: Clean build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeded

**Step 2: Run smoke test**

Use `@skill run-smoke-test` to verify the app launches and the Settings window opens correctly.

**Step 3: Final commit if any fixups needed**

```bash
git add -A
git commit -m "fix: address build issues from model selector implementation"
```

Only create this commit if fixups were needed.
