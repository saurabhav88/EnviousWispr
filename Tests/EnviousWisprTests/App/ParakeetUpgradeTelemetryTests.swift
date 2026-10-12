import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices

/// #3546 §3.7 T2: `parakeet_upgrade.activation` rows. When this fails, the Ultra rollout
/// reader counts an install's activation twice, misses a first activation, reports a
/// fallback the app did not take, or a row appears after usage metrics were off.
@MainActor
@Suite("Parakeet upgrade telemetry (#3546)", .tags(.observabilityContract))
struct ParakeetUpgradeTelemetryTests {
  static let ultra = ModelIdentity(
    family: .parakeet, name: "parakeet-ultra-coreml",
    revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", variant: "int8",
    runtimeABI: "fluidAudio-test")

  final class Rig {
    let defaults: UserDefaults
    var capturing = true
    var appVersion = "2.6.0"
    var rows: [ParakeetUpgradeTelemetry.Row] = []
    var sentry: [(String, String)] = []

    init() {
      let suite = "ParakeetUpgradeTelemetryTests.\(UUID().uuidString)"
      defaults = TestDefaults.suite(suite)!
    }

    @MainActor
    func telemetry() -> ParakeetUpgradeTelemetry {
      ParakeetUpgradeTelemetry(
        target: ParakeetUpgradeTelemetryTests.ultra, defaults: defaults, appVersion: appVersion,
        isCaptureRunning: { [unowned self] in self.capturing },
        send: { [unowned self] in self.rows.append($0) },
        reportUltraLoadFailure: { [unowned self] in self.sentry.append(($0, $1)) })
    }
  }

  static func facts(
    _ model: ParakeetModel, prior: ParakeetModel? = nil, attempts: Int? = 1, ms: Int? = 840
  ) -> ParakeetUpgradeCoordinator.LoadFacts {
    ParakeetUpgradeCoordinator.LoadFacts(
      selection: ParakeetModelSelection(
        model: model, revision: "95eaa59a", directory: URL(fileURLWithPath: "/tmp/x"),
        cacheOnly: true, displayBytes: 1, repairable: false, generation: 1),
      priorModel: prior, attempts: attempts, loadMilliseconds: ms)
  }

  @Test("an activation sends one row with its facts, and only the first is a first activation")
  func activationIsSentOnceWithItsFacts() {
    let rig = Rig()
    let telemetry = rig.telemetry()
    telemetry.observe(.activated(Self.facts(.ultra, prior: .v3, attempts: 2, ms: 1234)))
    telemetry.observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.count == 1, "a reload of the same target is not a new activation")
    let row = try? #require(rig.rows.first)
    #expect(row?.outcome == "activated")
    #expect(row?.targetModel == "parakeet-ultra-coreml")
    #expect(row?.targetRevision == "95eaa59a")
    #expect(row?.priorModel == "parakeet-tdt-0.6b-v3-coreml")
    #expect(row?.attempts == 2)
    #expect(row?.loadMs == 1234)
    #expect(row?.firstActivation == true)
    #expect(row?.fallback == nil)
    // A relaunch reads the same ledger: still one row.
    rig.telemetry().observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.count == 1)
  }

  @Test("an Ultra load failure always reaches Sentry, and its usage row is sent once")
  func loadFailureReachesSentryEveryTime() {
    let rig = Rig()
    let telemetry = rig.telemetry()
    let failure = ParakeetUpgradeCoordinator.Outcome.loadFailed(
      .ultra, Self.facts(.ultra), error: "VendorError#3", fallback: .v3)
    telemetry.observe(failure)
    telemetry.observe(failure)
    #expect(rig.sentry.count == 2)
    #expect(rig.sentry.first?.0 == "VendorError#3")
    #expect(rig.sentry.first?.1 == "v3")
    #expect(rig.rows.map(\.outcome) == ["load_failed"])
    #expect(rig.rows.first?.fallback == "v3")
    #expect(rig.rows.first?.firstActivation == nil)
    // A v3 load failure is not an upgrade event.
    telemetry.observe(.loadFailed(.v3, Self.facts(.v3), error: "E#1", fallback: .none))
    #expect(rig.sentry.count == 2)
    #expect(rig.rows.count == 1)
  }

  @Test("a prior model outside the vocabulary is omitted, never reported as none")
  func ultraPriorIsOmitted() {
    let rig = Rig()
    let telemetry = rig.telemetry()
    telemetry.observe(
      .loadFailed(.ultra, Self.facts(.ultra, prior: .ultra), error: "E#1", fallback: .none))
    telemetry.observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.map(\.outcome) == ["load_failed", "activated"])
    #expect(rig.rows.first?.priorModel == nil)
    #expect(rig.rows.last?.priorModel == "none", "nothing was serving")
  }

  @Test("deferred disk and cleanup failures repeat once per app version")
  func versionScopedOutcomesRepeatPerVersion() {
    let rig = Rig()
    rig.telemetry().observe(.deferredDisk)
    rig.telemetry().observe(.deferredDisk)
    rig.telemetry().observe(.retirementFailed(.v3))
    rig.appVersion = "2.6.1"
    rig.telemetry().observe(.deferredDisk)
    rig.telemetry().observe(.retirementFailed(.ultra))
    #expect(
      rig.rows.map(\.outcome) == [
        "deferred_disk", "cleanup_failed", "deferred_disk", "cleanup_failed",
      ])
    #expect(
      rig.rows.allSatisfy { $0.priorModel == nil && $0.attempts == nil && $0.loadMs == nil },
      "non-load rows carry no prior identity rather than a guessed none")
  }

  @Test("each closed outcome maps to its row name, and internal steps send nothing")
  func outcomeVocabularyIsClosed() {
    let rig = Rig()
    let telemetry = rig.telemetry()
    for outcome: ParakeetUpgradeCoordinator.Outcome in [
      .declined, .resumed, .refetchStarted, .exhausted,
      .selected(.ultra, row: "A"), .fellBackToV3, .retiredV3, .removedTarget,
      .storeUnavailable("reset"), .retryGranted, .backgroundStarted, .backgroundAdmitted,
      .backgroundFetchFailed("network"),
    ] {
      telemetry.observe(outcome)
    }
    #expect(rig.rows.map(\.outcome) == ["declined", "resumed", "refetch", "exhausted"])
  }

  /// The transition is noted on this Mac whether or not metrics are on, and sent only while
  /// they are. When this fails, an activation seen with metrics off is replayed later, or an
  /// ordinary reload after metrics are turned on is sent as a first activation.
  @Test("an activation seen with metrics off is never sent later, by a reload or a relaunch")
  func metricsOffActivationIsNeverReplayed() {
    let rig = Rig()
    rig.capturing = false
    let telemetry = rig.telemetry()
    telemetry.observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.isEmpty, "nothing leaves the Mac with metrics off")
    rig.capturing = true
    telemetry.observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.isEmpty, "an ordinary reload is not an activation")
    rig.telemetry().observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.isEmpty, "nor is the reload after a relaunch")
    // A different outcome first seen with metrics on is still sent.
    rig.telemetry().observe(.declined)
    #expect(rig.rows.map(\.outcome) == ["declined"])
  }

  @Test("first activation is false once any Ultra target has activated on this install")
  func firstActivationSpansTargets() {
    let rig = Rig()
    rig.defaults.set(
      ["parakeet-parakeet-ultra-coreml-older-int8|activated"],
      forKey: ParakeetUpgradeTelemetry.ledgerKey)
    rig.telemetry().observe(.activated(Self.facts(.ultra)))
    #expect(rig.rows.first?.firstActivation == false)
  }
}

