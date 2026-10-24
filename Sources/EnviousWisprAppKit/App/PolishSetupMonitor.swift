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

/// Permission to present one earned outside-stop notice (#3988): the stop it is about, the
/// configuration revision the take ran under, which offer of that stop it belongs to, and which
/// notice it is (first, or the repeat within a day), decided when it was offered. Asking for
/// one spends nothing.
struct OutsideStopNoticeTicket: Hashable {
  let stop: OutsideStopContext
  let configurationRevision: UInt64
  /// The take that owns this offer: only it may present it, and only its row reports it.
  let takeID: String
  /// Moves whenever a newer take re-earns the stop, so an older ticket never matches it.
  let offer: Int
  let variant: PolishSetupCardModel.NoticeVariant
}

/// Where the outside-stop notice policy keeps what must survive a relaunch (#3988): when each
/// engine's first notice last appeared, and the end of the 24-hour quiet after a repeat notice.
/// The APP's own defaults domain, never the unified settings suite: this is per-build memory
/// (like `accessibilityWarningDismissed`), so the dev build and the shipped app never share it.
/// Nil defaults keep it in memory, for tests that do not exercise a relaunch.
@MainActor
final class OutsideStopNoticeStore {
  private let defaults: UserDefaults?
  private var memory: [String: Date] = [:]

  static let keyPrefix = "outsideStopNotice."
  static let muteUntilKey = keyPrefix + "muteUntil"
  static func firstShownKey(_ provider: LLMProvider) -> String {
    keyPrefix + "firstShownAt." + provider.rawValue
  }

  init(defaults: UserDefaults?) { self.defaults = defaults }

  func date(_ key: String) -> Date? {
    guard let defaults else { return memory[key] }
    return defaults.object(forKey: key) as? Date
  }

  func set(_ date: Date?, for key: String) {
    guard let defaults else {
      memory[key] = date
      return
    }
    if let date { defaults.set(date, forKey: key) } else { defaults.removeObject(forKey: key) }
  }
}

/// Outside-stop notices earned by takes (#3988), keyed by engine and stopped child, and kept
/// apart from the setup episodes: the engine coming back ends the live recovery, never a notice
/// a take already earned. A value, so its rules are tested without an app.
struct OutsideStopNotices: Equatable {
  struct Key: Hashable {
    let provider: LLMProvider
    let generation: Int
  }
  struct Earned: Equatable {
    let key: Key
    var stop: OutsideStopContext
    var configurationRevision: UInt64
    /// When the take missed polish, stamped at the miss on the wall clock.
    var missedAt: Date
    /// The take that owns the current offer, and every take that owned an earlier one: a
    /// former owner can never take the stop back, however late it is delivered again.
    var owner: String
    var formerOwners: Set<String> = []
    /// Which offer this is; a newer take re-earning the stop moves it.
    var offer: Int
    var presented = false
    /// Refused by the 24-hour quiet. Final for this offer: only a NEW take missing polish for
    /// this stop makes a new offer, never the clock.
    var suppressed = false
  }

  /// Kept for the app's lifetime, never trimmed by age or count: an entry may hold a notice
  /// still waiting to show, and a spent one is what stops its stop being told twice. One entry
  /// per physical stop, so it grows only as often as something stops the engine.
  private(set) var earned: [Earned] = []

  /// The take `takeID` missed polish because of `stop` at `missedAt`, under
  /// `configurationRevision`. The first take per stop earns. A notice already presented is never
  /// earned again. A NEWER take that misses for an unshown stop makes a new offer it owns, with
  /// its own frozen stop, revision and miss time; any earlier offer (refused by the overlay, by
  /// the quiet, or another configuration's) is then dead. This is safe because a recording
  /// starting clears any card still on screen or pending, so no earlier ticket is in flight.
  /// The current owner or a former one re-delivered changes nothing.
  @discardableResult
  mutating func earn(
    _ stop: OutsideStopContext, configurationRevision: UInt64, missedAt: Date, takeID: String
  ) -> Bool {
    let key = Key(provider: stop.provider, generation: stop.generation)
    guard let index = earned.firstIndex(where: { $0.key == key }) else {
      earned.append(
        Earned(
          key: key, stop: stop, configurationRevision: configurationRevision, missedAt: missedAt,
          owner: takeID, offer: 1))
      return true
    }
    guard !earned[index].presented, earned[index].owner != takeID,
      !earned[index].formerOwners.contains(takeID)
    else { return false }
    earned[index].formerOwners.insert(earned[index].owner)
    earned[index].owner = takeID
    earned[index].stop = stop
    earned[index].configurationRevision = configurationRevision
    earned[index].missedAt = missedAt
    earned[index].offer += 1
    earned[index].suppressed = false
    return true
  }

