import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3897. The stored Apple Intelligence report is what the onboarding card, the History banner,
/// the menu line, the sidebar tag and the leave dialog read. When this is wrong, they keep
/// saying "turned off" after the user turned it on, until a relaunch; or the app re-runs the
/// full check (and sends a telemetry row) on every activation and every dictation.
@MainActor
@Suite(
  "Apple Intelligence report repairs itself after the user fixes it (#3897)", .tags(.productOutcome)
)
struct AIAvailabilityRecheckPolicyTests {

  // MARK: - Fixtures

  private static func report(
    _ status: AIAvailabilityStatus, _ reasons: [AIFailureReason] = []
  ) -> AppleIntelligenceAvailabilityReport {
    let gate = AIGateResult.passed(summary: "synthetic")
    return AppleIntelligenceAvailabilityReport(
      overallStatus: status,
      gates: AIGateSet(
        build: gate, runtime: gate, eligibility: gate, modelAccess: gate, functionalProbe: gate),
      failureReasons: reasons, osVersion: "synthetic", hardwareClass: "arm64")
  }

  private static let disabled = report(.unavailable, [.appleIntelligenceDisabled])
  private static let downloading = report(.unavailable, [.modelNotReady])
  private static let available = report(.available)

  /// What the coordinator reads and runs, scripted: the live answer, the reports the full
  /// check returns in order, and a count of how many full checks started.
  @MainActor
  final class Script {
    var eligible = true
    var live: AppleIntelligenceLiveAvailability = .available
    var liveReads = 0
    var reports: [AppleIntelligenceAvailabilityReport] = []
    var starts = 0
    var triggers: [String] = []
    /// Held open until released, to keep a full check in flight.
    var gate: CheckedContinuation<Void, Never>?
    var holdChecks = false
    /// Held open until released, to keep a live read in flight.
    var readGate: CheckedContinuation<Void, Never>?
    var holdReads = false

    /// Held open until released, to keep a debounced check waiting.
    var debounceGate: CheckedContinuation<Void, Never>?
    var holdDebounce = false

    func debounceWaitPoint() async {
      if holdDebounce { await withCheckedContinuation { debounceGate = $0 } }
    }

    func releaseDebounce() {
      debounceGate?.resume()
      debounceGate = nil
    }

    func liveValue() async -> AppleIntelligenceLiveAvailability {
      liveReads += 1
      if holdReads { await withCheckedContinuation { readGate = $0 } }
      return live
    }

    func nextReport() async -> AppleIntelligenceAvailabilityReport {
      starts += 1
      if holdChecks { await withCheckedContinuation { gate = $0 } }
      return reports.isEmpty ? AIAvailabilityRecheckPolicyTests.disabled : reports.removeFirst()
    }
  }

  /// A coordinator on its own defaults domain, whose stored report starts as `seed` the way a
  /// relaunch restores the previous session's report.
  private static func coordinator(
    _ script: Script, seed: AppleIntelligenceAvailabilityReport?
  ) throws -> AIAvailabilityCoordinator {
    let suite = "AIAvailabilityRecheckPolicyTests.\(UUID().uuidString)"
    let defaults = try #require(TestDefaults.suite(suite))
    defaults.removePersistentDomain(forName: suite)
    if let seed {
      defaults.set(try JSONEncoder().encode(seed), forKey: "aiDiagnosticsLatestReport")
    }
    return AIAvailabilityCoordinator(
      repairDependencies: AppleAvailabilityRepairDependencies(
        isRepairEligible: { script.eligible },
        readLiveAvailability: { await script.liveValue() },
        runDiagnostics: { await script.nextReport() },
        reportCompleted: { _, trigger in script.triggers.append(trigger) },
        debounceWait: { await script.debounceWaitPoint() }),
      defaults: defaults)
  }

  /// Lets the activation read and any debounced check it admitted run to completion.
  private static func settle(_ c: AIAvailabilityCoordinator) async {
    for _ in 0..<4 {
      await c.liveReadTask?.value
      await c.debounceTask?.value
      await Task.yield()
    }
  }

