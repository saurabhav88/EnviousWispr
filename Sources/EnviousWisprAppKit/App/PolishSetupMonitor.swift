import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Observation

// MARK: - Which setup warnings may show (#3438)

/// A warning surface. Each one remembers its own acknowledgement; the menu line and the
/// sidebar tag have none and show for as long as the problem does.
enum PolishSetupSurface: Hashable, CaseIterable {
  case leaveDialog
  case card
  case banner
  case menu
  case sidebarTag
}

/// What the chosen configuration is: the provider, the model it actually asks for, and the
/// saved credential's revision (cloud only). A change to any of them ends the episode; a change
/// to anything else does not.
struct PolishSetupConfiguration: Hashable {
  let provider: LLMProvider
  let model: String
  let credentialRevision: UInt64?
}

/// One stretch of time during which the chosen configuration has a setup problem. Ends on
/// confirmed repair, a configuration change, or relaunch. Memory is per episode.
struct PolishSetupEpisodeToken: Hashable {
  let rawValue: UInt64
}

/// What a caller freezing a take needs (#3438 chunk 4), captured when the take starts: the
/// configuration, a revision that moves on every configuration change (so A, then B, then A
/// again is not the first A), and the episode. Identity only: WHEN the take observed
/// something is stamped separately, at the moment it observed it.
struct PolishSetupContext: Equatable {
  let configuration: PolishSetupConfiguration
  let configurationRevision: UInt64
  let episode: PolishSetupEpisodeToken?
}

/// A permission to present the card, tied to the episode and to the eligibility generation it
/// was issued under. Only a matching receipt spends the card.
struct PolishSetupCardTicket: Hashable {
  let episode: PolishSetupEpisodeToken
  let generation: UInt64
}

/// Everything the monitor reads in one go, so a reconciliation never mixes old and new values.
struct PolishSetupInputs {
  let onboardingComplete: Bool
  let configuration: PolishSetupConfiguration
  let facts: PolishSetupFacts
  /// When the Ollama service last committed its state (`lastCommitAt`); nil if never.
  let ollamaLastCommitAt: ContinuousClock.Instant?
}

/// The episode state machine, as a value: pure, so its rules are tested without an app.
struct PolishSetupEpisodes: Equatable {
  struct Episode: Equatable {
    let token: PolishSetupEpisodeToken
    let configuration: PolishSetupConfiguration
    var problem: PolishSetupProblem
    var acknowledged: Set<PolishSetupSurface> = []
    var cardSpent = false
  }

  private(set) var episode: Episode?
  /// The confirmed problem a surface may show now: nil while suppressed, unknown or checking.
  private(set) var eligibleProblem: PolishSetupProblem?
  /// Moves whenever eligibility is lost, so a card ticket issued before cannot be spent after.
  private(set) var generation: UInt64 = 0
  private var nextToken: UInt64 = 1

  /// One reconciliation. `eligible` is false while polish is off or onboarding is incomplete.
  mutating func reconcile(
    readiness: PolishSetupReadiness, configuration: PolishSetupConfiguration, eligible: Bool
  ) {
    // A different provider, model or credential is a different setup: its memory starts over.
    if let current = episode, current.configuration != configuration { episode = nil }

    switch readiness {
    case .noProblem:
      // Confirmed repair ends the episode.
      episode = nil
    case .unknown, .checking:
      // Suspends what may show, keeps what was remembered.
      break
    case .problem(let problem):
      if episode == nil {
        episode = Episode(
          token: PolishSetupEpisodeToken(rawValue: nextToken), configuration: configuration,
          problem: problem)
        nextToken &+= 1
      } else {
        // Same configuration, the problem moved (not downloaded, then downloading, then
        // paused). Still the same unfinished setup: the person's answers stand.
        episode?.problem = problem
      }
    }

    let shown: PolishSetupProblem?
    if eligible, case .problem = readiness { shown = episode?.problem } else { shown = nil }
    if shown == nil, eligibleProblem != nil { generation &+= 1 }
    eligibleProblem = shown
  }