  /// The quiet refused the offer `takeID` owns. Anyone else's offer is untouched.
  mutating func suppress(_ stop: OutsideStopContext, ownedBy takeID: String) {
    let key = Key(provider: stop.provider, generation: stop.generation)
    guard let index = earned.firstIndex(where: { $0.key == key }), !earned[index].presented,
      earned[index].owner == takeID
    else { return }
    earned[index].suppressed = true
  }

  /// A quiet started: every offer still waiting, but `initiator`'s, is refused for good.
  mutating func suppressAll(except initiator: Key) {
    for index in earned.indices where earned[index].key != initiator && !earned[index].presented {
      earned[index].suppressed = true
    }
  }

  /// The usable offer for `stop` owned by `takeID`: unpresented and not refused.
  func pending(for stop: OutsideStopContext, ownedBy takeID: String) -> Earned? {
    let key = Key(provider: stop.provider, generation: stop.generation)
    guard let notice = earned.first(where: { $0.key == key }), notice.owner == takeID,
      !notice.presented, !notice.suppressed
    else { return nil }
    return notice
  }

  /// A ticket for the usable offer `takeID` owns for `stop`, as `variant`.
  func ticket(
    for stop: OutsideStopContext, ownedBy takeID: String,
    variant: PolishSetupCardModel.NoticeVariant = .first
  ) -> OutsideStopNoticeTicket? {
    pending(for: stop, ownedBy: takeID).map {
      OutsideStopNoticeTicket(
        stop: $0.stop, configurationRevision: $0.configurationRevision, takeID: $0.owner,
        offer: $0.offer, variant: variant)
    }
  }

  /// The notice actually appeared: spends it once. Only a ticket for the CURRENT, unrefused offer
  /// (same stop and context, revision and offer) spends it; a duplicate, refused, superseded or
  /// unknown receipt answers false.
  @discardableResult
  mutating func presented(_ ticket: OutsideStopNoticeTicket) -> Bool {
    let key = Key(provider: ticket.stop.provider, generation: ticket.stop.generation)
    guard let index = earned.firstIndex(where: { $0.key == key }), !earned[index].presented,
      !earned[index].suppressed, earned[index].owner == ticket.takeID,
      earned[index].offer == ticket.offer, earned[index].stop == ticket.stop,
      earned[index].configurationRevision == ticket.configurationRevision
    else { return false }
    earned[index].presented = true
    return true
  }
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
      // #3988: an outside stop is told once after the take it cost, never on leaving.
      if case .localEngineStoppedOutside = problem { return false }
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
  /// Told of every accepted take Apple Intelligence polished (#3897), with no readiness filter:
  /// `AIAvailabilityCoordinator` decides whether its stored report needs a re-check.
  @ObservationIgnored private let appleRefresh: (@MainActor () -> Void)?
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
  /// #3988: what an outside-stop notice's applicability reads, so a change to it reaches the
  /// card owner in the same turn even when no setup episode moved.
  private struct NoticeApplicability: Equatable {
    let configurationRevision: UInt64
    let onboardingComplete: Bool
    let provider: LLMProvider
    let restartFailed: Bool
  }
  @ObservationIgnored private var lastNoticeApplicability: NoticeApplicability?
  /// What takes said about the Ollama SERVER (not installed, not running, or running: any take
  /// that polished), and about each MODEL (missing or none chosen, or working), with WHEN they
  /// observed it. Kept apart because one server serves many models: a success with model B
  /// says the server runs, never that model A is installed. Each is believed only when newer
  /// than the service's own last commit; kept across configuration changes.
  @ObservationIgnored private var ollamaServerObservation:
    (problem: PolishSetupProblem?, observedAt: ContinuousClock.Instant)?
  @ObservationIgnored private var ollamaModelObservations:
    [String: (problem: PolishSetupProblem?, observedAt: ContinuousClock.Instant)] = [:]
  /// The newest thing a take said about each saved cloud key: rejected by the provider, or
  /// accepted (a take that polished). One per PROVIDER, each a fact about that key (its
  /// credential revision): it survives model and provider changes and another provider's
  /// takes, and stops counting when that key is replaced or cleared.
  /// #3988: outside-stop notices earned by takes, independent of the episodes.
  @ObservationIgnored private(set) var outsideStopNotices = OutsideStopNotices()
  /// #3988: the notice policy's persisted history and its wall clock. Policy compares only
  /// wall-clock dates: stored ones, now, and each take's miss time stamped at the miss.
  @ObservationIgnored private let noticeStore: OutsideStopNoticeStore
  @ObservationIgnored private let wallNow: @MainActor () -> Date
  /// The repeat notice whose presentation started the current quiet; it stays usable inside it.
  @ObservationIgnored private var muteInitiator: OutsideStopNotices.Key?
  @ObservationIgnored private var cloudKeyTakeObservations:
    [LLMProvider: (credentialRevision: UInt64, rejected: Bool, observedAt: ContinuousClock.Instant)] =
      [:]

