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

/// Guides users through Ollama installation, server startup, and model pulling.
@MainActor
@Observable
final class OllamaSetupService {

    // MARK: - Public State

    private(set) var setupState: OllamaSetupState = .detecting
    private(set) var pullProgress: Double = 0
    private(set) var pullStatusText: String = ""

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
        Task {
            let maxAttempts = 20
            for _ in 0..<maxAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms

                if await isServerRunning() {
                    if await hasAnyModels() {
                        setupState = .ready
                        UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
                    } else {
                        setupState = .runningNoModels
                    }
                    return
                }
            }

            setupState = .error(
                "Couldn't start Ollama automatically. Try running `ollama serve` in Terminal."
            )
        }
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
