import AppKit
import Foundation

/// States in the Ollama guided-setup flow.
public enum OllamaSetupState: Equatable {
  case detecting
  case notInstalled
  case installedNotRunning
  case runningNoModels
  case pullingModel(progress: Double, status: String)
  case ready
  case error(String)
}

/// Warm-up state for the currently selected Ollama model.
public enum OllamaWarmupState: Equatable {
  case idle
  case warming(model: String)
  case warm(model: String, expiresAt: Date)
  case failed(model: String)

  /// Whether the given model is currently warm (not expired).
  public func isWarm(for model: String) -> Bool {
    if case .warm(let m, let expires) = self, m == model {
      return Date() < expires
    }
    return false
  }
}

/// Quality tier for Ollama catalog models.
public enum OllamaQualityTier: String, Sendable {
  case best = "best"
  case medium = "medium"
  case worst = "worst"

  public var label: String {
    switch self {
    case .best: return "Best"
    case .medium: return "Medium"
    case .worst: return "Fast"
    }
  }
}

/// A model entry in the Ollama catalog (curated or dynamic).
public struct OllamaModelCatalogEntry: Identifiable, Sendable {
  public let name: String
  public let displayName: String
  public let parameterCount: String
  public let qualityTier: OllamaQualityTier
  public let downloadSize: String
  public let isDownloaded: Bool

  public var id: String { name }

  public init(
    name: String,
    displayName: String,
    parameterCount: String,
    qualityTier: OllamaQualityTier,
    downloadSize: String,
    isDownloaded: Bool = false
  ) {
    self.name = name
    self.displayName = displayName
    self.parameterCount = parameterCount
    self.qualityTier = qualityTier
    self.downloadSize = downloadSize
    self.isDownloaded = isDownloaded
  }
}

/// A model parsed from Ollama's /api/tags response.
public struct OllamaDownloadedModel: Sendable {
  public let exactName: String
  public let canonicalName: String
  public let parameterSize: String?
  public let parameterBillions: Double?
  public let fileSizeBytes: Int64
  public let displayName: String
}

/// Guides users through Ollama installation, server startup, and model pulling.
@MainActor
@Observable
public final class OllamaSetupService {

  // MARK: - Public State

  public private(set) var setupState: OllamaSetupState = .detecting
  public private(set) var pullProgress: Double = 0
  public private(set) var pullStatusText: String = ""
  public private(set) var currentPullingModel: String?
  public private(set) var downloadedModels: [OllamaDownloadedModel] = []
  public private(set) var warmupState: OllamaWarmupState = .idle

  // Per-pull generation token. Bumped on every pullModel/cancelPull call so stale
  // tasks can no-op their writes (Swift Task cancellation is cooperative; without
  // this, a late chunk or terminal-branch cleanup from an old task could clobber
  // the newer pull's state, most acutely on cancel-then-re-download-same-model).
  private var pullEpoch: UInt64 = 0

  /// Canonical names of downloaded models. Backward-compatible with old Set<String> consumers.
  public var downloadedModelNames: Set<String> {
    Set(downloadedModels.map(\.canonicalName))
  }

  // MARK: - Model Catalog

