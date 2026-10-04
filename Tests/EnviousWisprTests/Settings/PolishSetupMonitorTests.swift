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
    appleFailureReasons: [AIFailureReason] = [],
    openAIRevision: UInt64 = 1
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: egOneInstall, egOneHealth: .green,
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
      appleStatus: appleStatus, appleFailureReasons: appleFailureReasons, appleIsChecking: false,
      validationProvider: nil, cloudValidation: .idle,
      credentialRevisions: [.openAI: openAIRevision], cloudVerdicts: [:],
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

// MARK: - A take's polish outcome (#3438 chunk 4)

extension PolishSetupMonitorTests {

  @MainActor
  private final class KeyLog {
    var reads: [(LLMProvider, SavedKeyState)] = []
  }

  private static func takeMonitor(_ world: World, keys: KeyLog) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs },
      recordKeyEvidence: { provider, state, _ in keys.reads.append((provider, state)) })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    return monitor
  }

  private static func outcome(
    _ take: PolishSetupTakeContext, id: String = "take-1",
    evidence: PolishSetupEvidence?, tag: PolishSetupProblemTag? = nil,
    at observedAt: ContinuousClock.Instant = .now
  ) -> PolishTakeOutcome {
    PolishTakeOutcome(
      takeID: id, context: take, result: .skippedWithNotice, evidence: evidence,
      setupProblem: tag, observedAt: observedAt)
  }

  private static func withVerdict(
    _ facts: PolishSetupFacts, _ verdict: PolishCloudVerdict?
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: facts.egOneInstall, egOneHealth: facts.egOneHealth,
      s1MiniInstall: facts.s1MiniInstall, s1MiniHealth: facts.s1MiniHealth,
      appleStatus: facts.appleStatus, appleFailureReasons: facts.appleFailureReasons,
      appleIsChecking: facts.appleIsChecking, validationProvider: facts.validationProvider,
      cloudValidation: facts.cloudValidation, credentialRevisions: facts.credentialRevisions,
      cloudVerdicts: verdict.map { [$0.provider: $0] } ?? [:],
      openAIKeySaved: facts.openAIKeySaved,
      geminiKeySaved: facts.geminiKeySaved, claudeKeySaved: facts.claudeKeySaved,
      ollamaSetup: facts.ollamaSetup, ollamaModel: facts.ollamaModel)
  }

  @Test("a take freezes the configuration, revision and episode it starts under")
  func freezesTheTakeContext() throws {
    let world = World()
    let monitor = Self.monitor(world)
    let take = monitor.freezeTakeContext()
    #expect(take.provider == .openAI)
    #expect(take.model == "gpt-test")
    #expect(take.episode == monitor.currentEpisode?.rawValue)
    #expect(take.episode != nil)
    world.configuration = Self.egOne
    #expect(monitor.freezeTakeContext().configurationRevision > take.configurationRevision)
  }

  @Test("evidence is confirmed for the take's frozen provider, from the take's own proof or live facts")
  func confirmsSetupProblems() {
    let world = World()
    world.facts = Self.facts(egOneInstall: .notInstalled, openAIKeySaved: nil)
    let monitor = Self.monitor(world)
    let openAITake = PolishSetupTakeContext(
      provider: .openAI, model: "gpt-test", configurationRevision: 0, episode: nil)
    let egOneTake = PolishSetupTakeContext(
      provider: .egOne, model: "eg-1", configurationRevision: 0, episode: nil)
    let ollamaTake = PolishSetupTakeContext(
      provider: .ollama, model: "qwen3:4b", configurationRevision: 0, episode: nil)

    // No key in the Keychain is its own proof, even while presence was unknown.
    #expect(monitor.confirmedSetupProblem(.cloudKeyMissing, for: openAITake) == .cloudKeyMissing)
    #expect(monitor.confirmedSetupProblem(.cloudKeyMissing, for: egOneTake) == nil)
    // An unreadable Keychain is unknown, never missing.
    #expect(monitor.confirmedSetupProblem(.cloudKeyUnreadable, for: openAITake) == nil)
    // A local engine that was not ready: confirmed by a not-downloaded install, for the
    // frozen provider even though the chosen one is OpenAI now.
    #expect(
      monitor.confirmedSetupProblem(.localEngineNotReady, for: egOneTake) == .localNotDownloaded)
    world.facts = Self.facts(egOneInstall: .paused, openAIKeySaved: nil)
    #expect(
      monitor.confirmedSetupProblem(.localEngineDownloadPending, for: egOneTake)
        == .localDownloadPaused)
    // Installed or still downloading is not an unfinished setup.
    world.facts = Self.facts(egOneInstall: .installed(version: "1.2"))
    #expect(monitor.confirmedSetupProblem(.localEngineNotReady, for: egOneTake) == nil)
    world.facts = Self.facts(egOneInstall: .downloading(fractionCompleted: 0.4, upgrade: nil))
    #expect(monitor.confirmedSetupProblem(.localEngineNotReady, for: egOneTake) == nil)
    // OpenAI's polish request says "rejected" only on HTTP 401: its own typed answer.
    #expect(monitor.confirmedSetupProblem(.cloudKeyRejected, for: openAITake) == .cloudKeyRejected)
    // Gemini's can also come from body text, so it needs the typed verdict for the current key.
    let geminiTake = PolishSetupTakeContext(
      provider: .gemini, model: "gemini-test", configurationRevision: 0, episode: nil)
    #expect(monitor.confirmedSetupProblem(.cloudKeyRejectedClassified, for: geminiTake) == nil)
    var verdictFacts = Self.facts()
    verdictFacts = Self.withVerdict(
      PolishSetupFacts(
        egOneInstall: verdictFacts.egOneInstall, egOneHealth: verdictFacts.egOneHealth,
        s1MiniInstall: verdictFacts.s1MiniInstall, s1MiniHealth: verdictFacts.s1MiniHealth,
        appleStatus: verdictFacts.appleStatus, appleFailureReasons: [], appleIsChecking: false,
        validationProvider: nil, cloudValidation: .idle,
        credentialRevisions: [.openAI: 1, .gemini: 1], cloudVerdicts: [:],
        openAIKeySaved: true, geminiKeySaved: true, claudeKeySaved: true,
        ollamaSetup: .ready, ollamaModel: .installed),
      PolishCloudVerdict(provider: .gemini, credentialRevision: 1, result: .rejected))
    world.facts = verdictFacts
    #expect(
      monitor.confirmedSetupProblem(.cloudKeyRejectedClassified, for: geminiTake)
        == .cloudKeyRejected)
    // Ollama's own check is proof; the service says whether it is installed at all.
    #expect(monitor.confirmedSetupProblem(.ollamaUnreachable, for: ollamaTake) == .ollamaNotRunning)
    world.facts = Self.facts(ollamaSetup: .notInstalled)
    #expect(
      monitor.confirmedSetupProblem(.ollamaUnreachable, for: ollamaTake) == .ollamaNotInstalled)
    #expect(
      monitor.confirmedSetupProblem(.ollamaModelUnavailable, for: ollamaTake)
        == .ollamaModelNotInstalled)
    #expect(monitor.confirmedSetupProblem(.ollamaNoModel, for: ollamaTake) == .ollamaNoModel)
    #expect(monitor.confirmedSetupProblem(.ollamaUnreachable, for: openAITake) == nil)
  }

  @Test("a missing-key take starts the warning when presence was unknown, once, with no new read")
  func missingKeyTakeTeachesPresence() throws {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: nil)
    let keys = KeyLog()
    let monitor = Self.takeMonitor(world, keys: keys)
    monitor.start()
    defer { monitor.stop() }
    // Unknown presence: no warning, and a take starts with no episode.
    #expect(monitor.eligibleProblem == nil)
    let take = monitor.freezeTakeContext()
    #expect(take.episode == nil)
    let missing = Self.outcome(take, evidence: .cloudKeyMissing, tag: .cloudKeyMissing)
    monitor.ingest(missing)
    #expect(keys.reads.count == 1)
    #expect(keys.reads.first?.0 == .openAI)
    #expect(keys.reads.first?.1 == .absent)
    // The same take delivered again changes nothing.
    monitor.ingest(missing)
    #expect(keys.reads.count == 1)
    // An unreadable Keychain publishes unknown, never absent.
    monitor.ingest(Self.outcome(take, id: "take-2", evidence: .cloudKeyUnreadable))
    #expect(keys.reads.last?.1 == .unknown)
  }

  @Test("a take from an older configuration or an ended episode is not taken in")
  func staleTakesAreRejected() throws {
    let world = World()
    let keys = KeyLog()
    let monitor = Self.takeMonitor(world, keys: keys)
    monitor.start()
    defer { monitor.stop() }
    let take = monitor.freezeTakeContext()
    #expect(take.episode != nil)
    // A, then B, then A: the first A's take says nothing.
    world.configuration = Self.egOne
    world.configuration = Self.openAI
    monitor.ingest(Self.outcome(take, evidence: .cloudKeyMissing, tag: .cloudKeyMissing))
    #expect(keys.reads.isEmpty)
    // Repaired, then broken again in the same configuration: a new episode.
    let second = monitor.freezeTakeContext()
    world.facts = Self.facts(openAIKeySaved: true)
    _ = monitor.currentContext()
    #expect(monitor.currentEpisode == nil)
    world.facts = Self.facts(openAIKeySaved: false)
    _ = monitor.currentContext()
    #expect(monitor.currentEpisode?.rawValue != second.episode)
    monitor.ingest(Self.outcome(second, id: "take-2", evidence: .cloudKeyMissing))
    #expect(keys.reads.isEmpty)
  }

  @Test("a take that started with no episode is still rejected after A, then B, then A")
  func episodelessStaleTakeIsRejected() throws {
    let world = World()
    // Unknown presence: no episode, so only the configuration revision can tell this take is old.
    world.facts = Self.facts(openAIKeySaved: nil)
    let keys = KeyLog()
    let monitor = Self.takeMonitor(world, keys: keys)
    monitor.start()
    defer { monitor.stop() }
    let take = monitor.freezeTakeContext()
    #expect(take.episode == nil)
    world.configuration = Self.egOne
    world.configuration = Self.openAI
    monitor.ingest(Self.outcome(take, evidence: .cloudKeyMissing, tag: .cloudKeyMissing))
    #expect(keys.reads.isEmpty)
    // Control: the same evidence from a take of the current configuration is taken in.
    monitor.ingest(
      Self.outcome(monitor.freezeTakeContext(), id: "take-2", evidence: .cloudKeyMissing))
    #expect(keys.reads.count == 1)
  }

  @Test("an Ollama take is believed only if it observed after the service last committed")
  func ollamaTakeOrdering() throws {
    let world = World()
    world.configuration = Self.ollama
    world.facts = Self.facts(ollamaSetup: .ready)
    let keys = KeyLog()
    let monitor = Self.takeMonitor(world, keys: keys)
    monitor.start()
    defer { monitor.stop() }
    let take = monitor.freezeTakeContext()
    let observedAt = ContinuousClock.now
    // The service committed AFTER the take observed: the service wins.
    world.ollamaLastCommitAt = observedAt.advanced(by: .seconds(1))
    monitor.ingest(
      Self.outcome(take, evidence: .ollamaUnreachable, tag: .ollamaNotRunning, at: observedAt))
    #expect(monitor.eligibleProblem == nil)
    // A later take that observed after the commit is believed.
    monitor.ingest(
      Self.outcome(
        take, id: "take-2", evidence: .ollamaUnreachable, tag: .ollamaNotRunning,
        at: observedAt.advanced(by: .seconds(2))))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
    #expect(keys.reads.isEmpty)
  }

  @Test("a key rejected during dictation warns with no Settings visit; a later success repairs it")
  func rejectedKeyLearnedFromDictation() throws {
    let world = World()
    // After relaunch: the key is saved and nothing has checked it.
    world.facts = Self.facts(openAIKeySaved: true)
    let keys = KeyLog()
    let monitor = Self.takeMonitor(world, keys: keys)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == nil)
    let take = monitor.freezeTakeContext()
    let start = ContinuousClock.now
    monitor.ingest(
      Self.outcome(take, evidence: .cloudKeyRejected, tag: .cloudKeyRejected, at: start))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // An older success arriving late changes nothing.
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-old", context: take, result: .polished, evidence: nil, setupProblem: nil,
        observedAt: start.advanced(by: .seconds(-1))))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // A newer take that polished: the key works again.
    let next = monitor.freezeTakeContext()
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-2", context: next, result: .polished, evidence: nil, setupProblem: nil,
        observedAt: start.advanced(by: .seconds(1))))
    #expect(monitor.eligibleProblem == nil)
    #expect(keys.reads.isEmpty, "no key read was stamped, so no presence is published")
    // Rejected again later: the warning returns.
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), id: "take-3", evidence: .cloudKeyRejected,
        tag: .cloudKeyRejected, at: start.advanced(by: .seconds(2))))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // A new key starts clean (the saved key's revision moves in the facts and the
    // configuration together, as `SavedKeyPresence` moves both in the app).
    world.facts = Self.facts(openAIKeySaved: true, openAIRevision: 2)
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-test", credentialRevision: 2)
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("an Ollama take that polished repairs an old failure; a short take does not")
  func ollamaRepairAndRecurrence() throws {
    let world = World()
    world.configuration = Self.ollama
    // The service's last word (no Settings page watching) says Ollama is not running.
    world.facts = Self.facts(ollamaSetup: .installedNotRunning)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    let take = monitor.freezeTakeContext()
    monitor.ingest(
      Self.outcome(take, evidence: .ollamaUnreachable, tag: .ollamaNotRunning, at: start))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
    // Too short: no model was asked, so it proves nothing.
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-short", context: monitor.freezeTakeContext(), result: .bypassed,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(1))))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
    // Started outside the app, then a dictation polished.
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-2", context: monitor.freezeTakeContext(), result: .polished,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(2))))
    #expect(monitor.eligibleProblem == nil)
    #expect(monitor.currentEpisode == nil, "a repair ends the episode, it does not only pause it")
    // Stopped again.
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), id: "take-3", evidence: .ollamaUnreachable,
        tag: .ollamaNotRunning, at: start.advanced(by: .seconds(3))))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
  }

  private static func openAIFacts(verdict: PolishCloudVerdict?) -> PolishSetupFacts {
    withVerdict(facts(openAIKeySaved: true), verdict)
  }

  @Test("the newest of the key check and a dictation's own request decides, both ways")
  func keyCheckAndTakesAreOrdered() throws {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: true)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    // A dictation's request is rejected.
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .cloudKeyRejected, tag: .cloudKeyRejected,
        at: start))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // An OLDER key check that accepted the key arrives late: the rejection stands.
    world.facts = Self.openAIFacts(
      verdict: PolishCloudVerdict(
        provider: .openAI, credentialRevision: 1, result: .accepted,
        decidedAt: start.advanced(by: .seconds(-1))))
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // A NEWER key check accepts it: the warning clears.
    world.facts = Self.openAIFacts(
      verdict: PolishCloudVerdict(
        provider: .openAI, credentialRevision: 1, result: .accepted,
        decidedAt: start.advanced(by: .seconds(1))))
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == nil)
    // The key check rejects it; then a NEWER dictation polishes: the warning clears again.
    world.facts = Self.openAIFacts(
      verdict: PolishCloudVerdict(
        provider: .openAI, credentialRevision: 1, result: .rejected,
        decidedAt: start.advanced(by: .seconds(2))))
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-2", context: monitor.freezeTakeContext(), result: .polished,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(3))))
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("Gemini: a typed rejection confirms with no key check; body text alone does not")
  func geminiRejectionNeedsTypedEvidence() {
    let world = World()
    let monitor = Self.monitor(world)
    let gemini = PolishSetupTakeContext(
      provider: .gemini, model: "gemini-test", configurationRevision: 0, episode: nil)
    #expect(monitor.confirmedSetupProblem(.cloudKeyRejected, for: gemini) == .cloudKeyRejected)
    #expect(monitor.confirmedSetupProblem(.cloudKeyRejectedClassified, for: gemini) == nil)
    let openAI = PolishSetupTakeContext(
      provider: .openAI, model: "gpt-test", configurationRevision: 0, episode: nil)
    #expect(
      monitor.confirmedSetupProblem(.cloudKeyRejectedClassified, for: openAI) == .cloudKeyRejected)
  }

  /// The saved-key owner as the app wires it: the monitor's key evidence lands in the facts.
  private static func presenceMonitor(_ world: World) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs },
      recordKeyEvidence: { _, state, _ in
        world.facts = Self.facts(openAIKeySaved: state.asSavedFlag)
      })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    return monitor
  }

  @Test("unknown presence: a rejection warns, a later success ends that episode, a new rejection starts afresh")
  func unknownPresenceRejectionEpisodes() throws {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: nil)
    let monitor = Self.presenceMonitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.currentEpisode == nil)
    let start = ContinuousClock.now
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-1", context: monitor.freezeTakeContext(), result: .failed,
        evidence: .cloudKeyRejected, setupProblem: .cloudKeyRejected,
        observedAt: start.advanced(by: .milliseconds(5)), keyReadAt: start))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    let first = try #require(monitor.currentEpisode)
    let ticket = try #require(monitor.cardTicket())
    monitor.cardPresented(ticket)
    #expect(monitor.cardTicket() == nil, "the card was spent for this episode")

    // A later dictation polished with the same key: the episode ends.
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-2", context: monitor.freezeTakeContext(), result: .polished,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(1)),
        keyReadAt: start.advanced(by: .milliseconds(900))))
    #expect(monitor.eligibleProblem == nil)
    #expect(monitor.currentEpisode == nil)

    // Rejected again: a NEW episode, with the card allowed again.
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-3", context: monitor.freezeTakeContext(), result: .failed,
        evidence: .cloudKeyRejected, setupProblem: .cloudKeyRejected,
        observedAt: start.advanced(by: .seconds(2)),
        keyReadAt: start.advanced(by: .milliseconds(1900))))
    let second = try #require(monitor.currentEpisode)
    #expect(second != first)
    #expect(monitor.cardTicket() != nil)
  }

  @Test("another model from the same provider keeps a rejected key's warning; a new key clears it")
  func rejectionBelongsToTheKeyNotTheModel() throws {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: true)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .cloudKeyRejected, tag: .cloudKeyRejected))
    let before = try #require(monitor.currentEpisode)
    // Another OpenAI model, same saved key.
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-other", credentialRevision: 1)
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    #expect(monitor.currentEpisode != before, "a new configuration is a new episode")
    // A new key.
    world.facts = Self.facts(openAIKeySaved: true, openAIRevision: 2)
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-other", credentialRevision: 2)
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("a key a dictation proved rejected is never offered as the way back")
  func goBackHonorsDictationEvidence() throws {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: true)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .cloudKeyRejected, tag: .cloudKeyRejected))
    // The person picks EG-1, which is not downloaded, then tries to leave AI Polish.
    world.facts = Self.facts(egOneInstall: .notInstalled, openAIKeySaved: true)
    world.configuration = Self.egOne
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudKeyRejected(.openAI)))
    let request = try #require(
      PolishSetupLeaveGuard.request(
        for: .sidebar(.history), from: .aiPolish, monitor: monitor, previousProvider: .openAI,
        currentProvider: .egOne, keyNotSaved: false))
    #expect(request.goBackProvider == nil, "offered a way back to a key known to be rejected")
  }

  @Test("each provider keeps its own dictation evidence: Gemini working says nothing about OpenAI")
  func cloudEvidenceIsPerProvider() throws {
    let world = World()
    var facts = Self.facts(openAIKeySaved: true)
    facts = PolishSetupFacts(
      egOneInstall: facts.egOneInstall, egOneHealth: facts.egOneHealth,
      s1MiniInstall: facts.s1MiniInstall, s1MiniHealth: facts.s1MiniHealth,
      appleStatus: facts.appleStatus, appleFailureReasons: [], appleIsChecking: false,
      validationProvider: nil, cloudValidation: .idle,
      credentialRevisions: [.openAI: 1, .gemini: 1], cloudVerdicts: [:],
      openAIKeySaved: true, geminiKeySaved: true, claudeKeySaved: true,
      ollamaSetup: .ready, ollamaModel: .installed)
    world.facts = facts
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .cloudKeyRejected, tag: .cloudKeyRejected,
        at: start))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // Gemini, then a Gemini dictation that polished.
    world.configuration = PolishSetupConfiguration(
      provider: .gemini, model: "gemini-test", credentialRevision: 1)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-gemini", context: monitor.freezeTakeContext(), result: .polished,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(1))))
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudKeyRejected(.openAI)))
    // Back to OpenAI: its key is still known to be rejected.
    world.configuration = Self.openAI
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
  }

  @Test("Ollama not running holds across a model change; a missing model only for that model")
  func ollamaEvidenceAcrossModels() {
    let world = World()
    world.configuration = Self.ollama
    world.facts = Self.facts(ollamaSetup: .ready)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .ollamaUnreachable, tag: .ollamaNotRunning,
        at: start))
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
    // Another Ollama model: the server is still not running.
    world.configuration = PolishSetupConfiguration(
      provider: .ollama, model: "llama3:8b", credentialRevision: nil)
    #expect(monitor.eligibleProblem == .ollamaNotRunning)
    // A missing model is about that model only.
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), id: "take-2", evidence: .ollamaModelUnavailable,
        tag: .ollamaModelNotInstalled, at: start.advanced(by: .seconds(1))))
    #expect(monitor.eligibleProblem == .ollamaModelNotInstalled)
    world.configuration = Self.ollama
    #expect(monitor.eligibleProblem == nil, "another model's missing model was applied")
  }

  @Test("a check that could not tell never erases a newer definitive answer about the key")
  func inconclusiveKeepsTheDefinitiveAnswer() {
    let world = World()
    world.facts = Self.facts(openAIKeySaved: true)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    // T1: a dictation's request was rejected.
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .cloudKeyRejected, tag: .cloudKeyRejected,
        at: start))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI))
    // T2: the key check accepted it. T3: a later check could not tell (offline).
    let accepted = PolishCloudVerdict(
      provider: .openAI, credentialRevision: 1, result: .accepted,
      decidedAt: start.advanced(by: .seconds(1)))
    world.facts = Self.withVerdict(
      Self.facts(openAIKeySaved: true),
      PolishCloudVerdict(
        provider: .openAI, credentialRevision: 1, result: .inconclusive,
        decidedAt: start.advanced(by: .seconds(2)), definitive: accepted.lastDefinitive))
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == nil, "the T1 rejection came back over the T2 repair")
  }

  @Test("Ollama: a success with model B never erases model A's missing-model answer")
  func ollamaModelEvidenceIsPerModel() {
    let world = World()
    world.configuration = Self.ollama
    world.facts = Self.facts(ollamaSetup: .ready)
    let monitor = Self.takeMonitor(world, keys: KeyLog())
    monitor.start()
    defer { monitor.stop() }
    let start = ContinuousClock.now
    monitor.ingest(
      Self.outcome(
        monitor.freezeTakeContext(), evidence: .ollamaModelUnavailable,
        tag: .ollamaModelNotInstalled, at: start))
    #expect(monitor.eligibleProblem == .ollamaModelNotInstalled)
    world.configuration = PolishSetupConfiguration(
      provider: .ollama, model: "llama3:8b", credentialRevision: nil)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-b", context: monitor.freezeTakeContext(), result: .polished,
        evidence: nil, setupProblem: nil, observedAt: start.advanced(by: .seconds(1))))
    #expect(monitor.eligibleProblem == nil)
    world.configuration = Self.ollama
    #expect(monitor.eligibleProblem == .ollamaModelNotInstalled)
    // Leaving for another provider: Ollama is not offered back while a model is known missing
    // and the way back cannot say which model it would select.
    world.configuration = Self.openAI
    #expect(monitor.readiness(for: .ollama) == .unknown)
  }
}