  func shows(_ surface: PolishSetupSurface) -> Bool {
    guard let problem = eligibleProblem, let episode else { return false }
    switch surface {
    case .leaveDialog:
      // Informational problems still get their OK-only notice on leaving.
      return !episode.acknowledged.contains(.leaveDialog)
    case .card:
      // Apple Intelligence unavailable never gets a dictation card: its pipeline skip stays
      // silent (plan §14 Q1); the Settings-side surfaces still tell the person.
      return problem.isActionable
        && episode.configuration.provider != .appleIntelligence
        && !episode.cardSpent
        && !episode.acknowledged.contains(.card)
    case .banner:
      return problem.isActionable && !episode.acknowledged.contains(.banner)
    case .menu, .sidebarTag:
      return problem.isActionable
    }
  }

  mutating func acknowledge(_ surface: PolishSetupSurface, in token: PolishSetupEpisodeToken) {
    guard episode?.token == token else { return }
    switch surface {
    case .leaveDialog, .card, .banner: episode?.acknowledged.insert(surface)
    // These have no dismissal; an acknowledgement is ignored rather than invented.
    case .menu, .sidebarTag: return
    }
  }

  /// A ticket to try presenting the card now, or nil when the card may not show. Asking does
  /// not spend anything.
  func cardTicket() -> PolishSetupCardTicket? {
    guard shows(.card), let episode else { return nil }
    return PolishSetupCardTicket(episode: episode.token, generation: generation)
  }

  /// The card was actually presented. Spends it only for the current episode and generation,
  /// and answers whether it did; a duplicate or stale receipt does nothing and answers false.
  @discardableResult
  mutating func cardPresented(_ ticket: PolishSetupCardTicket) -> Bool {
    guard ticket.generation == generation, episode?.token == ticket.episode, shows(.card)
    else { return false }
    episode?.cardSpent = true
    return true
  }

  /// Whether a card raised under `ticket` still describes the present: the same episode, the
  /// same eligibility generation, and a problem still eligible to show. Spending the card does
  /// not end it (the card on screen IS the spend).
  func cardStillApplies(_ ticket: PolishSetupCardTicket) -> Bool {
    guard let episode, let problem = eligibleProblem else { return false }
    // Downloading or being checked is not something to finish: the card leaves, the episode
    // and its memory stay.
    return ticket.generation == generation
      && episode.token == ticket.episode
      && episode.configuration.provider != .appleIntelligence
      && problem.isActionable
  }
}

/// Decides which AI polish setup warnings may show, for dictation's chosen model (#3438).
///
/// Facts are derived on every reconciliation from the live owners (`PolishSetupFacts`) and
/// judged by `PolishSetupReadiness`; this owner keeps only what cannot be derived: the episode,
/// what each surface was told, whether the card was presented, and the order of Ollama
/// observations. Nothing is persisted, so a relaunch starts fresh. A limb: when it is wrong, a
/// warning is wrong; dictation is unaffected.
@MainActor @Observable
final class PolishSetupMonitor {
  private(set) var episodes = PolishSetupEpisodes()

  @ObservationIgnored private let readInputs: @MainActor () -> PolishSetupInputs
  @ObservationIgnored private let ollamaRefresh: OllamaOffPageRefresh?
  /// Where `polish_setup.prompt` rows go. Production sends them; tests collect them.
  @ObservationIgnored private let reportPrompt: @MainActor (PolishSetupPromptEvent) -> Void
  /// Where a take's own key read goes (`SavedKeyPresence.recordRead` in production): a take
  /// that found no key is confirmed evidence the key is absent, with no second read.
  @ObservationIgnored private let recordKeyEvidence:
    @MainActor (LLMProvider, SavedKeyState, ContinuousClock.Instant) -> Void
  /// Takes already taken in, newest last, so a repeated delivery changes nothing.
  @ObservationIgnored private var ingestedTakeIDs: [String] = []
  @ObservationIgnored private var observing = false
  @ObservationIgnored private var observationGeneration: UInt64 = 0
  /// Moves on every change of the chosen configuration, including a return to an earlier one.
  @ObservationIgnored private var configurationRevision: UInt64 = 0
  @ObservationIgnored private var lastConfiguration: PolishSetupConfiguration?
  @ObservationIgnored private var lastEligible = false
  /// The newest thing a take said about Ollama for the current configuration revision, and
  /// WHEN the take observed it. Whichever of this and the service's own last commit is newer
  /// is believed (#3438 chunk 4 records these).
  @ObservationIgnored private var ollamaTakeObservation:
    (revision: UInt64, problem: PolishSetupProblem?, observedAt: ContinuousClock.Instant)?
  /// The newest thing a take said about a saved cloud key: rejected by the provider, or accepted
  /// (a take that polished). A fact about THAT key (provider and credential revision), so it
  /// survives a model change and stops counting when the key is replaced or cleared.
  @ObservationIgnored private var cloudKeyTakeObservation:
    (provider: LLMProvider, credentialRevision: UInt64, rejected: Bool,
      observedAt: ContinuousClock.Instant)?

