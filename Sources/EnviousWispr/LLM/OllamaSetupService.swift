import Foundation
import AppKit

/// States in the Ollama guided-setup flow.
enum OllamaSetupState: Equatable {
    case detecting
    case notInstalled
    case installedNotRunning
    case runningNoModels
    case pullingModel(progress: Double, status: String)
    case ready
    case error(String)
}

/// Quality tier for Ollama catalog models.
enum OllamaQualityTier: String {
    case best = "best"
    case medium = "medium"
    case worst = "worst"

    var label: String {
        switch self {
        case .best: return "Best"
        case .medium: return "Medium"
        case .worst: return "Fast"
        }
    }
}

/// A model entry in the curated Ollama catalog.
struct OllamaModelCatalogEntry: Identifiable, Sendable {
    let name: String
    let displayName: String
    let parameterCount: String
    let qualityTier: OllamaQualityTier
    let downloadSize: String

    var id: String { name }
}

/// Guides users through Ollama installation, server startup, and model pulling.
@MainActor
@Observable
final class OllamaSetupService {

    // MARK: - Public State

    private(set) var setupState: OllamaSetupState = .detecting
    private(set) var pullProgress: Double = 0
    private(set) var pullStatusText: String = ""
    private(set) var downloadedModelNames: Set<String> = []

    // MARK: - Model Catalog

    static let modelCatalog: [OllamaModelCatalogEntry] = [
        OllamaModelCatalogEntry(name: "llama3.2", displayName: "Llama 3.2", parameterCount: "3B", qualityTier: .best, downloadSize: "~2 GB"),
        OllamaModelCatalogEntry(name: "llama3.2:1b", displayName: "Llama 3.2 (1B)", parameterCount: "1B", qualityTier: .medium, downloadSize: "~800 MB"),
        OllamaModelCatalogEntry(name: "mistral", displayName: "Mistral", parameterCount: "7B", qualityTier: .best, downloadSize: "~4 GB"),
        OllamaModelCatalogEntry(name: "phi3", displayName: "Phi-3 Mini", parameterCount: "3.8B", qualityTier: .medium, downloadSize: "~2.3 GB"),
        OllamaModelCatalogEntry(name: "gemma2:2b", displayName: "Gemma 2 (2B)", parameterCount: "2B", qualityTier: .medium, downloadSize: "~1.6 GB"),
        OllamaModelCatalogEntry(name: "gemma2", displayName: "Gemma 2", parameterCount: "9B", qualityTier: .best, downloadSize: "~5.5 GB"),
        OllamaModelCatalogEntry(name: "qwen2.5:3b", displayName: "Qwen 2.5 (3B)", parameterCount: "3B", qualityTier: .medium, downloadSize: "~1.9 GB"),
        OllamaModelCatalogEntry(name: "qwen2.5:7b", displayName: "Qwen 2.5 (7B)", parameterCount: "7B", qualityTier: .best, downloadSize: "~4.4 GB"),
        OllamaModelCatalogEntry(name: "tinyllama", displayName: "TinyLlama", parameterCount: "1.1B", qualityTier: .worst, downloadSize: "~638 MB"),
        OllamaModelCatalogEntry(name: "phi-2", displayName: "Phi-2", parameterCount: "2.7B", qualityTier: .worst, downloadSize: "~1.7 GB"),
    ]

    // MARK: - Weak Model Detection

    nonisolated static func isWeakModel(_ name: String) -> Bool {
        let prefixes: [String] = ["tinyllama", "phi-2", "gemma2:2b"]
        let lower = name.lowercased()
        return prefixes.contains(where: { lower.hasPrefix($0) })
    }

    // MARK: - Private

    private var ollamaProcess: Process?
    private var pullTask: Task<Void, Never>?

    private static let binaryPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
    private static let baseURL = "http://localhost:11434"
    private static let lastKnownStateKey = "OllamaSetupService.lastKnownReady"

    // MARK: - Detection Pipeline

    /// Run the full detection pipeline: binary → server → models.
    func detectState() async {
        setupState = .detecting

        // Fast path: if the user previously reached .ready, try the server directly.
        if UserDefaults.standard.bool(forKey: Self.lastKnownStateKey) {
            if await isServerRunning() {
                if await hasAnyModels() {
                    await refreshDownloadedModels()
                    setupState = .ready
                    return
                }
                setupState = .runningNoModels
                return
            }
        }

        // Full detection
        guard findOllamaBinary() != nil else {
            setupState = .notInstalled
            UserDefaults.standard.set(false, forKey: Self.lastKnownStateKey)
            return
        }

        guard await isServerRunning() else {
            // isServerRunning may have already set an .error state (port conflict)
            if case .error = setupState { return }
            setupState = .installedNotRunning
            return
        }

        if await hasAnyModels() {
            await refreshDownloadedModels()
            setupState = .ready
            UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
        } else {
            setupState = .runningNoModels
        }
    }

    // MARK: - Binary Discovery

