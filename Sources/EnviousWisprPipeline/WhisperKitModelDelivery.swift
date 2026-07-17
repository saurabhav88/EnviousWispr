import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Thrown when the multilingual (WhisperKit) delivery stage ends in a typed
/// failure — carries the class/detail so the App layer can render the delivery
/// state copy through the existing setup surface. Sibling of
/// `ParakeetDeliveryError`.
public struct WhisperKitDeliveryError: Error, Equatable {
  public let reason: DeliveryFailureClass
  public let detail: String?

  init(_ failure: DeliveryFailure) {
    self.reason = failure.reason
    self.detail = failure.detail
  }
}

/// #1525 identity pin: a fixed wire identity for the Sentry model-load-failed
/// path when multilingual delivery cannot be ensured. NEVER change this string
/// once shipped (mirrors `ParakeetDeliveryError`).
extension WhisperKitDeliveryError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    "EnviousWisprPipeline.WhisperKitDeliveryError#1"
  }

  public var sentrySemanticID: String { "whisper_kit.delivery_failed" }
}

/// Pipeline-side handle for the multilingual (WhisperKit) delivery stage
/// (#1386 PR-2): the ONE object the retirement coordinator + setup wiring talk
/// to. A THIN facade over the shared `ModelDeliveryController` — it owns the
/// D5 kill-switch read and forwards the controller calls; it holds NO durable
/// retirement state (that is the coordinator's; contract §5b).
/// Built once by `WisprBootstrapper` beside the shared controller.
///
/// Unlike `ParakeetDeliveryHandle` this handle does NOT bridge to the shared
/// `ProgressFile`: multilingual is the BACKUP engine and its download progress
/// surfaces in the AI/Speech settings row via the injected delivery-state
/// projection (§3d), not the cold-press wedge-guard channel that watches the
/// SELECTED engine's warm-up.
@MainActor
public final class WhisperKitDeliveryHandle {
  private let controller: ModelDeliveryController
  private let registration: DeliveryRegistration
  private let defaults: UserDefaults

  public init(
    controller: ModelDeliveryController, registration: DeliveryRegistration,
    defaults: UserDefaults? = nil
  ) {
    self.controller = controller
    self.registration = registration
    self.defaults = defaults ?? UserDefaults(suiteName: DeliveryFlags.suiteName) ?? .standard
  }

  /// Register a delivery-state observer scoped to THIS family — the injected
  /// projection (§3d) that maps `DeliveryState` into the ASR-local setup state.
  ///
  /// Sequenced (Codex 2b-r4 P2): each update re-hops to MainActor in its own
  /// task, whose execution order is not guaranteed — a delayed `.downloading`
  /// could overwrite a later `.admitted` and leave Settings reporting a
  /// finished model as unavailable. Mint in the observer (publish order on the
  /// controller actor), drop stale applications on MainActor — the same
  /// contract `ModelDeliveryHome` applies to the other families.
  public func observeState(_ handler: @escaping @MainActor @Sendable (DeliveryState) -> Void) {
    let identity = registration.manifest.identity
    let sequencer = DeliveryStateSequencer()
    let gate = AppliedStateGate()
    Task {
      await controller.addStateObserver { [identity] observedIdentity, state in
        guard observedIdentity == identity else { return }
        let seq = sequencer.next()
        Task { @MainActor in
          guard gate.admit(seq) else { return }
          handler(state)
        }
      }
    }
  }

  /// The D5 kill-switch, read fresh per attempt (relaunch-free legacy fallback).
  public func isEnabled() -> Bool {
    defaults.object(forKey: DeliveryFlags.key("enabled", family: .whisperKit)) as? Bool ?? true
  }

  /// Whether the owned cache is currently admitted (marker fast path, no fetch).
  public func isAdmitted() async -> Bool {
    await controller.isAdmitted(registration)
  }

  /// Adopt an already-complete owned cache WITHOUT fetching (launch / settings
  /// open) — never starts a multi-GB download behind the user's back.
  public func adoptIfPresent() async -> Bool {
    await controller.admitIfComplete(registration)
  }

  /// The EXPLICIT download door (user Download / Update) — fetches the pinned
  /// HF source into the owned folder.
  public func ensureAvailable() async -> ModelDeliveryController.DeliveryOutcome {
    await controller.ensureModelAvailable(registration)
  }

  /// No `repair()` here, unlike the Parakeet and EG-1 handles (#1386 PR-2, Codex
  /// code-diff r6). The shared primitive re-fetches what it could not verify, and
  /// for this engine a download is only ever the user's explicit choice (#1339).
  /// Not an omission to fix later: the absence IS the policy.

  /// User Cancel during the download — cooperative; resolves after the live
  /// attempt fully drains.
  public func cancelActiveFetch() async {
    _ = await controller.cancel(registration.manifest.identity)
  }

}

/// MainActor-serialized "apply only if newer" gate for the sequenced state
/// projection above.
@MainActor private final class AppliedStateGate {
  private var last: UInt64 = 0

  func admit(_ seq: UInt64) -> Bool {
    guard seq > last else { return false }
    last = seq
    return true
  }
}