  init(
    readInputs: @escaping @MainActor () -> PolishSetupInputs,
    ollamaRefresh: OllamaOffPageRefresh? = nil,
    reportPrompt: @escaping @MainActor (PolishSetupPromptEvent) -> Void = { $0.send() },
    recordKeyEvidence: @escaping @MainActor (LLMProvider, SavedKeyState, ContinuousClock.Instant)
      -> Void = { _, _, _ in }
  ) {
    self.readInputs = readInputs
    self.ollamaRefresh = ollamaRefresh
    self.reportPrompt = reportPrompt
    self.recordKeyEvidence = recordKeyEvidence
  }

  // MARK: - What surfaces read

  var eligibleProblem: PolishSetupProblem? { episodes.eligibleProblem }

  func shows(_ surface: PolishSetupSurface) -> Bool { episodes.shows(surface) }

  /// Whether `provider` would be fully set up if chosen now, from the same live facts. For the
  /// leave dialog's "Go back to" offer; it changes no warning memory.
  func readiness(for provider: LLMProvider) -> PolishSetupReadiness {
    PolishSetupReadiness.evaluate(provider: provider, facts: readInputs().facts)
  }

  /// The episode a surface is showing now, for it to hand back with the person's answer.
  var currentEpisode: PolishSetupEpisodeToken? { episodes.episode?.token }

  /// The person answered a surface that was showing `token`'s episode. An answer about an
  /// episode that has since ended changes nothing.
  func acknowledge(_ surface: PolishSetupSurface, in token: PolishSetupEpisodeToken) {
    reconcile()
    episodes.acknowledge(surface, in: token)
  }

  /// What a surface showing now is about: the eligible problem and the provider of the episode
  /// that has it. A surface takes this when it shows and reports with that copy.
  var promptSubject: PolishSetupPromptSubject? {
    guard let problem = episodes.eligibleProblem, let episode = episodes.episode else {
      return nil
    }
    return PolishSetupPromptSubject(problem: problem, provider: episode.configuration.provider)
  }

  /// One `polish_setup.prompt` row about `subject`, as the surface had it when it showed. Never
  /// rebuilt from live settings: the person may have changed model since.
  func recordPrompt(
    _ surface: PolishSetupPromptEvent.Surface, _ action: PolishSetupPromptEvent.Action,
    subject: PolishSetupPromptSubject, takeID: UUID? = nil
  ) {
    reportPrompt(
      PolishSetupPromptEvent(surface: surface, action: action, subject: subject, takeID: takeID))
  }

  func cardTicket() -> PolishSetupCardTicket? {
    reconcile()
    return episodes.cardTicket()
  }

  /// The card really appeared. Judged against the live state, not the last observed one;
  /// answers whether this presentation spent the card (false: stale, duplicate, or no longer
  /// eligible, and the caller withdraws it).
  @discardableResult
  func cardPresented(_ ticket: PolishSetupCardTicket) -> Bool {
    reconcile()
    return episodes.cardPresented(ticket)
  }

  /// Whether a card raised under `ticket` still describes the present (live state).
  func cardStillApplies(_ ticket: PolishSetupCardTicket) -> Bool {
    reconcile()
    return episodes.cardStillApplies(ticket)
  }

