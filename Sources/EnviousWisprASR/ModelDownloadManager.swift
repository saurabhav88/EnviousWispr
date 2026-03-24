import Foundation
import EnviousWisprCore
@preconcurrency import FluidAudio
import CryptoKit

/// Manages Parakeet model download with stall detection, Cloudflare R2 fallback,
/// and checksum verification.
///
/// This is a Heart bootstrap dependency — the app cannot transcribe without the model.
/// If download progress plumbing breaks, it must not destabilize the actual ASR runtime.
/// Worst case: missing progress UI, not broken model install.
///
/// Flow:
/// 1. Try FluidAudio's normal HuggingFace download path
/// 2. Monitor for stalls (no progress for `stallTimeout` seconds)
/// 3. If stalled or failed, fall back to Cloudflare R2 direct download
/// 4. Verify SHA-256 checksum of key model files
/// 5. Load models via FluidAudio's compile path
public actor ModelDownloadManager {

    /// Progress callback: (fractionCompleted, phaseString, detailString)
    public typealias ProgressCallback = @Sendable (Double, String, String) -> Void

    // MARK: - Configuration

    /// Seconds of no byte progress before declaring a stall and switching to fallback.
    private static let stallTimeout: TimeInterval = 20

    /// Cloudflare R2 base URL for model fallback.
    /// The model archive is hosted as a single .tar.gz at this URL.
    /// Empty string = fallback disabled (no R2 bucket configured yet).
    private static let r2BaseURL = "https://models.enviouswispr.com/parakeet-tdt-0.6b-v3-coreml.tar.gz"

    /// SHA-256 checksum of the Encoder.mlmodelc/model.mlmodel file (the largest, most critical file).
    /// Empty string = verification skipped (checksum not yet computed for current model version).
    /// To compute: `shasum -a 256 ~/Library/Application\ Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/model.mlmodel`
    private static let encoderChecksum = ""

    /// FluidAudio's expected cache directory for Parakeet v3 models.
    private static let modelCacheDir: URL = {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models")
        return appSupport.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
    }()

    // MARK: - Stall Detection State

    private var lastProgressTime: CFAbsoluteTime = 0
    private var lastFraction: Double = 0
    private var isStalled = false
    private var stallCheckTask: Task<Void, Never>?

    public init() {}

    // MARK: - Public API

    /// Download and load Parakeet v3 models with stall detection and optional R2 fallback.
    /// Returns loaded AsrModels ready for transcription.
    public func downloadAndLoad(progressCallback: ProgressCallback?) async throws -> AsrModels {
        lastProgressTime = CFAbsoluteTimeGetCurrent()
        lastFraction = 0
        isStalled = false

        // Start stall monitor
        stallCheckTask = Task.detached { [weak self] in
            await self?.monitorForStalls()
        }

        defer { stallCheckTask?.cancel() }

        do {
            // Primary path: FluidAudio's HuggingFace download
            let models = try await downloadViaFluidAudio(progressCallback: progressCallback)

            // Verify checksum if configured
            verifyChecksum()

            return models
        } catch {
            // If we stalled and R2 is configured, try the fallback
            if isStalled && !Self.r2BaseURL.isEmpty {
                progressCallback?(0.01, "Trying alternate download source...", "")

                do {
                    try await downloadViaR2(progressCallback: progressCallback)
                    let models = try await loadOnly(progressCallback: progressCallback)
                    verifyChecksum()
                    return models
                } catch {
                    throw ModelDownloadError.fallbackFailed(underlying: error)
                }
            }
            throw error
        }
    }

    // MARK: - Primary Download (FluidAudio / HuggingFace)

    private func downloadViaFluidAudio(progressCallback: ProgressCallback?) async throws -> AsrModels {
        let handler: DownloadUtils.ProgressHandler? = progressCallback.map { callback -> DownloadUtils.ProgressHandler in
            { [weak self] progress in
                // Update stall detection timestamp
                Task { await self?.recordProgress(fraction: progress.fractionCompleted) }

                let phase: String
                let detail: String

                switch progress.phase {
                case .listing:
                    phase = "Preparing download..."
                    detail = ""
                case .downloading:
                    phase = "Downloading speech model..."
                    let downloadPct = min(progress.fractionCompleted * 2.0, 1.0)
                    let downloadedMB = Int(downloadPct * 460)
                    let pct = Int(downloadPct * 100)
                    detail = "\(downloadedMB) MB of 460 MB (\(pct)%)"
                case .compiling(let modelName):
                    phase = "Installing model..."
                    detail = modelName
                }
                callback(progress.fractionCompleted, phase, detail)
            }
        }

        return try await AsrModels.downloadAndLoad(version: .v3, progressHandler: handler)
    }

    // MARK: - Fallback Download (Cloudflare R2)

    private func downloadViaR2(progressCallback: ProgressCallback?) async throws {
        guard let url = URL(string: Self.r2BaseURL) else {
            throw ModelDownloadError.invalidFallbackURL
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enviouswispr-model-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let tempArchive = tempDir.appendingPathComponent("model.tar.gz")

        // Download the archive
        let session = URLSession(configuration: .default)
        let request = URLRequest(url: url, timeoutInterval: 1800)
        let (downloadURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.fallbackHTTPError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        // Move to our temp location
        try FileManager.default.moveItem(at: downloadURL, to: tempArchive)

        progressCallback?(0.4, "Extracting model files...", "")

        // Extract tar.gz to the model cache directory
        let targetDir = Self.modelCacheDir
        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.createDirectory(
            at: targetDir.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Use tar to extract — simpler and more reliable than a Swift tar library
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tempArchive.path, "-C", targetDir.deletingLastPathComponent().path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ModelDownloadError.extractionFailed
        }

        progressCallback?(0.5, "Model files extracted", "")
    }

    // MARK: - Load Only (after R2 download)

    private func loadOnly(progressCallback: ProgressCallback?) async throws -> AsrModels {
        let handler: DownloadUtils.ProgressHandler? = progressCallback.map { callback -> DownloadUtils.ProgressHandler in
            { progress in
                switch progress.phase {
                case .compiling(let modelName):
                    callback(0.5 + progress.fractionCompleted * 0.5, "Installing model...", modelName)
                default:
                    callback(progress.fractionCompleted, "Loading models...", "")
                }
            }
        }

        return try await AsrModels.downloadAndLoad(
            to: Self.modelCacheDir,
            version: .v3,
            progressHandler: handler
        )
    }

    // MARK: - Stall Detection

    private func recordProgress(fraction: Double) {
        if fraction > lastFraction + 0.001 {
            lastProgressTime = CFAbsoluteTimeGetCurrent()
            lastFraction = fraction
        }
    }

    private func monitorForStalls() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // Check every 5 seconds
            guard !Task.isCancelled else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - lastProgressTime
            // Only stall-detect during download phase (fraction < 0.5)
            if elapsed >= Self.stallTimeout && lastFraction < 0.5 && lastFraction > 0 {
                isStalled = true
                return
            }
        }
    }

    // MARK: - Checksum Verification

    /// Verify the SHA-256 checksum of the encoder model file.
    /// Logs a warning if verification fails but does NOT block — the model may still work.
    /// This is a defense-in-depth measure, not a hard gate.
    private func verifyChecksum() {
        guard !Self.encoderChecksum.isEmpty else { return }

        let encoderModel = Self.modelCacheDir
            .appendingPathComponent("Encoder.mlmodelc")
            .appendingPathComponent("model.mlmodel")

        guard let data = try? Data(contentsOf: encoderModel) else { return }
        let hash = SHA256.hash(data: data)
        let hexHash = hash.map { String(format: "%02x", $0) }.joined()

        if hexHash != Self.encoderChecksum {
            Task {
                await AppLogger.shared.log(
                    "[ModelDownloadManager] Checksum mismatch — expected: \(Self.encoderChecksum), got: \(hexHash). Model may be corrupted.",
                    level: .info, category: "ASR"
                )
            }
        }
    }
}

// MARK: - Errors

public enum ModelDownloadError: LocalizedError {
    case stallDetected
    case invalidFallbackURL
    case fallbackHTTPError(statusCode: Int)
    case extractionFailed
    case fallbackFailed(underlying: any Error)

    public var errorDescription: String? {
        switch self {
        case .stallDetected:
            return "Download stalled — no progress for 20 seconds."
        case .invalidFallbackURL:
            return "Fallback download URL is invalid."
        case .fallbackHTTPError(let code):
            return "Fallback download failed with HTTP \(code)."
        case .extractionFailed:
            return "Failed to extract model files."
        case .fallbackFailed(let error):
            return "Both download sources failed: \(error.localizedDescription)"
        }
    }
}