  init(
    readInputs: @escaping @MainActor () -> PolishSetupInputs,
    ollamaRefresh: OllamaOffPageRefresh? = nil,
    appleRefresh: (@MainActor () -> Void)? = nil,
    reportPrompt: @escaping @MainActor (PolishSetupPromptEvent) -> Void = { $0.send() },
    recordKeyEvidence: @escaping @MainActor (LLMProvider, SavedKeyState, ContinuousClock.Instant)
      -> Void = { _, _, _ in },
    noticeStore: OutsideStopNoticeStore = OutsideStopNoticeStore(defaults: nil),
    wallNow: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.readInputs = readInputs
    self.ollamaRefresh = ollamaRefresh
    self.appleRefresh = appleRefresh
    self.reportPrompt = reportPrompt
    self.recordKeyEvidence = recordKeyEvidence
    self.noticeStore = noticeStore
    self.wallNow = wallNow
  }

  // MARK: - What surfaces read

  var eligibleProblem: PolishSetupProblem? { episodes.eligibleProblem }

  func shows(_ surface: PolishSetupSurface) -> Bool { episodes.shows(surface) }

  /// Whether `provider` would be fully set up if chosen now, from the same live facts. For the
  /// leave dialog's "Go back to" offer; it changes no warning memory.
  func readiness(for provider: LLMProvider) -> PolishSetupReadiness {
    let inputs = readInputs()
    // The same evidence and freshness rules as the warnings themselves: a key or a server a
    // dictation proved broken is not offered as a way back. The model of a provider that is not
    // the chosen one is not known here, so only server-level Ollama answers apply to it.
    let model =
      provider == inputs.configuration.provider ? inputs.configuration.model : nil
    return withTakeObservations(
      PolishSetupReadiness.evaluate(provider: provider, facts: inputs.facts),
      provider: provider, model: model, inputs: inputs)
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
    subject: PolishSetupPromptSubject, takeID: UUID? = nil,
    variant: PolishSetupCardModel.NoticeVariant? = nil
  ) {
    reportPrompt(
      PolishSetupPromptEvent(
        surface: surface, action: action, subject: subject, takeID: takeID, variant: variant))
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
        .localEngineDownloading, .localEngineVerifying, .appleUnavailable, .appleModelNotReady,
        .localEngineStoppedOutside:
        // Downloading, verifying, stopped from outside (#3988: told by its own notice, never a
        // setup problem) or another engine's state: not this take's setup problem.
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
    let outsideStop = Self.outsideStopMissed(outcome)
    // #3988: the engine coming back ends the stopped-outside episode the take started in; that
    // must not reject the take whose notice it earned.
    if outsideStop == nil, let episode = take.episode,
      episodes.episode?.token.rawValue != episode
    {
      return false
    }
    ingestedTakeIDs.append(outcome.takeID)
    if ingestedTakeIDs.count > 16 { ingestedTakeIDs.removeFirst() }
    if let outsideStop, let missedAt = outcome.outsideStopMissedAt {
      outsideStopNotices.earn(
        outsideStop, configurationRevision: take.configurationRevision, missedAt: missedAt,
        takeID: outcome.takeID)
      // Missed inside the quiet: refused now, not when someone asks.
      if isMuted(except: nil) { outsideStopNotices.suppress(outsideStop, ownedBy: outcome.takeID) }
    }

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
    if take.provider == .appleIntelligence, polished { appleRefresh?() }
    return true
  }