  // MARK: - The policy (pure)

  @Test(
    "activation re-checks only a switched-off or downloading report the live answer contradicts")
  func activationPolicy() {
    typealias R = AppleAvailabilityRepair
    #expect(R.activationWantsCheck(report: Self.disabled, live: .available))
    #expect(R.activationWantsCheck(report: Self.disabled, live: .modelNotReady))
    #expect(R.activationWantsCheck(report: Self.downloading, live: .available))
    #expect(R.activationWantsCheck(report: Self.downloading, live: .disabled))
    #expect(R.activationWantsCheck(report: Self.disabled, live: .disabled) == false)
    #expect(R.activationWantsCheck(report: Self.downloading, live: .modelNotReady) == false)
    for live: AppleIntelligenceLiveAvailability in [.notEligible, .unsupported, .unknown] {
      #expect(R.activationWantsCheck(report: Self.disabled, live: live) == false, "\(live)")
    }
    // Reports activation cannot test: available, below macOS 26, not eligible, timed out.
    for report in [
      Self.available, Self.report(.unavailable, [.unsupportedOS]),
      Self.report(.unavailable, [.deviceNotEligible]), Self.report(.degraded),
    ] {
      #expect(R.activationWantsCheck(report: report, live: .available) == false)
    }
  }

  @Test("a polished take re-checks any report that is not available; the budget is two")
  func takeAndBudgetPolicy() {
    typealias R = AppleAvailabilityRepair
    #expect(R.polishedTakeWantsCheck(report: Self.report(.degraded)))
    #expect(R.polishedTakeWantsCheck(report: Self.disabled))
    #expect(R.polishedTakeWantsCheck(report: Self.available) == false)
    #expect(R.budgetAdmits(startsThisEpoch: 0))
    #expect(R.budgetAdmits(startsThisEpoch: 1))
    #expect(R.budgetAdmits(startsThisEpoch: 2) == false)
    #expect(R.isTransition(from: nil, to: .available) == false, "the first answer is a baseline")
    #expect(R.isTransition(from: .disabled, to: .disabled) == false)
    #expect(R.isTransition(from: .disabled, to: .modelNotReady))
  }

  // MARK: - The coordinator

  @Test("turned on in System Settings: one activation repairs the report")
  func activationRepairs() async throws {
    let script = Script()
    script.reports = [Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.starts == 1)
    #expect(script.triggers == ["app_active"])
    #expect(c.latestReport?.overallStatus == .available)
    #expect(c.automaticStartsThisEpoch == 0, "an available report ends the epoch")
  }

