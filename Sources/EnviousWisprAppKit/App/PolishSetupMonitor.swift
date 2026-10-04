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

  /// The card was actually presented. Spends it only for the current episode and generation;
  /// a duplicate or stale receipt does nothing.
  mutating func cardPresented(_ ticket: PolishSetupCardTicket) {
    guard ticket.generation == generation, episode?.token == ticket.episode, shows(.card)
    else { return }
    episode?.cardSpent = true
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
    (revision: UInt64, problem: PolishSetupProblem, observedAt: ContinuousClock.Instant)?

  init(
    readInputs: @escaping @MainActor () -> PolishSetupInputs,
    ollamaRefresh: OllamaOffPageRefresh? = nil
  ) {
    self.readInputs = readInputs
    self.ollamaRefresh = ollamaRefresh
  }

  // MARK: - What surfaces read

  var eligibleProblem: PolishSetupProblem? { episodes.eligibleProblem }

  func shows(_ surface: PolishSetupSurface) -> Bool { episodes.shows(surface) }

  /// The episode a surface is showing now, for it to hand back with the person's answer.
  var currentEpisode: PolishSetupEpisodeToken? { episodes.episode?.token }

  /// The person answered a surface that was showing `token`'s episode. An answer about an
  /// episode that has since ended changes nothing.
  func acknowledge(_ surface: PolishSetupSurface, in token: PolishSetupEpisodeToken) {
    reconcile()
    episodes.acknowledge(surface, in: token)
  }

  func cardTicket() -> PolishSetupCardTicket? {
    reconcile()
    return episodes.cardTicket()
  }

  /// The card really appeared. Judged against the live state, not the last observed one.
  func cardPresented(_ ticket: PolishSetupCardTicket) {
    reconcile()
    episodes.cardPresented(ticket)
  }

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

  // MARK: - Ollama ordering

  /// A take that started under `context` observed Ollama at `observedAt` (chunk 4: stamped
  /// by the producer when it observed, never at delivery). Ignored unless the configuration
  /// is still the one the take started under, and unless it is newer than the observation
  /// already recorded.
  func recordOllamaTakeObservation(
    _ problem: PolishSetupProblem, context: PolishSetupContext,
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
      readiness = .problem(take.problem)
    }
    var next = episodes
    next.reconcile(
      readiness: readiness, configuration: inputs.configuration, eligible: eligible)
    if next != episodes { episodes = next }
    return inputs
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