#if DEBUG
  /// #3546 §3.7 T2: the real emitter and the real Sentry event builder, past the injected
  /// seams above. When this fails, the vendor row is missing a property, carries one it
  /// should omit, converts milliseconds wrongly, or the Ultra load failure groups wrong.
  @MainActor
  @Suite("Parakeet upgrade telemetry, real sinks (#3546)", .serialized, .tags(.observabilityContract))
  struct ParakeetUpgradeTelemetrySinkTests {
    @MainActor final class Box { var events: [CapturedTelemetryEvent] = [] }

    func captured(_ body: () -> Void) -> [CapturedTelemetryEvent] {
      let box = Box()
      let previous = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated {
          if event.name == "parakeet_upgrade.activation" { box.events.append(event) }
        }
      }
      defer { TelemetryService.shared.testEventHook = previous }
      body()
      return box.events
    }

    @Test("an activation row carries its properties, with load seconds as the value")
    func activationRowShape() throws {
      let events = captured {
        TelemetryService.shared.parakeetUpgradeActivation(
          targetModel: "parakeet-ultra-coreml", targetRevision: "95eaa59a",
          priorModel: "parakeet-tdt-0.6b-v3-coreml", outcome: "activated", fallback: nil,
          attempts: 2, loadMs: 1250, firstActivation: true)
      }
      let event = try #require(events.first)
      #expect(events.count == 1)
      #expect(
        event.stringProps == [
          "target_model": "parakeet-ultra-coreml", "target_revision": "95eaa59a",
          "prior_model": "parakeet-tdt-0.6b-v3-coreml", "outcome": "activated",
        ])
      #expect(event.intProps == ["attempts": 2, "load_ms": 1250])
      #expect(event.doubleProps == ["$value": 1.25])
      #expect(event.boolProps == ["first_activation": true])
    }

    @Test("a non-load row omits prior model, attempts, load time, value and fallback")
    func nonLoadRowShape() throws {
      let events = captured {
        TelemetryService.shared.parakeetUpgradeActivation(
          targetModel: "parakeet-ultra-coreml", targetRevision: "95eaa59a", priorModel: nil,
          outcome: "declined", fallback: nil, attempts: nil, loadMs: nil, firstActivation: nil)
      }
      let event = try #require(events.first)
      #expect(
        event.stringProps == [
          "target_model": "parakeet-ultra-coreml", "target_revision": "95eaa59a",
          "outcome": "declined",
        ])
      #expect(event.intProps.isEmpty)
      #expect(event.doubleProps.isEmpty)
      #expect(event.boolProps.isEmpty)
    }

    @Test("an Ultra load failure groups by its category and the loader's own error")
    func ultraLoadFailureSentryShape() {
      let event = SentryBreadcrumb.makeHandledErrorEvent(
        UltraLoadFailedError(loaderDescriptor: "com.apple.CoreML#0"),
        category: .parakeetUltraLoadFailed, stage: "model_load", extra: ["fallback": "v3"],
        environment: "production")
      #expect(
        event.fingerprint
          == ["handled_error", "parakeet_ultra_load_failed", "com.apple.CoreML#0", "production"])
      #expect(event.message?.formatted == "parakeet_ultra_load_failed: com.apple.CoreML#0")
      #expect(event.tags?["error.identity"] == "parakeet_ultra_load_failed")
      #expect(event.extra?["fallback"] as? String == "v3")
    }
  }
#endif