    /// Locate the Ollama binary on disk. Returns the path or nil.
    func findOllamaBinary() -> String? {
        // Check well-known paths first
        for path in Self.binaryPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: ask the shell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ollama"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let path = output, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    // MARK: - Server Health

    /// Check whether the Ollama server is reachable. Strict 3-second timeout.
    func isServerRunning() async -> Bool {
        guard let url = URL(string: Self.baseURL) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }

            if http.statusCode == 200 {
                return true
            }

            // Port is in use by something other than Ollama
            setupState = .error(
                "Another app is using Ollama's port (11434). Close it and try again."
            )
            return false
        } catch {
            return false
        }
    }

    /// Check whether Ollama has at least one pulled model.
    func hasAnyModels() async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/api/tags") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let models = json?["models"] as? [[String: Any]] else { return false }
            return !models.isEmpty
        } catch {
            return false
        }
    }

    // MARK: - Model Management

    /// Refresh the set of downloaded model names from GET /api/tags.
    func refreshDownloadedModels() async {
        guard let url = URL(string: "\(Self.baseURL)/api/tags") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let models = json?["models"] as? [[String: Any]] else { return }
            downloadedModelNames = Set(models.compactMap { $0["name"] as? String })
        } catch {
            // Silently ignore — server may not be running
        }
    }

    /// Delete a model by name via DELETE /api/delete.
    func deleteModel(name: String) {
        Task {
            guard let url = URL(string: "\(Self.baseURL)/api/delete") else { return }
            let body: [String: Any] = ["model": name]
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    downloadedModelNames.remove(name)
                    // If current model was deleted, update setup state
                    if downloadedModelNames.isEmpty {
                        setupState = .runningNoModels
                        UserDefaults.standard.set(false, forKey: Self.lastKnownStateKey)
                    }
                }
            } catch {
                // Silently ignore delete errors — user can try again
            }
        }
    }

    // MARK: - Server Lifecycle

    /// Start the Ollama server, preferring the .app bundle, falling back to the CLI binary.
    func startServer() {
        let appPath = "/Applications/Ollama.app"

        if FileManager.default.fileExists(atPath: appPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
        } else if let binary = findOllamaBinary() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    self?.ollamaProcess = nil
                }
            }
            do {
                try process.run()
                ollamaProcess = process
            } catch {
                setupState = .error(
                    "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
                )
                return
            }
        } else {
            setupState = .error(
                "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
            )
            return
        }

        // Poll until the server is up (up to 10 seconds)
        Task { [weak self] in
            let maxAttempts = 20
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard let self else { return }

                if await self.isServerRunning() {
                    if await self.hasAnyModels() {
                        await self.refreshDownloadedModels()
                        self.setupState = .ready
                        UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
                    } else {
                        self.setupState = .runningNoModels
                    }
                    return
                }
            }

            self?.setupState = .error(
                "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
            )
        }
    }

    /// Terminate the managed Ollama server process on app quit.
    func cleanup() {
        ollamaProcess?.terminate()
        ollamaProcess = nil
    }

    // MARK: - Model Pulling

    /// Pull a model by name, streaming progress updates.
    func pullModel(_ modelName: String) {
        // Cancel any in-flight pull
        pullTask?.cancel()
        pullTask = nil

        // Reset progress
        pullProgress = 0
        pullStatusText = "Starting download..."
        setupState = .pullingModel(progress: 0, status: "Starting download...")

        pullTask = Task {
            do {
                try await performStreamingPull(modelName: modelName)
                await refreshDownloadedModels()
                setupState = .ready
                UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
            } catch is CancellationError {
                setupState = .runningNoModels
            } catch let urlError as URLError {
                setupState = .error(friendlyMessage(for: urlError))
            } catch {
                let message = error.localizedDescription.lowercased()
                if message.contains("no space") || message.contains("errno 28") {
                    setupState = .error(
                        "Not enough disk space. The model needs about 2 GB free."
                    )
                } else {
                    setupState = .error(
                        "Download failed — check your internet connection and try again."
                    )
                }
            }
        }
    }

    /// Cancel an in-progress model pull.
    func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        setupState = .runningNoModels
    }

    // MARK: - Streaming Pull (Private)

    private func performStreamingPull(modelName: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/api/pull") else {
            throw LLMError.requestFailed("Invalid Ollama URL")
        }

        let body: [String: Any] = [
            "model": modelName,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600 // 10 minutes

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMError.requestFailed("Ollama pull request failed")
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Check for error response from Ollama
            if let errorMessage = json["error"] as? String {
                throw LLMError.requestFailed("Ollama pull error: \(errorMessage)")
            }

            let status = json["status"] as? String ?? ""

            // Calculate progress from total/completed bytes
            if let total = json["total"] as? Int64,
               let completed = json["completed"] as? Int64,
               total > 0 {
                let progress = Double(completed) / Double(total)
                pullProgress = progress
                pullStatusText = status
                setupState = .pullingModel(progress: progress, status: status)
            } else {
                pullStatusText = status
                setupState = .pullingModel(progress: pullProgress, status: status)
            }

            if status == "success" {
                pullProgress = 1.0
                pullStatusText = status
                setupState = .pullingModel(progress: 1.0, status: status)
                break
            }
        }
    }

    // MARK: - Error Mapping

    private func friendlyMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .notConnectedToInternet:
            return "Download failed — check your internet connection and try again."
        case .cancelled, .networkConnectionLost, .timedOut:
            return "Download was interrupted. Tap retry to resume where you left off."
        default:
            return "Download failed — check your internet connection and try again."
        }
    }
}