  /// `readiness` for `provider`, with what dictations learned about its saved key applied when
  /// that is the newest answer about THAT key (same provider and credential revision, newer
  /// than the key check's verdict). Used by the warnings and by every other readiness question
  /// (the leave dialog's way back), so the two can never disagree.
  private func withTakeObservations(
    _ readiness: PolishSetupReadiness, provider: LLMProvider, model: String?,
    inputs: PolishSetupInputs
  ) -> PolishSetupReadiness {
    let afterOllama = withOllamaTakeObservation(
      readiness, provider: provider, model: model, lastCommitAt: inputs.ollamaLastCommitAt)
    return withCloudTakeObservation(afterOllama, provider: provider, facts: inputs.facts)
  }

  /// `readiness` for Ollama with the newest take answer applied when it is newer than the
  /// service's last commit. A server-level answer (not running, not installed) holds for any
  /// model; a model-level one (model missing, none chosen) and a success hold for the model
  /// the take asked for. A success with ANOTHER model proves only that the server runs, so a
  /// stale "not running" from the service becomes unknown rather than ready.
  private func withOllamaTakeObservation(
    _ readiness: PolishSetupReadiness, provider: LLMProvider, model: String?,
    lastCommitAt: ContinuousClock.Instant?
  ) -> PolishSetupReadiness {
    guard provider == .ollama else { return readiness }
    func newer(_ at: ContinuousClock.Instant) -> Bool { lastCommitAt.map { $0 < at } ?? true }
    var result = readiness
    if let server = ollamaServerObservation, newer(server.observedAt) {
      if let problem = server.problem { return .problem(problem) }
      // The server runs: a stale "not running" or "not installed" no longer holds.
      switch result {
      case .problem(.ollamaNotRunning), .problem(.ollamaNotInstalled): result = .unknown
      default: break
      }
    }
    guard let model else {
      // The model a way back would select is not known here: unresolved model evidence makes
      // the answer unknown rather than ready.
      let unresolved = ollamaModelObservations.values.contains {
        $0.problem != nil && newer($0.observedAt)
      }
      if unresolved, result == .noProblem { return .unknown }
      return result
    }
    if let seen = ollamaModelObservations[model], newer(seen.observedAt) {
      return seen.problem.map { .problem($0) } ?? .noProblem
    }
    return result
  }

  private func withCloudTakeObservation(
    _ readiness: PolishSetupReadiness, provider: LLMProvider, facts: PolishSetupFacts
  ) -> PolishSetupReadiness {
    guard Self.usesCloudKey(provider), let take = cloudKeyTakeObservations[provider],
      take.credentialRevision == facts.credentialRevisions[provider],
      Self.cloudVerdictAt(facts, provider: provider).map({ $0 < take.observedAt }) ?? true
    else { return readiness }
    switch (take.rejected, readiness) {
    case (true, .noProblem), (true, .unknown):
      // The provider rejected this key during a dictation (no Settings visit needed).
      return .problem(.cloudKeyRejected(provider))
    case (false, .problem(.cloudKeyRejected(provider))):
      // A dictation polished with this key after the check rejected it.
      return .noProblem
    default:
      return readiness
    }
  }

  /// When the key check answered (accepted or rejected) about the key saved now; nil when it
  /// has not, or answered about an older key.
  private static func cloudVerdictAt(
    _ facts: PolishSetupFacts, provider: LLMProvider
  ) -> ContinuousClock.Instant? {
    // The last DEFINITIVE answer about the key saved now, whether this verdict is that answer
    // or a running/inconclusive check carrying it.
    guard let verdict = facts.cloudVerdicts[provider], verdict.provider == provider,
      verdict.credentialRevision == facts.credentialRevisions[provider]
    else { return nil }
    return verdict.lastDefinitive?.decidedAt
  }


  /// Newer wins, for the same saved key only; a different key replaces it outright.
  private func recordCloudKeyTakeObservation(
    rejected: Bool, configuration: PolishSetupConfiguration, observedAt: ContinuousClock.Instant
  ) {
    guard let credentialRevision = configuration.credentialRevision else { return }
    if let current = cloudKeyTakeObservations[configuration.provider],
      current.credentialRevision == credentialRevision, current.observedAt >= observedAt
    {
      return
    }
    cloudKeyTakeObservations[configuration.provider] = (credentialRevision, rejected, observedAt)
    reconcile()
  }