  /// Curated suggestions for users who haven't downloaded models yet.
  public static let modelCatalog: [OllamaModelCatalogEntry] = [
    OllamaModelCatalogEntry(
      name: "gemma3n:e4b", displayName: "Gemma 3 Nano (4B)", parameterCount: "4B",
      qualityTier: .best, downloadSize: "~6 GB"),
    OllamaModelCatalogEntry(
      name: "llama3.2", displayName: "Llama 3.2", parameterCount: "3B", qualityTier: .best,
      downloadSize: "~2 GB"),
    OllamaModelCatalogEntry(
      name: "llama3.2:1b", displayName: "Llama 3.2 (1B)", parameterCount: "1B",
      qualityTier: .medium, downloadSize: "~800 MB"),
    OllamaModelCatalogEntry(
      name: "mistral", displayName: "Mistral", parameterCount: "7B", qualityTier: .best,
      downloadSize: "~4 GB"),
    OllamaModelCatalogEntry(
      name: "phi3", displayName: "Phi-3 Mini", parameterCount: "3.8B", qualityTier: .medium,
      downloadSize: "~2.3 GB"),
    OllamaModelCatalogEntry(
      name: "gemma2:2b", displayName: "Gemma 2 (2B)", parameterCount: "2B", qualityTier: .medium,
      downloadSize: "~1.6 GB"),
    OllamaModelCatalogEntry(
      name: "gemma2", displayName: "Gemma 2", parameterCount: "9B", qualityTier: .best,
      downloadSize: "~5.5 GB"),
    OllamaModelCatalogEntry(
      name: "qwen2.5:3b", displayName: "Qwen 2.5 (3B)", parameterCount: "3B", qualityTier: .medium,
      downloadSize: "~1.9 GB"),
    OllamaModelCatalogEntry(
      name: "qwen2.5:7b", displayName: "Qwen 2.5 (7B)", parameterCount: "7B", qualityTier: .best,
      downloadSize: "~4.4 GB"),
    OllamaModelCatalogEntry(
      name: "tinyllama", displayName: "TinyLlama", parameterCount: "1.1B", qualityTier: .worst,
      downloadSize: "~638 MB"),
    OllamaModelCatalogEntry(
      name: "phi-2", displayName: "Phi-2", parameterCount: "2.7B", qualityTier: .worst,
      downloadSize: "~1.7 GB"),
  ]

  /// Dynamic catalog: downloaded models first (with real metadata), then undownloaded suggestions.
  public var dynamicCatalog: [OllamaModelCatalogEntry] {
    let canonicalDownloaded = Set(downloadedModels.map(\.canonicalName))

    // Build catalog entries from downloaded models
    let downloadedEntries: [OllamaModelCatalogEntry] = downloadedModels.map { model in
      // Overlay curated metadata if we have a catalog match
      if let curated = Self.modelCatalog.first(where: {
        Self.canonicalModelName($0.name) == model.canonicalName
      }) {
        return OllamaModelCatalogEntry(
          name: model.exactName,
          displayName: curated.displayName,
          parameterCount: model.parameterSize ?? curated.parameterCount,
          qualityTier: curated.qualityTier,
          downloadSize: Self.formatFileSize(model.fileSizeBytes),
          isDownloaded: true
        )
      }

      // Unknown/custom model: infer metadata
      return OllamaModelCatalogEntry(
        name: model.exactName,
        displayName: Self.inferDisplayName(from: model.exactName),
        parameterCount: model.parameterSize ?? "Unknown",
        qualityTier: Self.inferQualityTier(parameterBillions: model.parameterBillions),
        downloadSize: Self.formatFileSize(model.fileSizeBytes),
        isDownloaded: true
      )
    }
    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

    // Undownloaded suggestions (preserve static catalog order)
    let suggestions: [OllamaModelCatalogEntry] = Self.modelCatalog.compactMap { entry in
      let canonical = Self.canonicalModelName(entry.name)
      guard !canonicalDownloaded.contains(canonical) else { return nil }
      return entry
    }

    return downloadedEntries + suggestions
  }

  // MARK: - Name Normalization

  /// Canonical name: strips `:latest` suffix only. All other tags preserved.
  public nonisolated static func canonicalModelName(_ name: String) -> String {
    if name.hasSuffix(":latest") {
      return String(name.dropLast(":latest".count))
    }
    return name
  }

  // MARK: - Parameter Size Parsing

  /// Parse Ollama parameter size strings like "3B", "3.2B", "500M", "1T" into billions.
  /// Returns nil if parsing fails.
  public nonisolated static func parseParameterSize(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let upper = trimmed.uppercased()
    let multiplier: Double

    if upper.hasSuffix("B") {
      multiplier = 1.0
    } else if upper.hasSuffix("M") {
      multiplier = 0.001
    } else if upper.hasSuffix("T") {
      multiplier = 1000.0
    } else {
      return nil
    }

    let numberPart = String(upper.dropLast())
    guard let value = Double(numberPart), value > 0 else { return nil }
    return value * multiplier
  }

  // MARK: - Weak Model Detection

  /// Hardcoded fallback prefixes for weak model detection when parameter size
  /// is unknown and no size tag is present. Covers:
  /// - `tinyllama` (1.1B, all variants)
  /// - `phi-2` (2.7B, bare name)
  /// - `gemma2:2b` (2B, tagged)
  /// - `llama3.2` (3B default; bare name used as the app's default Ollama model)
  nonisolated private static let weakModelFallbackPrefixes: [String] = [
    "tinyllama", "phi-2", "gemma2:2b", "llama3.2",
  ]

