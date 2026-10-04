import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #3438. Which setup warnings may show, and what each one remembers. When this is wrong, a
/// person is nagged after choosing "Leave anyway", sees the card again for the same problem,
/// is warned while AI Polish is off, or is never told.
@MainActor
@Suite("AI polish setup warnings: when each one shows (#3438)", .tags(.productOutcome))
struct PolishSetupMonitorTests {

  // MARK: - Fixtures

  private static let openAI = PolishSetupConfiguration(
    provider: .openAI, model: "gpt-test", credentialRevision: 1)
  private static let egOne = PolishSetupConfiguration(
    provider: .egOne, model: "eg-1", credentialRevision: nil)
  private static let ollama = PolishSetupConfiguration(
    provider: .ollama, model: "qwen3:4b", credentialRevision: nil)

  private static func facts(
    egOneInstall: EGOneInstallState = .installed(version: "1.2"),
    openAIKeySaved: Bool? = true,
    ollamaSetup: OllamaSetupState = .ready,
    appleStatus: AIAvailabilityStatus? = .available,
    appleFailureReasons: [AIFailureReason] = []
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: egOneInstall, egOneHealth: .green,
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
      appleStatus: appleStatus, appleFailureReasons: appleFailureReasons, appleIsChecking: false,
      validationProvider: nil, cloudValidation: .idle,
      credentialRevisions: [.openAI: 1], cloudVerdict: nil,
      openAIKeySaved: openAIKeySaved, geminiKeySaved: true, claudeKeySaved: true,
      ollamaSetup: ollamaSetup, ollamaModel: .installed)
  }

  /// The live world the monitor reads, observable so the monitor sees changes on its own.
  /// The configuration and eligibility call the monitor synchronously when they change, as
  /// the settings hook and the saved-key owner do in the app.
  @MainActor @Observable
  final class World {
    var onboardingComplete = true { didSet { onTransition?() } }
    var configuration = PolishSetupMonitorTests.openAI { didSet { onTransition?() } }
    var facts = PolishSetupMonitorTests.facts(openAIKeySaved: false)
    var ollamaLastCommitAt: ContinuousClock.Instant?
    @ObservationIgnored var onTransition: (() -> Void)?

    var inputs: PolishSetupInputs {
      PolishSetupInputs(
        onboardingComplete: onboardingComplete, configuration: configuration, facts: facts,
        ollamaLastCommitAt: ollamaLastCommitAt)
    }
  }

  @MainActor
  private final class RefreshLog {
    var requests = 0
    var cancels = 0
  }

  private static func monitor(_ world: World, refresh: RefreshLog = RefreshLog())
    -> PolishSetupMonitor
  {
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs },
      ollamaRefresh: OllamaOffPageRefresh(
        requestOnce: { refresh.requests += 1 }, cancel: { refresh.cancels += 1 }))
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    return monitor
  }

  // MARK: - The episode rules (pure)

  @Test("a confirmed problem shows every surface; each acknowledgement is its own")
  func surfacesAndAcknowledgements() throws {
    var e = PolishSetupEpisodes()
    e.reconcile(
      readiness: .problem(.cloudKeyMissing(.openAI)), configuration: Self.openAI, eligible: true)
    for surface in PolishSetupSurface.allCases { #expect(e.shows(surface), "\(surface)") }
    let token = try #require(e.episode?.token)

    e.acknowledge(.leaveDialog, in: token)
    #expect(e.shows(.leaveDialog) == false)
    #expect(e.shows(.banner))
    #expect(e.shows(.card))

    e.acknowledge(.banner, in: token)
    #expect(e.shows(.banner) == false)
    #expect(e.shows(.card))

    // The menu line and the sidebar tag have no dismissal.
    e.acknowledge(.menu, in: token)
    e.acknowledge(.sidebarTag, in: token)
    #expect(e.shows(.menu))
    #expect(e.shows(.sidebarTag))
  }

  @Test("the card is spent only by a matching receipt, once")
  func cardTickets() throws {
    var e = PolishSetupEpisodes()
    e.reconcile(
      readiness: .problem(.cloudKeyMissing(.openAI)), configuration: Self.openAI, eligible: true)
    let ticket = try #require(e.cardTicket())
    // Asking again spends nothing.
    #expect(e.cardTicket() == ticket)
    e.cardPresented(ticket)
    #expect(e.shows(.card) == false)
    #expect(e.cardTicket() == nil)
    // A duplicate receipt changes nothing; the banner is untouched by the card.
    e.cardPresented(ticket)
    #expect(e.shows(.banner))
  }

  @Test("polish off or onboarding incomplete hides everything and voids an issued ticket")
  func suppressionVoidsTickets() throws {
    var e = PolishSetupEpisodes()
    let problem = PolishSetupReadiness.problem(.localEngineNotDownloaded(.egOne))
    e.reconcile(readiness: problem, configuration: Self.egOne, eligible: true)
    let ticket = try #require(e.cardTicket())
    let token = try #require(e.episode?.token)
    e.acknowledge(.banner, in: token)

    e.reconcile(readiness: problem, configuration: Self.egOne, eligible: false)
    for surface in PolishSetupSurface.allCases { #expect(e.shows(surface) == false) }

    // Eligible again: the episode and its answers are kept, but the old ticket is void.
    e.reconcile(readiness: problem, configuration: Self.egOne, eligible: true)
    #expect(e.episode?.token == token)
    #expect(e.shows(.banner) == false)
    e.cardPresented(ticket)
    #expect(e.shows(.card), "a ticket issued before suppression spent the card")
  }

  @Test("repair ends the episode; the same problem again starts a fresh one")
  func repairThenRecurrence() throws {
    var e = PolishSetupEpisodes()
    let missing = PolishSetupReadiness.problem(.cloudKeyMissing(.openAI))
    e.reconcile(readiness: missing, configuration: Self.openAI, eligible: true)
    let first = try #require(e.episode?.token)
    e.acknowledge(.banner, in: first)

    e.reconcile(readiness: .noProblem, configuration: Self.openAI, eligible: true)
    #expect(e.episode == nil)
    #expect(e.shows(.menu) == false)

    e.reconcile(readiness: missing, configuration: Self.openAI, eligible: true)
    #expect(e.episode?.token != first)
    #expect(e.shows(.banner), "an answer from the repaired episode carried over")
  }

  @Test("unknown or checking pauses the warnings and keeps what was answered")
  func unknownKeepsMemory() throws {
    var e = PolishSetupEpisodes()
    let missing = PolishSetupReadiness.problem(.cloudKeyMissing(.openAI))
    e.reconcile(readiness: missing, configuration: Self.openAI, eligible: true)
    let token = try #require(e.episode?.token)
    e.acknowledge(.banner, in: token)

    for pause in [PolishSetupReadiness.unknown, .checking] {
      e.reconcile(readiness: pause, configuration: Self.openAI, eligible: true)
      #expect(e.shows(.menu) == false)
      #expect(e.episode?.token == token)
    }
    e.reconcile(readiness: missing, configuration: Self.openAI, eligible: true)
    #expect(e.episode?.token == token)
    #expect(e.shows(.banner) == false)
    #expect(e.shows(.menu))
  }

  @Test("a new provider, model or saved key starts over; the problem moving does not")
  func configurationChanges() throws {
    var e = PolishSetupEpisodes()
    let missing = PolishSetupReadiness.problem(.cloudKeyMissing(.openAI))
    e.reconcile(readiness: missing, configuration: Self.openAI, eligible: true)
    let token = try #require(e.episode?.token)
    e.acknowledge(.leaveDialog, in: token)

    let newModel = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-other", credentialRevision: 1)
    e.reconcile(readiness: missing, configuration: newModel, eligible: true)
    #expect(e.episode?.token != token)
    #expect(e.shows(.leaveDialog))

    let afterModel = try #require(e.episode?.token)
    let newKey = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-other", credentialRevision: 2)
    e.reconcile(readiness: missing, configuration: newKey, eligible: true)
    #expect(e.episode?.token != afterModel)

    // EG-1 not downloaded, then downloading, then paused: one unfinished setup.
    var local = PolishSetupEpisodes()
    local.reconcile(
      readiness: .problem(.localEngineNotDownloaded(.egOne)), configuration: Self.egOne,
      eligible: true)
    let localToken = try #require(local.episode?.token)
    local.acknowledge(.leaveDialog, in: localToken)
    local.reconcile(
      readiness: .problem(.localEngineDownloading(.egOne)), configuration: Self.egOne,
      eligible: true)
    local.reconcile(
      readiness: .problem(.localEngineDownloadPaused(.egOne)), configuration: Self.egOne,
      eligible: true)
    #expect(local.episode?.token == localToken)
    #expect(local.shows(.leaveDialog) == false)
    #expect(local.episode?.problem == .localEngineDownloadPaused(.egOne))
  }

  @Test("an informational problem gets the leave notice only")
  func informationalSurfaces() {
    var e = PolishSetupEpisodes()
    e.reconcile(
      readiness: .problem(.localEngineDownloading(.egOne)), configuration: Self.egOne,
      eligible: true)
    #expect(e.shows(.leaveDialog))
    for surface in [PolishSetupSurface.card, .banner, .menu, .sidebarTag] {
      #expect(e.shows(surface) == false, "\(surface)")
    }
  }

  // MARK: - The live monitor

  @Test("the monitor follows the live owners without Settings open")
  func followsLiveOwners() async {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == .cloudKeyMissing(.openAI))

    world.facts = Self.facts(openAIKeySaved: true)
    #expect(await waitUntil { monitor.eligibleProblem == nil }, "repair did not reach the monitor")

    world.facts = Self.facts(openAIKeySaved: nil)
    world.onboardingComplete = false
    world.facts = Self.facts(openAIKeySaved: false)
    #expect(await waitUntil { monitor.episodes.episode != nil })
    #expect(monitor.eligibleProblem == nil, "a warning showed before onboarding finished")

    world.onboardingComplete = true
    #expect(await waitUntil { monitor.eligibleProblem == .cloudKeyMissing(.openAI) })

    // Polish off.
    world.configuration = PolishSetupConfiguration(
      provider: .none, model: "", credentialRevision: nil)
    #expect(await waitUntil { monitor.eligibleProblem == nil })
  }

  @Test("the context for a starting take is read live, never from a lagging copy")
  func contextIsLive() {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    world.configuration = Self.egOne
    world.facts = Self.facts(egOneInstall: .notInstalled)
    // No wait: the context must already describe the new configuration.
    let context = monitor.currentContext()
    #expect(context.configuration == Self.egOne)
    #expect(context.episode != nil)
  }

  @Test("whichever of a take and the Ollama service observed last is believed")
  func ollamaOrdering() {
    let t0 = ContinuousClock.now
    let world = World()
    world.configuration = Self.ollama
    world.facts = Self.facts(ollamaSetup: .ready)
    world.ollamaLastCommitAt = t0
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == nil)
    let take = monitor.currentContext()

    // A take observed Ollama not running after the service's last commit: believed.
    monitor.recordOllamaTakeObservation(
      .ollamaNotRunning, context: take, observedAt: t0 + .milliseconds(10))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)

    // The service commits later still: the service is believed.
    world.ollamaLastCommitAt = t0 + .milliseconds(20)
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == nil)

    // A take that observed BEFORE that commit but reports late does not overrule it.
    monitor.recordOllamaTakeObservation(
      .ollamaNotRunning, context: take, observedAt: t0 + .milliseconds(15))
    #expect(monitor.eligibleProblem == nil)

    // A probe committed after a take STARTED but before it observed the failure: the take's
    // observation is the newer one.
    monitor.recordOllamaTakeObservation(
      .ollamaModelNotInstalled, context: take, observedAt: t0 + .milliseconds(30))
    #expect(monitor.eligibleProblem == .ollamaModelNotInstalled)

    // Two takes: the older one, delivered last, does not replace the newer one.
    monitor.recordOllamaTakeObservation(
      .ollamaNotRunning, context: take, observedAt: t0 + .milliseconds(25))
    #expect(monitor.eligibleProblem == .ollamaModelNotInstalled)
  }

  @Test("a take from A says nothing after A, then B, then A, with no read in between")
  func ollamaStaleConfigurations() {
    let world = World()
    world.configuration = Self.ollama
    world.facts = Self.facts(ollamaSetup: .ready)
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let firstA = monitor.currentContext()

    // Both changes land before any observer runs; the settings hook still sees each one.
    world.configuration = PolishSetupConfiguration(
      provider: .ollama, model: "llama3", credentialRevision: nil)
    world.configuration = Self.ollama
    monitor.recordOllamaTakeObservation(
      .ollamaNotRunning, context: firstA, observedAt: .now)
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("an answer about an episode that already ended changes nothing")
  func staleAcknowledgement() throws {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let old = try #require(monitor.currentEpisode)
    // Repaired, then broken again: a new episode.
    world.facts = Self.facts(openAIKeySaved: true)
    _ = monitor.currentContext()
    world.facts = Self.facts(openAIKeySaved: false)
    _ = monitor.currentContext()
    #expect(monitor.currentEpisode != old)
    // The banner answered for the old episode is not taken as an answer for the new one.
    monitor.acknowledge(.banner, in: old)
    #expect(monitor.shows(.banner))
  }

  @Test("a card receipt after onboarding was reset and finished again spends nothing")
  func receiptAfterSuppression() throws {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let ticket = try #require(monitor.cardTicket())
    // Off and back on with no yield and no read in between.
    world.onboardingComplete = false
    world.onboardingComplete = true
    monitor.cardPresented(ticket)
    #expect(monitor.cardTicket() != nil, "a ticket from before the reset spent the card")
  }

  @Test("Apple Intelligence unavailable warns in Settings but never gets a dictation card")
  func appleNeverGetsACard() {
    let world = World()
    world.configuration = PolishSetupConfiguration(
      provider: .appleIntelligence, model: "apple", credentialRevision: nil)
    world.facts = Self.facts(appleStatus: .unavailable, appleFailureReasons: [.unsupportedOS])
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == .appleUnavailable(.unsupportedOS))
    for surface in [PolishSetupSurface.leaveDialog, .banner, .menu, .sidebarTag] {
      #expect(monitor.shows(surface), "\(surface)")
    }
    #expect(monitor.cardTicket() == nil)
  }

  @Test("activation asks for one off-page Ollama refresh only when it can matter")
  func activationRefresh() {
    let world = World()
    let refresh = RefreshLog()
    let monitor = Self.monitor(world, refresh: refresh)

    // Not started yet.
    world.configuration = Self.ollama
    monitor.applicationDidBecomeActive()
    #expect(refresh.requests == 0)

    monitor.start()
    monitor.applicationDidBecomeActive()
    #expect(refresh.requests == 1)

    // Not Ollama, or onboarding not finished: nothing.
    world.configuration = Self.openAI
    monitor.applicationDidBecomeActive()
    world.configuration = Self.ollama
    world.onboardingComplete = false
    monitor.applicationDidBecomeActive()
    #expect(refresh.requests == 1)
    monitor.stop()
  }

  @Test("a pending refresh is cancelled by a configuration change, onboarding reset, or stop")
  func refreshCancellation() {
    let world = World()
    world.configuration = Self.ollama
    let refresh = RefreshLog()
    let monitor = Self.monitor(world, refresh: refresh)
    monitor.start()
    let atStart = refresh.cancels

    world.configuration = PolishSetupConfiguration(
      provider: .ollama, model: "llama3", credentialRevision: nil)
    #expect(refresh.cancels == atStart + 1)

    world.onboardingComplete = false
    #expect(refresh.cancels == atStart + 2)

    monitor.stop()
    #expect(refresh.cancels == atStart + 3)
  }

  @Test("after stop, changes no longer move the monitor")
  func stopEndsObservation() async {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    #expect(monitor.eligibleProblem == .cloudKeyMissing(.openAI))
    monitor.stop()
    world.facts = Self.facts(openAIKeySaved: true)
    // Give a queued callback every chance to run; it must not revive observation.
    for _ in 0..<50 { await Task.yield() }
    #expect(monitor.eligibleProblem == .cloudKeyMissing(.openAI))
  }
}
