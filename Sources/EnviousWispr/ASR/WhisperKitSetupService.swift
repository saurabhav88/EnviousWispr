@preconcurrency import WhisperKit
import Foundation

/// Free function (nonisolated) that wraps WhisperKit.download() and relays progress
/// via an AsyncStream continuation. The continuation is Sendable, so this avoids
/// Swift 6 data-race diagnostics around sending a MainActor-captured closure
/// to a nonisolated function.
private func whisperKitDownload(
    variant: String,
    progressContinuation: AsyncStream<Double>.Continuation
) async throws {
    defer { progressContinuation.finish() }
    _ = try await WhisperKit.download(
        variant: variant,
        progressCallback: { progress in
            progressContinuation.yield(progress.fractionCompleted)
        }
    )
}

/// States in the WhisperKit model setup flow.
enum WhisperKitSetupState: Equatable {
    case checking           // initial detection
    case notDownloaded      // model not on disk
    case downloading(progress: Double, status: String) // actively downloading
    case ready              // model cached locally, ready to use
    case error(String)
}

/// Guides users through WhisperKit model download.
/// Downloads happen in Settings — NOT auto-triggered on first record.
@MainActor
@Observable
final class WhisperKitSetupService {

    // MARK: - Public State

    private(set) var setupState: WhisperKitSetupState = .checking

    /// Model variant to download (synced from AppSettings).
    // BRAIN: gotcha id=model-name-format
    var modelVariant: String = "openai_whisper-large-v3_turbo"

    // MARK: - Private

    private var downloadTask: Task<Void, Never>?

    /// WhisperKit model storage directory.
    /// WhisperKit 0.12+ downloads models to ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
    /// nonisolated(unsafe) is required: the class is @MainActor but nonisolated static methods reference this.
    nonisolated(unsafe) private static let whisperKitModelRoot: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")

    // MARK: - Detection

    private var lastDetectTime: Date?

    /// Check whether the model is already cached locally.
    /// Sets setupState to .ready or .notDownloaded (never triggers a download).
    /// Caches result for 5 seconds to avoid redundant file I/O on tab switches.
    func detectState() async {
        if let lastTime = lastDetectTime,
           Date().timeIntervalSince(lastTime) < 5.0,
           setupState != .checking {
            return
        }

        setupState = .checking
        let isDownloaded = WhisperKitSetupService.isModelCached(variant: modelVariant)
        setupState = isDownloaded ? .ready : .notDownloaded
        lastDetectTime = Date()
    }

    /// Force a fresh state check, ignoring cache.
    func forceDetectState() async {
        lastDetectTime = nil
        await detectState()
    }

    /// Returns true if a folder matching the given model variant exists in the HF cache.
    nonisolated static func isModelCached(variant: String) -> Bool {
        return getLocalModelPath(variant: variant) != nil
    }

    /// Returns the local path to a cached WhisperKit model, or nil if not downloaded.
    /// WhisperKit 0.12+ stores models as direct subdirectories like `openai_whisper-large-v3`.
    nonisolated static func getLocalModelPath(variant: String) -> String? {
        guard let root = whisperKitModelRoot else { return nil }

        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }

        let variantLower = variant.lowercased()
        let sanitizedLower = variant.replacingOccurrences(of: "-", with: "_").lowercased()

        guard let contents = try? fm.contentsOfDirectory(atPath: root.path) else {
            return nil
        }

        for dir in contents {
            let lower = dir.lowercased()
            if lower.contains(variantLower) || lower.contains(sanitizedLower) {
                let fullPath = root.appendingPathComponent(dir).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    return fullPath
                }
            }
        }
        return nil
    }

    // MARK: - Download

    /// Start downloading the model with progress tracking.
    func downloadModel() {
        downloadTask?.cancel()
        setupState = .downloading(progress: 0, status: "Starting download...")

        let variant = modelVariant
        downloadTask = Task { [weak self] in
            // Run the actual network download on a detached task (nonisolated context).
            // Progress fractions are relayed back via an AsyncStream so there is no
            // actor-isolated closure sent to a nonisolated function (Swift 6 safe).
            let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()

            let downloadResult: Task<Void, Error> = Task.detached {
                // The progress callback runs on whatever thread URLSession uses.
                // It feeds into the stream (safe — AsyncStream continuation is Sendable).
                try await whisperKitDownload(
                    variant: variant,
                    progressContinuation: progressContinuation
                )
            }

            // Consume progress updates on the MainActor while the download runs.
            // If outer Task is cancelled, exit the loop and cancel the inner download.
            for await fraction in progressStream {
                if Task.isCancelled { break }
                guard let self else { break }
                self.setupState = .downloading(progress: fraction, status: "Downloading model files...")
            }

            // If the outer Task was cancelled, cancel the inner detached download too.
            if Task.isCancelled {
                downloadResult.cancel()
                self?.setupState = .notDownloaded
                return
            }

            do {
                try await downloadResult.value
                guard let self else { return }
                self.lastDetectTime = Date()
                self.setupState = .ready
            } catch is CancellationError {
                self?.setupState = .notDownloaded
                downloadResult.cancel()
            } catch {
                self?.setupState = .error(
                    "Download failed — check your internet connection and try again."
                )
            }
        }
    }

    /// Cancel an in-progress download.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        setupState = .notDownloaded
    }
}