  /// Told SYNCHRONOUSLY whenever the episode state changes (an episode starts or ends,
  /// eligibility is lost or regained, a surface is answered), so the card owner can withdraw a
  /// card that no longer applies in the same turn, without waiting for observation.
  @ObservationIgnored var onEpisodeChange: (@MainActor () -> Void)?

  /// The configuration and episode now, read from the live owners rather than a cached copy,
  /// for a take freezing its context at start.
  func currentContext() -> PolishSetupContext {
    let inputs = reconcile()
    return PolishSetupContext(
      configuration: inputs.configuration, configurationRevision: configurationRevision,
      episode: episodes.episode?.token)
  }

  /// Called SYNCHRONOUSLY by the owners of the configuration and eligibility (the settings
  /// change hook, the saved-key owner) at the moment they change. Observation alone samples
  /// later and could miss A, then B, then A, or off then on, between two samples; these
  /// transitions must never be missed, because they decide which takes and tickets still count.
  func configurationOrEligibilityChanged() {
    reconcile()
  }

  // MARK: - Takes (#3438 chunk 4)

  /// The setup a take starting now runs under, read from the live owners, for the driver to
  /// freeze beside the take's config.
  func freezeTakeContext() -> PolishSetupTakeContext {
    let context = currentContext()
    return PolishSetupTakeContext(
      provider: context.configuration.provider, model: context.configuration.model,
      configurationRevision: context.configurationRevision, episode: context.episode?.rawValue)
  }

  /// Whether a take's typed evidence confirms an unfinished setup for the take's FROZEN
  /// provider, judged now from the same live facts as every warning. Evidence alone is enough
  /// only where the take itself proved it (no key in the Keychain; Ollama's own check before the
  /// request). A rejected key needs the typed verdict for the current key; a local engine that
  /// was not ready needs a confirmed not-downloaded, paused or failed install. Anything else
  /// (unreadable key, installed or busy engine, a crash, a timeout) is not a setup problem.
  func confirmedSetupProblem(
    _ evidence: PolishSetupEvidence, for take: PolishSetupTakeContext
  ) -> PolishSetupProblemTag? {
    let provider = take.provider
    switch evidence {
    case .cloudKeyMissing:
      return Self.usesCloudKey(provider) ? .cloudKeyMissing : nil
    case .cloudKeyUnreadable:
      return nil
    case .cloudKeyRejected:
      // The provider's own typed rejection (Gemini: 401 or its structured API_KEY_INVALID).
      return Self.usesCloudKey(provider) ? .cloudKeyRejected : nil
    case .cloudKeyRejectedClassified:
      switch provider {
      case .openAI, .claude:
        // Their polish classifiers report rejection from HTTP 401 alone.
        return .cloudKeyRejected
      case .gemini:
        // Read from body text only: confirmed by nothing but the typed verdict for the
        // current key.
        guard case .problem(.cloudKeyRejected(.gemini)) = readiness(for: .gemini) else {
          return nil
        }
        return .cloudKeyRejected
      case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
        return nil
      }
    case .ollamaUnreachable:
      guard provider == .ollama else { return nil }
      // The take's own check found no server; the service's facts say whether Ollama is
      // installed at all.
      if case .problem(.ollamaNotInstalled) = readiness(for: .ollama) { return .ollamaNotInstalled }
      return .ollamaNotRunning
    case .ollamaModelUnavailable:
      return provider == .ollama ? .ollamaModelNotInstalled : nil
    case .ollamaNoModel:
      return provider == .ollama ? .ollamaNoModel : nil
    case .localEngineNotReady, .localEngineDownloadPending:
      guard case .problem(let problem) = readiness(for: provider) else { return nil }
      switch problem {
      case .localEngineNotDownloaded(let engine) where engine == provider:
        return .localNotDownloaded
      case .localEngineDownloadPaused(let engine) where engine == provider:
        return .localDownloadPaused
      case .localEngineUpdatePaused(let engine) where engine == provider:
        return .localUpdatePaused
      case .localEngineFailed(let engine) where engine == provider:
        return .localDownloadFailed
      case .cloudKeyMissing, .cloudKeyRejected, .ollamaNotInstalled, .ollamaNotRunning,
        .ollamaNoModel, .ollamaModelNotInstalled, .localEngineNotDownloaded,
        .localEngineDownloadPaused, .localEngineUpdatePaused, .localEngineFailed,
        .localEngineDownloading, .localEngineVerifying, .appleUnavailable, .appleModelNotReady:
        // Downloading, verifying or another engine's state: not this take's setup problem.
        return nil
      }
    }
  }

