import EnviousWisprCore

/// What one engine supplies so the neutral lifecycle can run a local polish model on it (#4473).
///
/// An engine ADAPTER: it hands over operations and holds no policy. The runtime asks it for a
/// launch configuration and a health probe, with the runtime's own model identity; the process
/// manager and the coordinator execute what comes back. Everything about the PROCESS stays
/// with them and never moves here: residency, leases and reservations; start and stop order,
/// readiness budgets and launch generations; crash classification, retry and fallback; and,
/// with the runtime, admission, downloads, upgrades, persistence and the checker adapter the
/// launch should carry.
///
/// Each runtime holds exactly one engine, required at construction with no default, so a
/// runtime cannot be built that quietly runs on an engine nobody chose. The pipeline never
/// sees an engine: it receives connectors (`BundledLocalPolisherFactories`) from the app's
/// composition root.
public protocol LocalPolishEngine: Sendable {
  /// Builds the launch configuration of one model on this engine. The runtime calls it once
  /// per launch with its own identity and the admitted values of its delivery.
  var makeLaunchConfiguration: LocalPolishLaunchConfigurationFactory { get }

  /// Builds the health probe for one model on this engine, presenting itself as that model.
  var makeHealthProbe:
    @Sendable (LocalPolishModelID, PromptFamily) -> LocalPolishHealthProbe
  { get }

  #if DEBUG
    /// Reads the engine's slot state for Live UAT evidence. DEBUG builds only: the
    /// requirement, its operation type and every implementation are absent from a release.
    var inspectSlots: LocalPolishSlotInspection { get }
  #endif
}
