import Foundation

/// States in the WhisperKit model setup flow.
public enum WhisperKitSetupState: Equatable {
  case checking  // initial detection
  case notDownloaded  // model not on disk
  case downloading(progress: Double, status: String)  // actively downloading
  case ready  // model cached locally, ready to use
  case error(String)
}

/// Presents WhisperKit model setup in Settings. Downloads happen there — NEVER
/// auto-triggered on first record.
///
/// #1386 PR-2 hollowed this out. It used to own a `WhisperKit.download()` task
/// pointed at a folder we do not control, and treat a 3-artifact directory probe
/// as proof a model existed. Both are gone: availability is controller admission
/// alone, and fetching goes through the verified delivery path. What remains is
/// presentation — the same `downloadModel()` / `cancelDownload()` surface the
/// Settings view already calls, now delegating to injected actions so this type
/// holds no download task and no cache truth of its own.
@MainActor
@Observable
public final class WhisperKitSetupService {

  // MARK: - Public State

  public private(set) var setupState: WhisperKitSetupState = .checking

  /// Model variant. Source of truth: `WhisperKitBackend.defaultModelVariant()`.
  // BRAIN: gotcha id=model-name-format
  public let modelVariant: String = WhisperKitBackend.defaultModelVariant()

  /// Reads current availability: `.ready` when an admitted verified model exists,
  /// admission truth alone; a refused foreign copy is simply not an installed model.
  /// `.notDownloaded` otherwise. Injected by the composition root over the
  /// delivery handle + relocation coordinator — ASR imports neither Pipeline nor
  /// ModelDelivery, so the dependency arrives as a closure.
  private let readAvailability: @MainActor () async -> WhisperKitSetupState
  /// The explicit Download action (controller-backed). Returns whether the
  /// request was ACCEPTED — false means refused (kill switch off, no wiring)
  /// and no delivery state will ever arrive for it.
  private let startDownload: @MainActor () async -> Bool
  /// The explicit Cancel action (controller-backed; drains the active fetch).
  private let cancelActiveDownload: @MainActor () async -> Void

  /// The default wiring reports "not downloaded" and does nothing: a build with
  /// no delivery wiring must offer no fetch at all rather than quietly resurrect
  /// an unverified one.
  public init(
    readAvailability: @escaping @MainActor () async -> WhisperKitSetupState = { .notDownloaded },
    startDownload: @escaping @MainActor () async -> Bool = { false },
    cancelActiveDownload: @escaping @MainActor () async -> Void = {}
  ) {
    self.readAvailability = readAvailability
    self.startDownload = startDownload
    self.cancelActiveDownload = cancelActiveDownload
  }

  // MARK: - Detection

  private var lastDetectTime: Date?

  /// Refresh from delivery truth. Never downloads. Caches for 5s so tab switches
  /// do not re-ask on every appearance.
  public func detectState() async {
    if let lastTime = lastDetectTime,
      Date().timeIntervalSince(lastTime) < 5.0,
      setupState != .checking
    {
      return
    }
    setupState = .checking
    setupState = await readAvailability()
    lastDetectTime = Date()
  }

  /// Force a fresh state check, ignoring the cache.
  public func forceDetectState() async {
    lastDetectTime = nil
    await detectState()
  }

  /// Apply a delivery-state projection pushed by the composition root (the
  /// download's live progress). Kept separate from `detectState()` so a push
  /// never fights the 5s read cache.
  public func applyDeliveryState(_ state: WhisperKitSetupState) {
    setupState = state
    if case .ready = state { lastDetectTime = Date() }
  }

  // MARK: - Download

  /// The user asked for the model. Delegates to the verified delivery path; the
  /// state projection drives progress from there. A REFUSED request re-detects
  /// instead — no delivery state will ever arrive for it, and leaving the
  /// optimistic "Starting download..." up would stick forever (Codex 2b-r1 P2).
  public func downloadModel() {
    setupState = .downloading(progress: 0, status: "Starting download...")
    Task { [startDownload, weak self] in
      if await startDownload() == false {
        await self?.forceDetectState()
      }
    }
  }

  /// Cancel an in-progress download. Acknowledgment is instant by design — the
  /// controller's cancel resolves only after its drain.
  public func cancelDownload() {
    Task { [cancelActiveDownload, weak self] in
      await cancelActiveDownload()
      await self?.forceDetectState()
    }
  }
}