  /// A concluded take's polish outcome. Taken in only while it still describes the current
  /// configuration (same revision, provider and model) and, when the take started inside an
  /// episode, that same episode; once per take. A take that started with no episode (a key
  /// whose presence was not yet known) is taken in: its configuration revision already rejects
  /// a take from before any provider, model or key change.
  @discardableResult
  func ingest(_ outcome: PolishTakeOutcome) -> Bool {
    reconcile()
    let take = outcome.context
    guard ingestedTakeIDs.contains(outcome.takeID) == false,
      take.configurationRevision == configurationRevision,
      let configuration = lastConfiguration,
      configuration.provider == take.provider, configuration.model == take.model
    else { return false }
    if let episode = take.episode, episodes.episode?.token.rawValue != episode { return false }
    ingestedTakeIDs.append(outcome.takeID)
    if ingestedTakeIDs.count > 16 { ingestedTakeIDs.removeFirst() }

    // A bypassed (too short) or skipped take asked no model, so only `.polished` is repair.
    let polished = outcome.result == .polished
    if Self.usesCloudKey(take.provider) {
      switch outcome.evidence {
      case .cloudKeyMissing?:
        recordKeyEvidence(take.provider, .absent, outcome.observedAt)
      case .cloudKeyUnreadable?:
        recordKeyEvidence(take.provider, .unknown, outcome.observedAt)
      case .cloudKeyRejected?, .cloudKeyRejectedClassified?:
        if outcome.setupProblem == .cloudKeyRejected {
          recordCloudKeyTakeObservation(
            rejected: true, configuration: configuration, observedAt: outcome.observedAt)
        }
      case .localEngineNotReady?, .localEngineDownloadPending?, .ollamaUnreachable?,
        .ollamaModelUnavailable?, .ollamaNoModel?, nil:
        break
      }
      if polished {
        recordCloudKeyTakeObservation(
          rejected: false, configuration: configuration, observedAt: outcome.observedAt)
      }
      // A request the provider answered or rejected carried a saved key when the connector read
      // it: present AT THAT READ, ordered by the saved-key owner against every newer answer (a
      // clear made while the request was in flight stays newer).
      if let keyReadAt = outcome.keyReadAt,
        polished || outcome.evidence == .cloudKeyRejected
          || outcome.evidence == .cloudKeyRejectedClassified
      {
        recordKeyEvidence(take.provider, .present, keyReadAt)
      }
    }
    if take.provider == .ollama {
      let problem: PolishSetupProblem??
      if polished {
        problem = .some(nil)
      } else if let tag = outcome.setupProblem, let confirmed = Self.ollamaProblem(tag) {
        problem = .some(confirmed)
      } else {
        problem = nil
      }
      if let problem {
        recordOllamaTakeObservation(
          problem,
          context: PolishSetupContext(
            configuration: configuration, configurationRevision: take.configurationRevision,
            episode: episodes.episode?.token),
          observedAt: outcome.observedAt)
      }
    }
    return true
  }

  /// When the key check answered (accepted or rejected) about the key saved now; nil when it
  /// has not, or answered about an older key.
  private static func cloudVerdictAt(
    _ facts: PolishSetupFacts, provider: LLMProvider
  ) -> ContinuousClock.Instant? {
    guard let verdict = facts.cloudVerdict, verdict.provider == provider,
      verdict.credentialRevision == facts.credentialRevisions[provider]
    else { return nil }
    switch verdict.result {
    case .accepted, .rejected: return verdict.decidedAt
    case .checking, .inconclusive: return nil
    }
  }

