import Foundation

/// #1177 (Telemetry Bible Phase 8): the telemetry seam for quiet-limb failures that
/// occur INSIDE the `EnviousWisprLLM` module (cloud pre-warm, legacy-key cleanup).
///
/// The LLM module depends only on Core + ArgmaxOSS — not on Services / PostHog /
/// Sentry. Rather than pull that weight upward (a new `LLM -> Services` edge), the
/// module takes this injected sink — the established `HotkeyTelemetrySink` pattern.
/// The TYPE lives in Core (Foundation-only, NO Services types — Codex grounded review
/// r2); the `.live` factory that maps these callbacks onto `TelemetryService` +
/// `SentryBreadcrumb` lives in Services and is injected by the App composition root.
/// Defaults to `.noop`, so every other construction site (the two connector
/// default-args, the ~43 test sites) stays silent.
///
/// Closures are `@Sendable` and fire-and-forget: the `.live` implementation hops to
/// the `@MainActor` `TelemetryService` internally, so callers in any isolation — the
/// `Task.detached` pre-warm, the synchronous Keychain cleanup — just call them
/// without awaiting and never block the heart path.
public struct LLMTelemetrySink: Sendable {
  /// A quiet-limb failure was observed → the `limb.failure_observed` population event.
  /// Metadata only (never transcript / content / key material).
  public let limbFailure:
    @Sendable (
      _ limb: String, _ operation: String, _ result: String,
      _ errorCategory: String, _ durationMs: Int?
    ) -> Void

  /// The legacy plaintext API-key file could not be deleted after migration to the
  /// Keychain → a security-relevant Sentry handled error. The `.live` factory maps
  /// this to the `legacyKeyCleanupFailed` category; the payload carries only the
  /// account name and the bridged error signature, never the key material.
  public let legacyKeyCleanupFailed: @Sendable (_ error: any Error, _ account: String) -> Void

  /// #2093: a cloud pre-warm request is about to leave → `llm.prewarm_started`.
  ///
  /// This exists to MEASURE C4, and it is the only thing that can. The obvious
  /// proxy — watching `rate_or_quota` fall — moves for reasons we do not control
  /// (a user's own separate usage, provider policy), so it is a guardrail and
  /// never the evidence. The ratio that answers "did we stop spending the user's
  /// quota" is this event over accepted-plus-failed polishes, per provider.
  ///
  /// Emitted immediately BEFORE the request is sent and AFTER every key, model
  /// and construction guard — so it counts requests that actually leave, not
  /// intentions. Metadata only: provider and model, never key material.
  public let prewarmStarted: @Sendable (_ provider: String, _ model: String) -> Void

  /// `prewarmStarted` is deliberately NOT defaulted. Only three sites construct
  /// this type, so requiring it costs almost nothing and makes the compiler,
  /// rather than a reviewer, catch a `.live` factory that forgets to wire the
  /// event — the failure mode where the counter silently never fires and the
  /// change looks unmeasurable rather than broken.
  public init(
    limbFailure: @escaping @Sendable (String, String, String, String, Int?) -> Void,
    legacyKeyCleanupFailed: @escaping @Sendable (any Error, String) -> Void,
    prewarmStarted: @escaping @Sendable (String, String) -> Void
  ) {
    self.limbFailure = limbFailure
    self.legacyKeyCleanupFailed = legacyKeyCleanupFailed
    self.prewarmStarted = prewarmStarted
  }

  /// No-op sink — the default at every construction site except the App composition
  /// root (which injects `.live`). Keeps tests and keyless paths silent.
  public static let noop = LLMTelemetrySink(
    limbFailure: { _, _, _, _, _ in },
    legacyKeyCleanupFailed: { _, _ in },
    prewarmStarted: { _, _ in })
}