  /// Matches a size tag like `:1b`, `:3b`, `:0.5b` — Ollama's standard naming
  /// convention for parameter-count variants. Used as a fallback when we don't
  /// have downloaded-model metadata for the exact parameter billions.
  nonisolated private static let sizeTagRegex = try? NSRegularExpression(
    pattern: #":(\d+(?:\.\d+)?)b(?:-|$|\s|:)"#,
    options: .caseInsensitive
  )

  /// Determine if a model should receive a simplified system prompt.
  /// Resolution order (strongest signal first):
  /// 1. Explicit `parameterBillions` from downloaded-model metadata.
  /// 2. `:Nb` size tag in the name (e.g. `llama3.2:70b` → 70B, not weak; `qwen2.5:3b` → weak).
  /// 3. Hardcoded fallback prefix list for bare names without any size hint.
  public nonisolated static func isWeakModel(_ name: String, parameterBillions: Double? = nil)
    -> Bool
  {
    if let billions = parameterBillions {
      return billions <= 3.0
    }
    let lower = name.lowercased()
    // Size tag is authoritative when present (overrides prefix defaults so
    // `llama3.2:70b` is correctly classified as non-weak even though the
    // `llama3.2` family is in the prefix list).
    let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
    if let match = sizeTagRegex?.firstMatch(in: lower, range: range),
      match.numberOfRanges > 1,
      let billionsRange = Range(match.range(at: 1), in: lower),
      let billions = Double(lower[billionsRange])
    {
      return billions <= 3.0
    }
    return weakModelFallbackPrefixes.contains(where: { lower.hasPrefix($0) })
  }

  /// Known thinking-capable Ollama model family prefixes (as of 2026-04).
  /// These families emit reasoning into `message.thinking` separately from the
  /// final answer in `message.content`. Because the reasoning still counts
  /// against `num_predict`, these models need a larger token budget to avoid
  /// truncating the final answer to empty (#272).
  nonisolated private static let thinkingCapableFamilyPrefixes: [String] = [
    "gemma4",  // Google Gemma 4 (thinking capability in Ollama 0.20+)
    "qwen3",  // Alibaba Qwen 3 reasoning
    "deepseek-r1",  // DeepSeek R1 reasoning
    "gpt-oss",  // OpenAI gpt-oss (low/medium/high thinking)
  ]

  /// Determine if a model emits separate thinking tokens that consume
  /// `num_predict` budget. Used to decide whether to grant the larger
  /// 2048-token floor in `LLMPolishStep` (non-thinking models stay on the
  /// tight 256 floor so they can't outrun the 15s pipeline timeout on a
  /// rambly generation).
  public nonisolated static func isThinkingCapableModel(_ name: String) -> Bool {
    let lower = name.lowercased()
    return thinkingCapableFamilyPrefixes.contains(where: { lower.hasPrefix($0) })
  }

  /// Convenience: check if a model name is weak using downloaded model metadata.
  public func isWeakModel(_ name: String) -> Bool {
    let canonical = Self.canonicalModelName(name)
    let downloaded = downloadedModels.first(where: { $0.canonicalName == canonical })
    return Self.isWeakModel(name, parameterBillions: downloaded?.parameterBillions)
  }

  // MARK: - Private

  private var ollamaProcess: Process?
  private var pullTask: Task<Void, Never>?
  private var warmupTask: Task<Void, Never>?

  private static let binaryPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
  private static let baseURL = "http://localhost:11434"
  private static let lastKnownStateKey = "OllamaSetupService.lastKnownReady"

  // MARK: - Detection Pipeline

  public init() {}

