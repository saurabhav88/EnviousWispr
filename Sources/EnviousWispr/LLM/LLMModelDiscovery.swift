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
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)") else {
            throw LLMError.requestFailed("Invalid URL")
        }
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
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            throw LLMError.requestFailed("Invalid URL")
        }
        var request = URLRequest(url: url)
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

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            return false
        }
        var request = URLRequest(url: url)
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