  @Test("nothing changed: no check and no telemetry row")
  func unchangedLiveAnswerDoesNothing() async throws {
    let script = Script()
    script.live = .disabled
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    await Self.settle(c)
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.liveReads == 2)
    #expect(script.starts == 0)
    #expect(script.triggers.isEmpty)
  }

  @Test("no report or an available report: no live read")
  func nothingToRepairReadsNothing() async throws {
    for seed in [nil, Self.available] {
      let script = Script()
      let c = try Self.coordinator(script, seed: seed)
      c.applicationDidBecomeActive()
      await Self.settle(c)
      #expect(script.liveReads == 0, "\(String(describing: seed?.overallStatus))")
      #expect(script.starts == 0)
    }
  }

  @Test("another provider after onboarding: no read and no check")
  func ineligibleDoesNothing() async throws {
    let script = Script()
    script.eligible = false
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.liveReads == 0)
    #expect(script.starts == 0)
  }

  @Test("switching away during the live read drops the repair")
  func eligibilityRevalidatedAfterRead() async throws {
    let script = Script()
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    script.eligible = false
    await Self.settle(c)
    #expect(script.liveReads == 1)
    #expect(script.starts == 0)
  }

  @Test("activations during one live read share it")
  func activationsCoalesce() async throws {
    let script = Script()
    script.reports = [Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    c.applicationDidBecomeActive()
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.liveReads == 1)
    #expect(script.starts == 1)
  }

  @Test("still failing: two automatic checks per epoch across both triggers, then none")
  func budgetHoldsAcrossReportReplacement() async throws {
    let script = Script()
    script.reports = [Self.disabled, Self.disabled, Self.disabled]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()  // live available, report disabled: check 1
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()  // new disabled report, still not available: check 2
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()  // a new report never renews the budget
    await Self.settle(c)
    c.applicationDidBecomeActive()  // same live answer: no transition, no reset
    await Self.settle(c)
    #expect(script.starts == 2)
    #expect(script.triggers == ["app_active", "polished_take"])
    // The re-check button always runs.
    c.debouncedCheck()
    await Self.settle(c)
    #expect(script.starts == 3)
    #expect(script.triggers.last == "manual_refresh")
  }

  @Test("switched off to downloading is a change: it re-checks and starts a new epoch")
  func typedTransitionResetsTheBudget() async throws {
    let script = Script()
    script.reports = [Self.disabled, Self.disabled, Self.downloading, Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.starts == 2)
    #expect(c.automaticStartsThisEpoch == 2)
    // The model started downloading: the live answer moved, so the epoch starts over.
    script.live = .modelNotReady
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.starts == 3)
    #expect(c.latestReport?.failureReasons == [.modelNotReady])
    #expect(c.automaticStartsThisEpoch == 1)
    // Download finished.
    script.live = .available
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.starts == 4)
    #expect(c.latestReport?.overallStatus == .available)
  }

  @Test("a polished take repairs a timed-out report; an available report is left alone")
  func polishedTakeRepairs() async throws {
    let script = Script()
    script.reports = [Self.available]
    let c = try Self.coordinator(script, seed: Self.report(.degraded))
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.starts == 1)
    #expect(script.triggers == ["polished_take"])
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.starts == 1)
  }

  @Test("a check that lands first makes the waiting repair stale")
  func newerReportDiscardsStaleRepair() async throws {
    let script = Script()
    script.holdChecks = true
    script.reports = [Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    // A check is already running (the launch check) when the dictation polishes.
    let launch = Task { await c.checkAvailability(trigger: "app_launch") }
    while script.gate == nil { await Task.yield() }
    c.appleIntelligencePolishSucceeded()
    await c.debounceTask?.value
    #expect(script.starts == 1, "a repair never starts while a check runs")
    script.gate?.resume()
    await launch.value
    await Self.settle(c)
    #expect(script.starts == 1)
    #expect(c.latestReport?.overallStatus == .available)
  }

  @Test("an automatic repair never replaces a pending re-check")
  func repairNeverCancelsManual() async throws {
    let script = Script()
    script.reports = [Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.debouncedCheck()
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.triggers == ["manual_refresh"])
  }

  // MARK: - Work that went stale before it started (#3897 review)

  @Test("eligible only for Apple Intelligence, or while onboarding is open")
  func eligibility() {
    typealias R = AppleAvailabilityRepair
    #expect(R.isEligible(provider: .appleIntelligence, onboardingComplete: true))
    #expect(R.isEligible(provider: .appleIntelligence, onboardingComplete: false))
    #expect(R.isEligible(provider: .openAI, onboardingComplete: false))
    #expect(R.isEligible(provider: .openAI, onboardingComplete: true) == false)
    #expect(R.isEligible(provider: .none, onboardingComplete: true) == false)
  }

  @Test("a live answer read while another check ran moves nothing and renews nothing")
  func staleLiveSampleIsDropped() async throws {
    let script = Script()
    script.reports = [Self.disabled, Self.disabled, Self.disabled]
    let c = try Self.coordinator(script, seed: Self.disabled)
    // Spend the epoch: two automatic checks that still say switched off.
    c.applicationDidBecomeActive()
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(c.automaticStartsThisEpoch == 2)
    // A changed live answer is being read when a provider-switch check lands a new report.
    script.live = .modelNotReady
    script.holdReads = true
    c.applicationDidBecomeActive()
    while script.readGate == nil { await Task.yield() }
    await c.checkAvailability(trigger: "provider_switch")
    script.readGate?.resume()
    await Self.settle(c)
    #expect(script.starts == 3, "only the provider-switch check ran")
    #expect(script.triggers == ["app_active", "polished_take", "provider_switch"])
    #expect(c.automaticStartsThisEpoch == 2, "a stale answer never renews the budget")
  }

  /// Holds the debounce until `script.releaseDebounce()`, so a test acts inside the wait.
  private static func waitForHeldDebounce(_ script: Script) async {
    while script.debounceGate == nil { await Task.yield() }
  }

  @Test("a check that starts during the wait drops the waiting repair")
  func checkStartedDuringDebounce() async throws {
    let script = Script()
    script.reports = [Self.disabled]
    script.holdDebounce = true
    let c = try Self.coordinator(script, seed: Self.report(.degraded))
    c.appleIntelligencePolishSucceeded()
    await Self.waitForHeldDebounce(script)
    await c.checkAvailability(trigger: "provider_switch")
    script.releaseDebounce()
    await Self.settle(c)
    #expect(script.starts == 1)
    #expect(script.triggers == ["provider_switch"])
    #expect(c.automaticStartsThisEpoch == 0, "a dropped repair spends nothing")
  }

  @Test("a newer live answer that agrees with the report cancels the waiting repair")
  func newerAgreeingSampleCancels() async throws {
    let script = Script()
    script.holdDebounce = true
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()  // live available: a repair waits
    await Self.waitForHeldDebounce(script)
    script.live = .disabled  // switched back off before it started
    c.applicationDidBecomeActive()
    await c.liveReadTask?.value
    script.releaseDebounce()
    await Self.settle(c)
    #expect(script.liveReads == 2)
    #expect(script.starts == 0)
    #expect(c.automaticStartsThisEpoch == 0)
  }

  @Test("a report stuck degraded after the budget recovers after Apple Intelligence goes off and on")
  func exhaustedBudgetRecoversOnLiveChange() async throws {
    let script = Script()
    // Two repairs time out (degraded), then the third check, after the off/on, passes.
    script.reports = [Self.report(.degraded), Self.report(.degraded), Self.available]
    let c = try Self.coordinator(script, seed: Self.disabled)
    c.applicationDidBecomeActive()  // live available vs disabled: repair 1, degraded
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()  // repair 2, degraded
    await Self.settle(c)
    c.appleIntelligencePolishSucceeded()  // budget spent
    await Self.settle(c)
    #expect(script.starts == 2)
    // Activation still reads while degraded, but never starts a check for it.
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.liveReads == 2)
    #expect(script.starts == 2)
    // Turned off, then on again in System Settings: each changed answer starts a new epoch.
    script.live = .disabled
    c.applicationDidBecomeActive()
    await Self.settle(c)
    script.live = .available
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(c.automaticStartsThisEpoch == 0)
    c.appleIntelligencePolishSucceeded()
    await Self.settle(c)
    #expect(script.starts == 3)
    #expect(c.latestReport?.overallStatus == .available)
  }

  @Test("below macOS 26: activation reads, never checks")
  func unsupportedReadsButNeverChecks() async throws {
    let script = Script()
    script.live = .unsupported
    let c = try Self.coordinator(script, seed: Self.report(.unavailable, [.unsupportedOS]))
    c.applicationDidBecomeActive()
    await Self.settle(c)
    #expect(script.liveReads == 1)
    #expect(script.starts == 0)
  }

  @Test("losing eligibility during the wait drops the repair")
  func eligibilityLostBeforeStart() async throws {
    let script = Script()
    script.holdDebounce = true
    let c = try Self.coordinator(script, seed: Self.report(.degraded))
    c.appleIntelligencePolishSucceeded()
    await Self.waitForHeldDebounce(script)
    script.eligible = false  // switched to another provider after onboarding
    script.releaseDebounce()
    await Self.settle(c)
    #expect(script.starts == 0)
    #expect(c.automaticStartsThisEpoch == 0)
  }
}