  /// Run the full detection pipeline: binary -> server -> models.
  public func detectState() async {
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
  public func findOllamaBinary() -> String? {
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
      FileManager.default.isExecutableFile(atPath: path)
    else {
      return nil
    }
    return path
  }

  // MARK: - Server Health

  /// Check whether the Ollama server is reachable. Strict 3-second timeout.
  public func isServerRunning() async -> Bool {
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
  public func hasAnyModels() async -> Bool {
    await refreshDownloadedModels()
    return !downloadedModels.isEmpty
  }

  // MARK: - Model Management

  /// Refresh the list of downloaded models from GET /api/tags, parsing full metadata.
  public func refreshDownloadedModels() async {
    guard let url = URL(string: "\(Self.baseURL)/api/tags") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      guard let models = json?["models"] as? [[String: Any]] else { return }
      downloadedModels = models.compactMap { model -> OllamaDownloadedModel? in
        guard let name = model["name"] as? String else { return nil }
        let canonical = Self.canonicalModelName(name)

        // Parse details.parameter_size
        let details = model["details"] as? [String: Any]
        let parameterSize = details?["parameter_size"] as? String
        let parameterBillions = parameterSize.flatMap { Self.parseParameterSize($0) }

        // Parse file size (Int64 for large models)
        let fileSizeBytes: Int64
        if let size = model["size"] as? Int64 {
          fileSizeBytes = size
        } else if let size = model["size"] as? Int {
          fileSizeBytes = Int64(size)
        } else {
          fileSizeBytes = 0
        }

        let displayName = Self.inferDisplayName(from: name)

        return OllamaDownloadedModel(
          exactName: name,
          canonicalName: canonical,
          parameterSize: parameterSize,
          parameterBillions: parameterBillions,
          fileSizeBytes: fileSizeBytes,
          displayName: displayName
        )
      }
    } catch {
      // Silently ignore -- server may not be running
    }
  }

  /// Delete a model by name via DELETE /api/delete.
  public func deleteModel(name: String) {
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
          downloadedModels.removeAll(where: { $0.exactName == name })
          // Reset warm-up if the deleted model was warmed or warming
          let canonical = Self.canonicalModelName(name)
          switch warmupState {
          case .warm(let m, _) where m == canonical,
            .warming(let m) where m == canonical:
            resetWarmup()
          default:
            break
          }
          // If current model was deleted, update setup state
          if downloadedModels.isEmpty {
            setupState = .runningNoModels
            UserDefaults.standard.set(false, forKey: Self.lastKnownStateKey)
          }
        }
      } catch {
        // Silently ignore delete errors -- user can try again
      }
    }
  }

  // MARK: - Server Lifecycle

  /// Start the Ollama server, preferring the .app bundle, falling back to the CLI binary.
  public func startServer() {
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
        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        guard let self else { return }

        if await self.isServerRunning() {
          if await self.hasAnyModels() {
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
  public func cleanup() {
    ollamaProcess?.terminate()
    ollamaProcess = nil
  }

  // MARK: - Model Pulling

  /// Pull a model by name, streaming progress updates.
  public func pullModel(_ modelName: String) {
    // Cancel any in-flight pull and invalidate its epoch so stale writes no-op.
    pullTask?.cancel()
    pullTask = nil
    pullEpoch &+= 1
    let epoch = pullEpoch

    // Reset progress
    currentPullingModel = modelName
    pullProgress = 0
    pullStatusText = "Starting download..."
    setupState = .pullingModel(progress: 0, status: "Starting download...")

    pullTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.performStreamingPull(modelName: modelName, epoch: epoch)
        guard self.pullEpoch == epoch else { return }
        await self.refreshDownloadedModels()
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        self.setupState = .ready
        UserDefaults.standard.set(true, forKey: Self.lastKnownStateKey)
      } catch is CancellationError {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        // Bug fix: don't force .runningNoModels if models exist
        if self.downloadedModels.isEmpty {
          self.setupState = .runningNoModels
        } else {
          self.setupState = .ready
        }
      } catch let urlError as URLError {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        self.setupState = .error(self.friendlyMessage(for: urlError))
      } catch {
        guard self.pullEpoch == epoch else { return }
        self.currentPullingModel = nil
        let message = error.localizedDescription.lowercased()
        if message.contains("no space") || message.contains("errno 28") {
          self.setupState = .error(
            "Not enough disk space. The model needs about 2 GB free."
          )
        } else {
          self.setupState = .error(
            "Download failed. Check your internet connection and try again."
          )
        }
      }
    }
  }

  /// Cancel an in-progress model pull.
  public func cancelPull() {
    pullTask?.cancel()
    pullTask = nil
    pullEpoch &+= 1
    currentPullingModel = nil
    // Bug fix: don't force .runningNoModels if models exist
    if downloadedModels.isEmpty {
      setupState = .runningNoModels
    } else {
      setupState = .ready
    }
  }

  // MARK: - Model Warm-up

  /// Warm up a model by sending a minimal request to load it into GPU memory.
  /// Cancels any in-flight warm-up for a different model.
  public func warmUpModel(_ modelName: String) {
    let canonical = Self.canonicalModelName(modelName)

    // Skip if already warm for this model and not expired
    if warmupState.isWarm(for: canonical) { return }

    // Skip if already warming this model
    if case .warming(let m) = warmupState, m == canonical { return }

    // Cancel any in-flight warm-up for a different model
    warmupTask?.cancel()
    warmupTask = nil

    warmupState = .warming(model: canonical)

    warmupTask = Task { [weak self] in
      defer { self?.warmupTask = nil }
      do {
        guard let url = URL(string: "\(Self.baseURL)/api/chat") else {
          self?.warmupState = .failed(model: canonical)
          return
        }

        let body: [String: Any] = [
          "model": modelName,
          "messages": [["role": "user", "content": "hi"]],
          "stream": false,
          "think": false,
          "keep_alive": "60m",
          "options": ["num_predict": 1],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (_, response) = try await URLSession.shared.data(for: request)

        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          self?.warmupState = .failed(model: canonical)
          return
        }

        let expirySeconds: TimeInterval = 55 * 60  // conservative vs 60m keep_alive
        self?.warmupState = .warm(
          model: canonical, expiresAt: Date().addingTimeInterval(expirySeconds))

        // Schedule state reset at expiry so the UI doesn't show a stale checkmark
        try? await Task.sleep(nanoseconds: UInt64(expirySeconds * 1_000_000_000))
        // Only reset if still warm for this model (not replaced by a newer warm-up)
        if case .warm(let m, _) = self?.warmupState, m == canonical {
          self?.warmupState = .idle
        }
      } catch is CancellationError {
        // Cancelled by a newer warm-up request; don't overwrite state
      } catch let error as URLError where error.code == .cancelled {
        // URLSession cancellation; same as above
      } catch {
        self?.warmupState = .failed(model: canonical)
      }
    }
  }

  /// Reset warm-up state (e.g., when provider changes away from Ollama).
  public func resetWarmup() {
    warmupTask?.cancel()
    warmupTask = nil
    warmupState = .idle
  }

  // MARK: - Streaming Pull (Private)

  private func performStreamingPull(modelName: String, epoch: UInt64) async throws {
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
    request.timeoutInterval = 600  // 10 minutes

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw LLMError.requestFailed("Ollama pull request failed")
    }

    for try await line in bytes.lines {
      try Task.checkCancellation()
      // Drop stale writes from a task whose pull was superseded by a newer
      // pullModel()/cancelPull() call. Epoch mismatch → bail silently.
      guard pullEpoch == epoch else { return }

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
        total > 0
      {
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

  // MARK: - Display Helpers

  /// Infer a display name from a raw Ollama model name.
  nonisolated static func inferDisplayName(from name: String) -> String {
    let base = name.components(separatedBy: ":").first ?? name
    return base.replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: ".", with: " ")
      .split(separator: " ")
      .map { $0.prefix(1).uppercased() + $0.dropFirst() }
      .joined(separator: " ")
  }

  /// Infer quality tier from parameter count.
  nonisolated static func inferQualityTier(parameterBillions: Double?) -> OllamaQualityTier {
    guard let billions = parameterBillions else { return .medium }
    if billions >= 7.0 { return .best }
    if billions <= 2.0 { return .worst }
    return .medium
  }

  /// Format file size in bytes to human-readable string.
  nonisolated static func formatFileSize(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "Unknown" }
    let gb = Double(bytes) / 1_073_741_824.0
    if gb >= 1.0 {
      return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576.0
    return String(format: "%.0f MB", mb)
  }

  // MARK: - Error Mapping

  private func friendlyMessage(for urlError: URLError) -> String {
    switch urlError.code {
    case .notConnectedToInternet:
      return "Download failed. Check your internet connection and try again."
    case .cancelled, .networkConnectionLost, .timedOut:
      return "Download was interrupted. Tap retry to resume where you left off."
    default:
      return "Download failed. Check your internet connection and try again."
    }
  }
}