  /// Newer wins, for the same saved key only; a different key replaces it outright.
  private func recordCloudKeyTakeObservation(
    rejected: Bool, configuration: PolishSetupConfiguration, observedAt: ContinuousClock.Instant
  ) {
    guard let credentialRevision = configuration.credentialRevision else { return }
    if let current = cloudKeyTakeObservation, current.provider == configuration.provider,
      current.credentialRevision == credentialRevision, current.observedAt >= observedAt
    {
      return
    }
    cloudKeyTakeObservation = (configuration.provider, credentialRevision, rejected, observedAt)
    reconcile()
  }

  private static func usesCloudKey(_ provider: LLMProvider) -> Bool {
    switch provider {
    case .openAI, .gemini, .claude: return true
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: return false
    }
  }

  private static func ollamaProblem(_ tag: PolishSetupProblemTag) -> PolishSetupProblem? {
    switch tag {
    case .ollamaNotInstalled: return .ollamaNotInstalled
    case .ollamaNotRunning: return .ollamaNotRunning
    case .ollamaNoModel: return .ollamaNoModel
    case .ollamaModelNotInstalled: return .ollamaModelNotInstalled
    case .cloudKeyMissing, .cloudKeyRejected, .localNotDownloaded, .localDownloadPaused,
      .localUpdatePaused, .localDownloadFailed:
      return nil
    }
  }

  // MARK: - Ollama ordering

  /// A take that started under `context` observed Ollama at `observedAt` (chunk 4: stamped
  /// by the producer when it observed, never at delivery). Ignored unless the configuration
  /// is still the one the take started under, and unless it is newer than the observation
  /// already recorded.
  func recordOllamaTakeObservation(
    _ problem: PolishSetupProblem?, context: PolishSetupContext,
    observedAt: ContinuousClock.Instant
  ) {
    reconcile()
    guard context.configuration.provider == .ollama,
      context.configurationRevision == configurationRevision
    else { return }
    if let current = ollamaTakeObservation, current.revision == configurationRevision,
      current.observedAt >= observedAt
    {
      return
    }
    ollamaTakeObservation = (configurationRevision, problem, observedAt)
    reconcile()
  }

  // MARK: - Lifecycle

  /// Starts observing the live owners. Idempotent.
  func start() {
    guard !observing else { return }
    observing = true
    observationGeneration &+= 1
    observe(generation: observationGeneration)
  }

  /// Stops observing; a queued callback from before cannot revive it.
  func stop() {
    observing = false
    observationGeneration &+= 1
    ollamaRefresh?.cancel()
  }

  /// App activation: one off-page Ollama refresh when dictation's chosen model is Ollama and
  /// no Settings page is watching it.
  func applicationDidBecomeActive() {
    let inputs = readInputs()
    guard observing, inputs.onboardingComplete, inputs.configuration.provider == .ollama
    else { return }
    ollamaRefresh?.requestOnce()
  }

  // MARK: - Reconciliation