  // MARK: - Outside-stop notices (#3988)

  /// The stop a concluded take missed polish because of, or nil. Only the frozen miss evidence
  /// of a bundled engine's not-ready skip counts: recovery attribution alone, a polished take
  /// and a bypass never do, and the stop must be the take's own engine's.
  static func outsideStopMissed(_ outcome: PolishTakeOutcome) -> OutsideStopContext? {
    guard let stop = outcome.outsideStopMiss, outcome.outsideStopMissedAt != nil,
      outcome.evidence == .localEngineNotReady, stop.provider == outcome.context.provider
    else { return nil }
    switch stop.provider {
    case .egOne, .s1Mini: break
    case .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none: return nil
    }
    switch outcome.result {
    case .skippedSilently, .skippedWithNotice, .failed: return stop
    case .notRequested, .polished, .bypassed, .cancelled: return nil
    }
  }

  /// A ticket to present `outcome`'s notice now, or nil when it may not show: not earned,
  /// already presented, onboarding not finished, another configuration, the restart failed
  /// (its own red status takes over), or the 24-hour quiet is on. Asking spends nothing.
  /// Which notice it is gets decided here, from when the take missed polish.
  func outsideStopNoticeTicket(for outcome: PolishTakeOutcome) -> OutsideStopNoticeTicket? {
    let inputs = reconcile()
    guard let stop = Self.outsideStopMissed(outcome),
      let earned = outsideStopNotices.pending(for: stop, ownedBy: outcome.takeID),
      let ticket = outsideStopNotices.ticket(
        for: stop, ownedBy: outcome.takeID, variant: noticeVariant(for: earned)),
      outsideStopNoticeApplies(ticket, inputs: inputs)
    else { return nil }
    if isMuted(except: nil) {
      // Not queued for after the quiet: a later miss is judged afresh.
      outsideStopNotices.suppress(stop, ownedBy: outcome.takeID)
      return nil
    }
    return ticket
  }

  /// The notice really appeared: spends it once, judged against the live state. False for a
  /// stale, duplicate, muted or no-longer-applicable receipt, and the caller withdraws it. Only
  /// here is history written: a first notice starts its engine's day, a repeat starts the quiet.
  @discardableResult
  func outsideStopNoticePresented(_ ticket: OutsideStopNoticeTicket) -> Bool {
    let inputs = reconcile()
    guard outsideStopNoticeApplies(ticket, inputs: inputs) else { return false }
    if isMuted(except: nil) {
      // Drawn inside the quiet: refused for good, this offer never comes back after it. Only
      // if it is still this ticket's offer: a stale callback never touches a newer take's.
      if outsideStopNotices.ticket(for: ticket.stop, ownedBy: ticket.takeID)?.offer == ticket.offer {
        outsideStopNotices.suppress(ticket.stop, ownedBy: ticket.takeID)
      }
      return false
    }
    guard outsideStopNotices.presented(ticket) else { return false }
    let now = wallNow()
    switch ticket.variant {
    case .first:
      noticeStore.set(now, for: OutsideStopNoticeStore.firstShownKey(ticket.stop.provider))
    case .escalated:
      noticeStore.set(now.addingTimeInterval(Self.quiet), for: OutsideStopNoticeStore.muteUntilKey)
      let initiator = OutsideStopNotices.Key(
        provider: ticket.stop.provider, generation: ticket.stop.generation)
      muteInitiator = initiator
      // Every other offer still waiting (a pending card, a take not yet offered) is refused.
      outsideStopNotices.suppressAll(except: initiator)
    }
    return true
  }

  /// Whether a notice raised under `ticket` still describes the present. The engine being
  /// ready again does not end it; a configuration change, onboarding reset, failed restart or
  /// another notice's quiet does. The repeat notice that started the quiet stays usable in it.
  func outsideStopNoticeStillApplies(_ ticket: OutsideStopNoticeTicket) -> Bool {
    let key = OutsideStopNotices.Key(
      provider: ticket.stop.provider, generation: ticket.stop.generation)
    return outsideStopNoticeApplies(ticket, inputs: reconcile()) && !isMuted(except: key)
  }

  /// The 24-hour window and quiet (#3988, founder 2026-10-23).
  static let quiet: TimeInterval = 24 * 60 * 60

  /// A repeat within a day of the last first notice SHOWN for this engine, timed by when the
  /// take missed polish: elapsed in [0, 24 h). Before the first notice, or a day or more after,
  /// it is a first notice again. Every unshown entry is a different stop from any shown one,
  /// because a stop's notice is never earned twice.
  private func noticeVariant(
    for earned: OutsideStopNotices.Earned
  ) -> PolishSetupCardModel.NoticeVariant {
    guard
      let shown = noticeStore.date(OutsideStopNoticeStore.firstShownKey(earned.stop.provider))
    else { return .first }
    let elapsed = earned.missedAt.timeIntervalSince(shown)
    return elapsed >= 0 && elapsed < Self.quiet ? .escalated : .first
  }

  /// Whether the 24-hour quiet is on, for any notice but `initiator`'s. A deadline further
  /// out than a day from now (the clock was set back) is cut to a day from now and saved so,
  /// so reading it again can never push it out. A clock set forward by hand may end it early:
  /// an accepted limit (plan §3.3b).
  private func isMuted(except initiator: OutsideStopNotices.Key?) -> Bool {
    guard let deadline = noticeStore.date(OutsideStopNoticeStore.muteUntilKey) else {
      return false
    }
    let now = wallNow()
    let bounded = min(deadline, now.addingTimeInterval(Self.quiet))
    if bounded != deadline { noticeStore.set(bounded, for: OutsideStopNoticeStore.muteUntilKey) }
    guard bounded > now else { return false }
    return initiator == nil || initiator != muteInitiator
  }

  private func outsideStopNoticeApplies(
    _ ticket: OutsideStopNoticeTicket, inputs: PolishSetupInputs
  ) -> Bool {
    inputs.onboardingComplete
      && ticket.configurationRevision == configurationRevision
      && inputs.configuration.provider == ticket.stop.provider
      && !inputs.facts.localRestartFailed(ticket.stop.provider)
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
      .localUpdatePaused, .localDownloadFailed, .localStoppedOutside:
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
    let model = context.configuration.model
    switch problem {
    case .ollamaNotRunning?, .ollamaNotInstalled?:
      recordOllamaServer(problem, at: observedAt)
    case nil:
      // A polished take: the server runs AND this model works.
      recordOllamaServer(nil, at: observedAt)
      recordOllamaModel(model, nil, at: observedAt)
    case .some(let modelProblem):
      // Reaching the model check means the server answered.
      recordOllamaServer(nil, at: observedAt)
      recordOllamaModel(model, modelProblem, at: observedAt)
    }
    reconcile()
  }

  private func recordOllamaServer(_ problem: PolishSetupProblem?, at observedAt: ContinuousClock.Instant) {
    if let current = ollamaServerObservation, current.observedAt >= observedAt { return }
    ollamaServerObservation = (problem, observedAt)
  }

  private func recordOllamaModel(
    _ model: String, _ problem: PolishSetupProblem?, at observedAt: ContinuousClock.Instant
  ) {
    if let current = ollamaModelObservations[model], current.observedAt >= observedAt { return }
    ollamaModelObservations[model] = (problem, observedAt)
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
      // A refresh asked for the previous configuration answers a question nobody asks now.
      ollamaRefresh?.cancel()
    }
    if lastEligible, !eligible { ollamaRefresh?.cancel() }
    lastEligible = eligible

    let readiness = withTakeObservations(
      PolishSetupReadiness.evaluate(provider: inputs.configuration.provider, facts: inputs.facts),
      provider: inputs.configuration.provider, model: inputs.configuration.model, inputs: inputs)
    var next = episodes
    next.reconcile(
      readiness: readiness, configuration: inputs.configuration, eligible: eligible)
    let applicability = NoticeApplicability(
      configurationRevision: configurationRevision,
      onboardingComplete: inputs.onboardingComplete, provider: inputs.configuration.provider,
      restartFailed: inputs.facts.localRestartFailed(inputs.configuration.provider))
    let noticeChanged = applicability != lastNoticeApplicability
    lastNoticeApplicability = applicability
    let episodeChanged = next != episodes
    if episodeChanged { episodes = next }
    if episodeChanged || noticeChanged { onEpisodeChange?() }
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
        cloudVerdicts: llmDiscovery.cloudVerdicts,
        ollamaModel: settings.ollamaModel),
      ollamaLastCommitAt: setup.ollamaSetup.lastCommitAt)
  }
}