  private func observe(generation: UInt64) {
    withObservationTracking {
      reconcile()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.observing, self.observationGeneration == generation else { return }
        self.observe(generation: generation)
      }
    }
  }

  /// Reads one coherent snapshot and moves the episode. Reading the live owners here is what
  /// registers them for observation.
  @discardableResult
  private func reconcile() -> PolishSetupInputs {
    let inputs = readInputs()
    let eligible = inputs.onboardingComplete && inputs.configuration.provider != .none
    if lastConfiguration != inputs.configuration {
      if lastConfiguration != nil { configurationRevision &+= 1 }
      lastConfiguration = inputs.configuration
      ollamaTakeObservation = nil
      // A refresh asked for the previous configuration answers a question nobody asks now.
      ollamaRefresh?.cancel()
    }
    if lastEligible, !eligible { ollamaRefresh?.cancel() }
    lastEligible = eligible

    var readiness = PolishSetupReadiness.evaluate(
      provider: inputs.configuration.provider, facts: inputs.facts)
    if inputs.configuration.provider == .ollama, let take = ollamaTakeObservation,
      take.revision == configurationRevision,
      inputs.ollamaLastCommitAt.map({ $0 < take.observedAt }) ?? true
    {
      // A take that polished is repair evidence, newer than the service's last word.
      readiness = take.problem.map { .problem($0) } ?? .noProblem
    }
    let provider = inputs.configuration.provider
    if Self.usesCloudKey(provider), let take = cloudKeyTakeObservation,
      take.provider == provider,
      take.credentialRevision == inputs.configuration.credentialRevision,
      Self.cloudVerdictAt(inputs.facts, provider: provider).map({ $0 < take.observedAt }) ?? true
    {
      // The newest answer about this key came from a dictation's own request, not from the
      // key check: it decides.
      switch (take.rejected, readiness) {
      case (true, .noProblem), (true, .unknown):
        // The provider rejected this key during a dictation (no Settings visit needed).
        readiness = .problem(.cloudKeyRejected(provider))
      case (false, .problem(.cloudKeyRejected(provider))):
        // A dictation polished with this key after the check rejected it.
        readiness = .noProblem
      default:
        break
      }
    }
    var next = episodes
    next.reconcile(
      readiness: readiness, configuration: inputs.configuration, eligible: eligible)
    if next != episodes {
      episodes = next
      onEpisodeChange?()
    }
    return inputs
  }
}

/// The AI polish setup warnings' app-lifetime owners, held by the composition root as one
/// slot: the saved-key record, the warning monitor, and the card after a dictation.
@MainActor
final class PolishSetupWiring {
  let savedKeyPresence: SavedKeyPresence
  let monitor: PolishSetupMonitor
  let card: PolishSetupCardPresenter

  init(
    savedKeyPresence: SavedKeyPresence, monitor: PolishSetupMonitor,
    card: PolishSetupCardPresenter
  ) {
    self.savedKeyPresence = savedKeyPresence
    self.monitor = monitor
    self.card = card
  }
}

/// Late binding for the settings change hook, which is installed before the monitor exists.
@MainActor
final class PolishSetupMonitorHolder {
  weak var monitor: PolishSetupMonitor?
}

/// The one off-page Ollama probe on app activation (#3438), owned by `SetupCoordinator` so the
/// visible-page watch and this probe never both run.
@MainActor
struct OllamaOffPageRefresh {
  let requestOnce: @MainActor () -> Void
  let cancel: @MainActor () -> Void
}

extension PolishSetupInputs {
  /// The inputs composed from the live app-level owners, for DICTATION's chosen model: the
  /// import's provider, an unsaved editor draft and another provider's verdict never count.
  @MainActor
  static func live(
    settings: SettingsManager, localPolishRuntimes: LocalPolishRuntimeSet,
    aiAvailability: AIAvailabilityCoordinator, setup: SetupCoordinator,
    llmDiscovery: LLMModelDiscoveryCoordinator, savedKeyPresence: SavedKeyPresence
  ) -> PolishSetupInputs {
    let provider = settings.llmProvider
    let revision: UInt64?
    switch provider {
    case .openAI, .gemini, .claude: revision = savedKeyPresence.revision(for: provider)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none: revision = nil
    }
    return PolishSetupInputs(
      onboardingComplete: settings.onboardingState == .completed,
      configuration: PolishSetupConfiguration(
        provider: provider, model: settings.effectiveLLMModel, credentialRevision: revision),
      facts: .live(
        localPolishRuntimes: localPolishRuntimes, aiAvailability: aiAvailability, setup: setup,
        validationProvider: llmDiscovery.stateProvider,
        cloudValidation: llmDiscovery.keyValidationState,
        openAIKeySaved: savedKeyPresence.savedFlag(for: .openAI),
        geminiKeySaved: savedKeyPresence.savedFlag(for: .gemini),
        claudeKeySaved: savedKeyPresence.savedFlag(for: .claude),
        savedKeyPresence: savedKeyPresence,
        cloudVerdict: llmDiscovery.cloudVerdict,
        ollamaModel: settings.ollamaModel),
      ollamaLastCommitAt: setup.ollamaSetup.lastCommitAt)
  }
}
