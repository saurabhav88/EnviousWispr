import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Observation

// MARK: - Correction proposal coordinator (#996 §3.1 steps 8–10)
//
// The inbox. The only writer of the proposal ledger on this path and the only
// caller of `CustomWordSaveHelper` for it; the overlay card (5f) and the
// Pending tab (5g) are its two readers and both resolve through `resolve`.
// Every dependency arrives as a value or a seam, so the status × write-failure
// matrix below runs under test with a temporary ledger and a scripted word
// list, never the founder's data.
//
// Status × event (the store enforces the ledger's own invariants; this type
// enforces the transitions):
//
//   status     | event                       | result
//   -----------|-----------------------------|-------------------------------------------
//   (none)     | propose, pair rejected      | refused, nothing written
//   (none)     | propose, pair open          | refreshOpen: metadata only (typed outcome)
//   (none)     | propose, new pair           | pending persisted → learn_proposed → present
//   pending    | present, not yet attempted  | overlayAttempted persisted → ONE offer
//   pending    | present, already attempted  | nothing (never a second attempt)
//   pending    | admitted (first token)      | learn_card_shown; repeat token idempotent
//   pending    | ended: expired, unanswered  | learn_card_expired; still pending, no retry
//
// Presentation (in memory, this launch only; never rebuilt from the persisted
// `overlayAttempted`, so an offer made in an earlier launch counts nothing):
//
//   phase            | admitted(token)          | showResult      | ended(token, reason)  | resolved
//   -----------------|--------------------------|-----------------|-----------------------|----------
//   (no record)      | nothing                  | nothing         | nothing               | nothing
//   offered          | pending: → admitted,     | nothing         | nothing (token        | → ended
//                    |   card_shown; else → ended|                |   unknown)            |
//   admitted(t)      | same t: nothing;         | morph card;     | t: → ended; card_expired| unchanged
//                    |   other token: nothing   |   result shown  |   iff expired AND no result|
//   ended            | nothing                  | nothing         | nothing               | nothing
//
// Admission is consumed once per offer and only while the proposal is still
// pending; a terminal resolution (accept, reject, reconcile) closes an offer
// that was never admitted, so a delayed admission cannot revive it. A result
// card timing out is not an unanswered offer, whatever the proposal's status
// (a refusal leaves it pending, an accept does not).
//   pending    | accept                      | intent + accepting persisted → revalidate →
//              |                             |   write → accepted persisted
//   pending    | reject                      | tombstone + rejected in ONE replacement
//   accepting  | accept / reject (in flight) | coalesced: in progress, no second write
//   accepting  | accept / reject (persisted  | reconcile first: landed → accepted; missing
//              |   intent from a prior try)  |   → pending then the click proceeds;
//              |                             |   unreadable → in progress
//   accepting  | reconcile at initialize     | same three answers
//   accepted   | anything                    | no-op (admission and expiry count nothing)
//   rejected   | anything                    | no-op
//   any        | ledger untrusted / recovery | mutations refused; a recovery obligation is
//              |                             |   retried by one trusted re-load at the next
//              |                             |   resolve; reported once per launch
//
// Failure × stage (accept): intent write fails → pending, nothing written;
// revalidation refuses → pending persisted, save_failed{reason}; vocabulary
// write refused → pending persisted, save_failed{vocabulary_write_failed};
// vocabulary landed but the accepted write fails → stays ACCEPTING with the
// intent (the write is not undone), save_failed{ledger_write_failed}, a later
// reconcile completes it; the presentation token is checked before any of it;
// every refusal morphs the still-current card into its typed result.

/// The typed result the card morphs into (plan §3.1 step 9); the overlay owns
/// the sentences (`CorrectionProposalCardCopy.result`), so this type carries no
/// prose and the two cannot drift apart.
enum CorrectionCardResult: Equatable, Sendable {
  case saved
  case wontAskAgain
  case alreadyInYourWords
  case couldNotSave
  case savedButNotRecorded
}

/// The card the overlay draws (5f). App-local; the reducer owns the
/// presentation identity separately.
/// The two Accept outcomes as the card names them. `existingWord` carries the
/// canonical the sound-alike joins, read at offer time; Accept re-resolves it.
enum CorrectionCardState: Equatable, Sendable {
  case existingWord(name: String)
  case newWord
}

struct CorrectionProposalCardModel: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case offer
    case result(CorrectionCardResult)
  }
  let id: UUID
  let pairKey: String
  let original: String
  let corrected: String
  /// Which of the two Accept outcomes this card offers (founder's mock, 19 Sep):
  /// the overlay writes the state line and the result sentence from it.
  let state: CorrectionCardState
  let phase: Phase
}

/// One admission of a card. Minted by the overlay when it actually shows the
/// card; a resolution that names a token the coordinator no longer holds as
/// current is a stale click and is ignored.
struct CorrectionPresentationToken: Equatable, Hashable, Sendable {
  let id: UUID
  init(id: UUID = UUID()) { self.id = id }
}

/// What the overlay (5f) conforms to. The coordinator makes at most ONE
/// `offer` per proposal for the record's life; admission, expiry and
/// preemption are reported back through the coordinator's own methods.
@MainActor
protocol CorrectionProposalPresenting: AnyObject {
  /// Ask the overlay to show the card. Admission is NOT implied; the overlay
  /// calls `presentationAdmitted` when the card is on screen.
  func offer(_ model: CorrectionProposalCardModel)
  /// Morph the currently shown card into its typed result (the 3 s result
  /// phase); a no-op when that presentation is no longer on screen.
  func showResult(_ model: CorrectionProposalCardModel, presentation: CorrectionPresentationToken)
}

/// How a presentation left the screen without a decision: its dwell fired, or
/// the pipeline took the slot. The card has no keyboard dismiss (it never takes
/// focus), so there is no third reason.
enum CorrectionPresentationEnd: String, Sendable, Equatable {
  case expired
  case preempted
}

enum CorrectionProposalDecision: Sendable, Equatable {
  case accept
  case reject
}

/// A trustworthy read of the live word list, or the fact that none is
/// available. `unreadable` is never spent as "empty".
enum CorrectionWordListRead: Sendable, Equatable {
  case fresh([CustomWord])
  case unreadable
}

/// The vocabulary the coordinator reads and the one door it writes through.
@MainActor
struct CorrectionVocabularyAccess {
  /// Current in-memory user words (values).
  let userWords: () -> [CustomWord]
  /// Terms of the ENABLED packs only.
  let packTerms: () -> [CustomWord]
  /// Re-read from disk for reconciliation; distinguishes an unreadable library
  /// (or one that was corrupt at launch or during the session) from an empty one.
  let refreshTrustworthy: () -> CorrectionWordListRead
  /// `CustomWordSaveHelper.saveAndConfirm` in production: nil means landed.
  let save: (CustomWord, String) -> String?
  /// `WordSuggestionService.classifyByHeuristic` in production.
  let classify: (String) -> WordCategory?
}

/// Telemetry the coordinator and watcher emit, typed exactly like the nine
/// `TelemetryService.learn*` emitters so a test spy records the same shape.
@MainActor
protocol LearnFromEditsTelemetrySink: AnyObject {
  typealias T = TelemetryService.LearnFromEditsTelemetry
  func learnSkipped(reason: T.SkipReason)
  func learnObservationEnded(
    reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int)
  /// `queueWaitMs` nil = not measured by this arm (the wire row omits the key).
  func learnJudged(
    arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int,
    queueWaitMs: Int?)
  func learnProposed(state: T.TargetState)
  func learnCardShown()
  func learnCardExpired()
  func learnResolved(
    decision: T.Decision, surface: T.Surface, state: T.TargetState, outcome: T.ResolutionOutcome)
  func learnSaveFailed(reason: T.SaveFailure)
  func learnLedgerUntrusted(kind: T.LedgerUntrustedKind, disposition: T.LedgerDisposition)
}

@MainActor @Observable
final class CorrectionProposalCoordinator {

  enum LedgerState: Equatable {
    case notLoaded
    case ready
    case untrusted(CorrectionLedgerUntrustedKind)
  }

  enum ProposeOutcome: Equatable {
    case minted(UUID)
    case refreshed(UUID)
    case refusedRejectedPair
    case ledgerUnavailable
    case writeFailed
  }

  enum RefreshOutcome: Equatable {
    case refreshed
    case notOpen
    case writeFailed
  }

  enum ResolveOutcome: Equatable {
    case accepted(TelemetryService.LearnFromEditsTelemetry.ResolutionOutcome)
    case rejected
    /// A pending proposal was refused for the named reason and is pending again.
    case refused(TelemetryService.LearnFromEditsTelemetry.SaveFailure)
    /// The vocabulary write landed but the ledger could not record it; the
    /// proposal stays `accepting` with its intent for a later reconcile.
    case landedButUnrecorded
    case inProgress
    case alreadyResolved
    case unknownProposal
    case stalePresentation
    case ledgerUnavailable
  }

  enum ReconcileOutcome: Equatable {
    case completed
    case returnedToPending
    case unresolved
    case notAccepting
  }

  enum Surface: Sendable, Equatable {
    case card(CorrectionPresentationToken)
    case pending
  }

  private let store: CorrectionProposalStore
  private let vocabulary: CorrectionVocabularyAccess
  @ObservationIgnored private weak var presenter: (any CorrectionProposalPresenting)?
  private let telemetry: any LearnFromEditsTelemetrySink
  private let now: () -> Date
  private let makeID: () -> UUID

  private(set) var ledgerState: LedgerState = .notLoaded

  /// Observation instrumentation for the Pending tab (5g). The store is the
  /// one ledger source and its `ledger` is not an observed property, so a
  /// SwiftUI view reading `openProposalsNewestFirst` would never be told a
  /// write landed. Every computed ledger accessor reads this revision and
  /// every successful store write and every load bumps it; no second proposal
  /// array, cache or timer. A revision, not a copy: the list is still read
  /// from the store at the moment the view asks.
  private(set) var ledgerRevision: UInt64 = 0

  /// Set when this launch's load found a damaged file and started fresh
  /// (`CorrectionLedgerLoadOutcome.recovered`); the Pending tab shows the
  /// one banner for it. Same shape as `CustomWordsCoordinator
  /// .wordsLoadFailureAtLaunch`.
  private(set) var recoveredAtLaunch: CorrectionLedgerUntrustedKind?

  /// The life of one offer, tracked apart from the proposal's durable status.
  struct Presentation: Equatable {
    enum Phase: Equatable {
      case offered
      case admitted(CorrectionPresentationToken)
      case ended
    }
    var phase: Phase
    /// A typed result morphed the card; its later expiry is not an unanswered offer.
    var resultShown = false
    /// The proposal as it was offered: what the card on screen shows. Kept here
    /// so a click can still be answered on the card when the ledger has gone
    /// untrusted meanwhile and `proposal(id:)` reads nothing.
    let offered: CorrectionProposal
  }
  private(set) var presentations: [UUID: Presentation] = [:]
  /// The presentation the overlay says is on screen, per proposal.
  var currentPresentation: [UUID: CorrectionPresentationToken] {
    var out: [UUID: CorrectionPresentationToken] = [:]
    for (id, p) in presentations {
      if case .admitted(let token) = p.phase { out[id] = token }
    }
    return out
  }
  /// The untrusted ledger is reported once per launch.
  private var reportedUntrusted = false
  /// Proposals with a resolve in flight (reentrant clicks from a presenter
  /// callback coalesce).
  private var resolving: Set<UUID> = []

  init(
    store: CorrectionProposalStore,
    vocabulary: CorrectionVocabularyAccess,
    presenter: (any CorrectionProposalPresenting)?,
    telemetry: any LearnFromEditsTelemetrySink,
    now: @escaping () -> Date = { Date() },
    makeID: @escaping () -> UUID = { UUID() }
  ) {
    self.store = store
    self.vocabulary = vocabulary
    self.presenter = presenter
    self.telemetry = telemetry
    self.now = now
    self.makeID = makeID
  }

  /// Late binding for the overlay (constructed after the coordinator at the
  /// composition root).
  func attach(presenter: any CorrectionProposalPresenting) {
    self.presenter = presenter
  }

  // MARK: - Ledger

  /// Load (or re-load after a recovery obligation) and reconcile every
  /// `accepting` proposal. Untrusted storage disables this path: no proposal
  /// is minted or resolved until a trusted ledger is restored.
  func initialize() {
    defer { ledgerRevision &+= 1 }
    switch store.load() {
    case .empty, .trusted:
      ledgerState = .ready
      for proposal in store.ledger?.proposals ?? [] where proposal.status == .accepting {
        _ = reconcile(id: proposal.id)
      }
      // The 30-day policy (plan §3.1 step 5) has to be spent somewhere: resolved
      // payloads (the original and corrected text) leave here, once per launch.
      // Pending, accepting and tombstones are never pruned (store contract).
      do {
        _ = try store.prune(now: now())
      } catch {
        noteWriteFailure(error)
      }
    case .recovered(let kind, _):
      // A damaged file moved aside; the ledger is empty and trusted. The tab
      // says so once; the wire event keeps its name (the ledger WAS untrusted
      // at load) and is reported once per launch like before.
      ledgerState = .ready
      recoveredAtLaunch = kind
      if !reportedUntrusted {
        reportedUntrusted = true
        telemetry.learnLedgerUntrusted(kind: Self.wireKind(kind), disposition: .recovered)
      }
    case .untrusted(let kind, _):
      ledgerState = .untrusted(kind)
      if !reportedUntrusted {
        reportedUntrusted = true
        telemetry.learnLedgerUntrusted(kind: Self.wireKind(kind), disposition: .blocked)
      }
    }
  }

  var ledger: CorrectionProposalLedger? {
    _ = ledgerRevision
    return ledgerState == .ready ? store.ledger : nil
  }

  /// The two store writes, wrapped so a landed write always invalidates the
  /// observed accessors above; a thrown write leaves the revision alone and
  /// the caller's error path speaks for it.
  private func persistProposal(_ proposal: CorrectionProposal) throws {
    try store.upsert(proposal)
    ledgerRevision &+= 1
  }

  private func persistRejection(id: UUID, at time: Date) throws {
    try store.reject(id: id, at: time)
    ledgerRevision &+= 1
  }

  /// Open (`pending`/`accepting`) proposals by pair key, for the filter.
  var openProposalsByPairKey: [String: UUID] {
    var out: [String: UUID] = [:]
    for p in ledger?.openProposals ?? [] { out[p.pairKey] = p.id }
    return out
  }

  var rejectedPairKeys: Set<String> {
    Set(ledger?.rejectedPairs.map(\.pairKey) ?? [])
  }

  func proposal(id: UUID) -> CorrectionProposal? { ledger?.proposal(id: id) }

  /// Pending and accepting proposals, newest first (the Pending tab's list).
  var openProposalsNewestFirst: [CorrectionProposal] {
    (ledger?.openProposals ?? []).sorted { $0.createdAt > $1.createdAt }
  }

  // MARK: - Step 8: propose

  /// `refreshOpen`: the same pair seen again updates context, source app and
  /// `updatedAt` only. No re-judge, no second overlay attempt. A persistence
  /// failure is routed like every other write failure.
  @discardableResult
  func refresh(id: UUID, contextExcerpt: String?, sourceBundleID: String?) -> RefreshOutcome {
    guard ledgerState == .ready, var proposal = proposal(id: id), !proposal.status.isTerminal
    else { return .notOpen }
    proposal.refreshMetadata(
      contextExcerpt: contextExcerpt, sourceBundleID: sourceBundleID, at: now())
    do {
      try persistProposal(proposal)
    } catch {
      noteWriteFailure(error)
      return .writeFailed
    }
    return .refreshed
  }

  /// Mint one durable proposal for a judged correction, then make its single
  /// overlay attempt. The live ledger is re-checked first: a pair rejected or
  /// opened since the filter ran is not minted again.
  func propose(
    original: String, corrected: String, state: CorrectionProposalTargetState, language: String?,
    contextExcerpt: String?, sourceBundleID: String?, advisorySafeAlias: Bool?
  ) -> ProposeOutcome {
    let outcome = proposeRecording(
      original: original, corrected: corrected, state: state, language: language,
      contextExcerpt: contextExcerpt, sourceBundleID: sourceBundleID, advisorySafeAlias: advisorySafeAlias)
    #if DEBUG
      // Local debug log only (plan §11 UAT tokens): the pair itself, so a Live
      // UAT can read the verdict from app.log. Release logs no user text.
      Self.debugLog("proposed original=\"\(original)\" corrected=\"\(corrected)\" state=\(state) outcome=\(outcome)")
    #endif
    return outcome
  }

  private func proposeRecording(
    original: String, corrected: String, state: CorrectionProposalTargetState, language: String?,
    contextExcerpt: String?, sourceBundleID: String?, advisorySafeAlias: Bool?
  ) -> ProposeOutcome {
    guard ledgerState == .ready else { return .ledgerUnavailable }
    let pairKey = CorrectionPairKey.make(original: original, corrected: corrected)
    if rejectedPairKeys.contains(pairKey) { return .refusedRejectedPair }
    if let open = openProposalsByPairKey[pairKey] {
      switch refresh(id: open, contextExcerpt: contextExcerpt, sourceBundleID: sourceBundleID) {
      case .refreshed, .notOpen: return .refreshed(open)
      case .writeFailed: return .writeFailed
      }
    }
    // The watcher classified the target BEFORE the judge ran; the word list can
    // have changed meanwhile (the person adds the word while the judge thinks).
    // The card's promise ("New word" / "Already in your words") and the wire
    // state come from the list as it is NOW, the same lookup Accept revalidates.
    let state: CorrectionProposalTargetState =
      switch CustomWordSaveHelper.proposalTarget(
        for: corrected, in: vocabulary.userWords(), packTerms: vocabulary.packTerms())
      {
      case .existing(let word), .packOverride(let word): .existingWord(word.id)
      case .new: .newWord
      }
    let proposal = CorrectionProposal(
      id: makeID(), original: original, corrected: corrected, state: state, language: language,
      contextExcerpt: contextExcerpt, sourceBundleID: sourceBundleID, createdAt: now(),
      advisorySafeAlias: advisorySafeAlias)
    do {
      try persistProposal(proposal)
    } catch {
      noteWriteFailure(error)
      return .writeFailed
    }
    telemetry.learnProposed(state: Self.wireState(state))
    present(id: proposal.id)
    return .minted(proposal.id)
  }

  // MARK: - Step 9: present once

  /// Records the attempt durably, THEN asks the overlay once. A proposal whose
  /// attempt is already recorded (including from a previous launch) is never
  /// offered again; it waits in Pending.
  func present(id: UUID) {
    guard var proposal = proposal(id: id), proposal.status == .pending, !proposal.overlayAttempted
    else { return }
    proposal.overlayAttempted = true
    proposal.updatedAt = now()
    do {
      try persistProposal(proposal)
    } catch {
      noteWriteFailure(error)
      return
    }
    presentations[id] = Presentation(phase: .offered, offered: proposal)
    presenter?.offer(cardModel(for: proposal, phase: .offer))
  }

  /// The overlay admitted the card. `learn_card_shown` counts here, never at
  /// the offer, and exactly once per offer made in this launch: the `offered`
  /// phase is consumed. A repeat of the same token is idempotent; a second
  /// token, an admission after the presentation ended, an offer from an
  /// earlier launch, or an unknown id count nothing.
  func presentationAdmitted(id: UUID, token: CorrectionPresentationToken) {
    guard let record = presentations[id], record.phase == .offered else { return }
    // Resolved from Pending before the overlay got to it: the offer is spent.
    guard proposal(id: id)?.status == .pending else {
      presentations[id]?.phase = .ended
      return
    }
    presentations[id]?.phase = .admitted(token)
    telemetry.learnCardShown()
  }

  /// A terminal resolution closes an offer that was never admitted, so a
  /// delayed admission callback counts nothing and holds no current token.
  private func closeUnadmittedOffer(id: UUID) {
    if presentations[id]?.phase == .offered { presentations[id]?.phase = .ended }
  }

  /// The card left the screen. Expiry counts only for the offer itself: a
  /// result card timing out after a resolution or a refusal is not an
  /// unanswered offer, whatever the proposal's status. The proposal stays
  /// where its ledger status put it and gets no second attempt.
  func presentationEnded(
    id: UUID, token: CorrectionPresentationToken, reason: CorrectionPresentationEnd
  ) {
    guard let record = presentations[id], record.phase == .admitted(token) else { return }
    presentations[id]?.phase = .ended
    if reason == .expired, !record.resultShown { telemetry.learnCardExpired() }
  }

  func cardModel(for proposal: CorrectionProposal, phase: CorrectionProposalCardModel.Phase)
    -> CorrectionProposalCardModel
  {
    CorrectionProposalCardModel(
      id: proposal.id, pairKey: proposal.pairKey, original: proposal.original,
      corrected: proposal.corrected, state: cardState(for: proposal), phase: phase)
  }

  func cardState(for proposal: CorrectionProposal) -> CorrectionCardState {
    switch proposal.state {
    case .existingWord(let id):
      let name =
        vocabulary.userWords().first { $0.id == id }?.canonical
        ?? vocabulary.packTerms().first { $0.id == id }?.canonical ?? proposal.corrected
      return .existingWord(name: name)
    case .newWord:
      return .newWord
    }
  }

  // MARK: - Step 10: resolve

  /// One status-gated commit for both surfaces. Only `pending` begins an
  /// attempt; a persisted `accepting` is reconciled first; terminal states
  /// no-op. A card click must name the presentation the overlay reported as
  /// current.
  @discardableResult
  func resolve(id: UUID, _ decision: CorrectionProposalDecision, surface: Surface) -> ResolveOutcome
  {
    let outcome = resolveRecording(id: id, decision, surface: surface)
    #if DEBUG
      let pair = proposal(id: id).map { "\"\($0.original)\" -> \"\($0.corrected)\"" } ?? id.uuidString
      Self.debugLog("resolved \(pair) decision=\(decision) surface=\(surface) outcome=\(outcome)")
    #endif
    return outcome
  }

  #if DEBUG
    /// One `[LearnFromEdits]` line in app.log, Debug builds only.
    static func debugLog(_ line: String) {
      Task { await AppLogger.shared.log(line, category: "LearnFromEdits") }
    }
  #endif

  private func resolveRecording(id: UUID, _ decision: CorrectionProposalDecision, surface: Surface)
    -> ResolveOutcome
  {
    // A click inside a presenter callback of a commit in flight coalesces; the
    // executing attempt is the one that answers.
    guard !resolving.contains(id) else { return .inProgress }
    resolving.insert(id)
    defer { resolving.remove(id) }
    // A recovery obligation left by an earlier failed write is retried here:
    // one trusted re-load, then the attempt proceeds; still untrusted refuses.
    if case .untrusted(.durabilityUnconfirmed) = ledgerState { initialize() }
    guard ledgerState == .ready else {
      // A card can still be on screen from before the ledger went untrusted
      // (another row's failed sync). Its click must answer: the card morphs to
      // "Couldn't save" and the failure is counted, instead of a silent no-op.
      telemetry.learnSaveFailed(reason: .ledgerUntrusted)
      if let shown = presentations[id]?.offered { showResult(for: shown, .couldNotSave) }
      return .ledgerUnavailable
    }
    guard var proposal = proposal(id: id) else { return .unknownProposal }
    if case .card(let token) = surface, currentPresentation[id] != token {
      return .stalePresentation
    }
    if proposal.status == .accepting {
      // A persisted intent from an earlier attempt (a crash, or a landed write
      // whose record failed): reconcile against a trustworthy list first.
      switch reconcile(id: id) {
      case .completed: return .accepted(.alreadyLanded)
      case .unresolved, .notAccepting: return .inProgress
      case .returnedToPending:
        guard let fresh = self.proposal(id: id) else { return .unknownProposal }
        proposal = fresh
      }
    }
    switch proposal.status {
    case .accepting: return .inProgress
    case .accepted, .rejected: return .alreadyResolved
    case .pending: break
    }
    switch decision {
    case .accept: return accept(proposal, surface: surface)
    case .reject: return reject(proposal, surface: surface)
    }
  }

  private func accept(_ pending: CorrectionProposal, surface: Surface) -> ResolveOutcome {
    let wireSurface = Self.wireSurface(surface)
    let wireState = Self.wireState(pending.state)
    // 1. Resolve the target NOW and persist the intent before any vocabulary
    //    write. A created word's id is allocated here, once, so a crash after
    //    the write and before the ledger update can be reconciled by id.
    let target = CustomWordSaveHelper.proposalTarget(
      for: pending.corrected, in: vocabulary.userWords(), packTerms: vocabulary.packTerms())
    // The card promised "adds a sound-alike to <word>"; if no word with that
    // canonical exists any more, the promise cannot be kept and nothing is
    // invented in its place. Refused before any intent is written.
    if case .existingWord = pending.state, case .new = target {
      telemetry.learnSaveFailed(reason: .targetGone)
      showResult(for: pending, .couldNotSave)
      return .refused(.targetGone)
    }
    let intent: CorrectionAcceptingIntent
    switch target {
    case .existing(let word):
      intent = CorrectionAcceptingIntent(
        pairKey: pending.pairKey, operation: .addAlias, targetWordID: word.id)
    case .packOverride(let converted):
      intent = CorrectionAcceptingIntent(
        pairKey: pending.pairKey, operation: .addAlias, targetWordID: converted.id)
    case .new:
      intent = CorrectionAcceptingIntent(
        pairKey: pending.pairKey, operation: .createWord, targetWordID: makeID())
    }
    var accepting = pending
    accepting.status = .accepting
    accepting.acceptingIntent = intent
    accepting.updatedAt = now()
    do {
      try persistProposal(accepting)
    } catch {
      noteWriteFailure(error)
      telemetry.learnSaveFailed(reason: .ledgerWriteFailed)
      showResult(for: pending, .couldNotSave)
      return .refused(.ledgerWriteFailed)
    }

    // 2. Revalidate immediately before the synchronous write (no suspension
    //    between here and `save`), in a fixed order: the live target must be
    //    the one the intent names; both surfaces must be free of another
    //    word's effective claim; only THEN may same-target coverage resolve as
    //    already landed. A stored alias on the intended word that another word
    //    wins as a trigger is not coverage, it is a shadowed alias, and refuses.
    let userWords = vocabulary.userWords()
    let packTerms = vocabulary.packTerms()
    /// The word the alias joins, nil when a new word is created.
    let base: CustomWord?
    switch CustomWordSaveHelper.proposalTarget(
      for: pending.corrected, in: userWords, packTerms: packTerms)
    {
    case .existing(let current):
      guard current.id == intent.targetWordID else {
        return refuse(accepting, reason: .targetGone)
      }
      base = current
    case .packOverride(let converted):
      guard converted.id == intent.targetWordID else {
        return refuse(accepting, reason: .targetGone)
      }
      base = converted
    case .new:
      guard intent.operation == .createWord else { return refuse(accepting, reason: .targetGone) }
      base = nil
    }
    // The same two surfaces the filter checked (step 6): the original as a
    // trigger, and the corrected phrase itself, both against every OTHER word
    // as the library is now. A claim that appeared since the proposal refuses.
    let index = WordCorrector.buildExactTriggerIndex(words: userWords + packTerms)
    for surface in [pending.original, pending.corrected] {
      if case .blocked = index.resolveAliasOwnership(
        for: surface, excludingOwnerID: intent.targetWordID)
      {
        return refuse(accepting, reason: .aliasOwnedElsewhere)
      }
    }
    if let base, Self.covers(base, original: pending.original) {
      return finishAccepted(
        accepting, outcome: .alreadyLanded, surface: wireSurface, state: wireState)
    }
    let word: CustomWord
    if var updated = base {
      updated.aliases.append(pending.original)
      word = updated
    } else {
      word = CustomWord(
        id: intent.targetWordID, canonical: pending.corrected, aliases: [pending.original],
        category: vocabulary.classify(pending.corrected) ?? .general, source: .user)
    }

    // 3. The one write, then prove it landed.
    if vocabulary.save(word, pending.original) != nil {
      return refuse(accepting, reason: .vocabularyWriteFailed)
    }
    let outcome: TelemetryService.LearnFromEditsTelemetry.ResolutionOutcome
    switch (intent.operation, target) {
    case (.createWord, _): outcome = .added
    case (.addAlias, .packOverride): outcome = .packOverride
    case (.addAlias, _): outcome = .aliasAdded
    }
    return finishAccepted(accepting, outcome: outcome, surface: wireSurface, state: wireState)
  }

  /// Persist `accepted`. If that write fails the vocabulary is NOT undone: the
  /// proposal stays `accepting` with its intent so the next reconcile completes
  /// it, and a Reject is refused meanwhile by the status gate.
  private func finishAccepted(
    _ accepting: CorrectionProposal,
    outcome: TelemetryService.LearnFromEditsTelemetry.ResolutionOutcome,
    surface: TelemetryService.LearnFromEditsTelemetry.Surface,
    state: TelemetryService.LearnFromEditsTelemetry.TargetState
  ) -> ResolveOutcome {
    var done = accepting
    done.status = .accepted
    done.resolvedAt = now()
    done.updatedAt = done.resolvedAt ?? now()
    do {
      try persistProposal(done)
    } catch {
      noteWriteFailure(error)
      telemetry.learnSaveFailed(reason: .ledgerWriteFailed)
      showResult(for: accepting, .savedButNotRecorded)
      return .landedButUnrecorded
    }
    telemetry.learnResolved(decision: .accepted, surface: surface, state: state, outcome: outcome)
    showResult(for: done, outcome == .alreadyLanded ? .alreadyInYourWords : .saved)
    closeUnadmittedOffer(id: done.id)
    return .accepted(outcome)
  }

  /// Return an `accepting` proposal to `pending` (intent cleared) and report
  /// why. The refusal is reported only after that transition persists; if it
  /// cannot persist, the proposal stays `accepting` and the next resolve or
  /// initialize reconciles it.
  private func refuse(
    _ accepting: CorrectionProposal, reason: TelemetryService.LearnFromEditsTelemetry.SaveFailure
  ) -> ResolveOutcome {
    var back = accepting
    back.status = .pending
    back.acceptingIntent = nil
    back.updatedAt = now()
    do {
      try persistProposal(back)
    } catch {
      noteWriteFailure(error)
      telemetry.learnSaveFailed(reason: .ledgerWriteFailed)
      showResult(for: back, .couldNotSave)
      return .refused(.ledgerWriteFailed)
    }
    telemetry.learnSaveFailed(reason: reason)
    showResult(for: back, .couldNotSave)
    return .refused(reason)
  }

  private func reject(_ pending: CorrectionProposal, surface: Surface) -> ResolveOutcome {
    do {
      try persistRejection(id: pending.id, at: now())
    } catch {
      noteWriteFailure(error)
      telemetry.learnSaveFailed(reason: .ledgerWriteFailed)
      showResult(for: pending, .couldNotSave)
      return .refused(.ledgerWriteFailed)
    }
    telemetry.learnResolved(
      decision: .rejected, surface: Self.wireSurface(surface), state: Self.wireState(pending.state),
      outcome: .tombstoned)
    showResult(for: proposal(id: pending.id) ?? pending, .wontAskAgain)
    closeUnadmittedOffer(id: pending.id)
    return .rejected
  }

  /// Morph the still-current card, if there is one; Pending resolutions with
  /// no card on screen update durable state only.
  private func showResult(for proposal: CorrectionProposal, _ result: CorrectionCardResult) {
    guard let token = currentPresentation[proposal.id] else { return }
    presentations[proposal.id]?.resultShown = true
    presenter?.showResult(cardModel(for: proposal, phase: .result(result)), presentation: token)
  }

  // MARK: - Reconciliation

  /// An `accepting` proposal found at launch or on the next attempt: read a
  /// TRUSTWORTHY word list and decide from what landed. Never performs the
  /// missing write.
  @discardableResult
  func reconcile(id: UUID) -> ReconcileOutcome {
    guard ledgerState == .ready, var proposal = proposal(id: id), proposal.status == .accepting,
      let intent = proposal.acceptingIntent
    else { return .notAccepting }
    guard case .fresh(let words) = vocabulary.refreshTrustworthy() else { return .unresolved }
    let landed = words.contains {
      $0.id == intent.targetWordID && Self.covers($0, original: proposal.original)
    }
    if landed {
      proposal.status = .accepted
      proposal.resolvedAt = now()
      proposal.updatedAt = now()
      do {
        try persistProposal(proposal)
      } catch {
        noteWriteFailure(error)
        return .unresolved
      }
      telemetry.learnResolved(
        decision: .accepted, surface: .pending, state: Self.wireState(proposal.state),
        outcome: .alreadyLanded)
      closeUnadmittedOffer(id: id)
      return .completed
    }
    proposal.status = .pending
    proposal.acceptingIntent = nil
    proposal.updatedAt = now()
    do {
      try persistProposal(proposal)
    } catch {
      noteWriteFailure(error)
      return .unresolved
    }
    return .returnedToPending
  }

  // MARK: - Helpers

  static func covers(_ word: CustomWord, original: String) -> Bool {
    let key = CorrectionPairKey.normalise(original)
    if CorrectionPairKey.normalise(word.canonical) == key { return true }
    return word.aliases.contains { CorrectionPairKey.normalise($0) == key }
  }

  private func noteWriteFailure(_ error: Error) {
    // A failure past the temp stage (commit, directory sync) leaves the store's
    // recovery obligation set, and the store already refuses everything until a
    // trusted re-load; mirroring that here keeps later attempts from even
    // reaching it. A temp-write or encoding failure leaves the ledger intact.
    switch error {
    case CorrectionProposalStoreError.commitFailed,
      CorrectionProposalStoreError.directorySyncFailed,
      CorrectionProposalStoreError.recoveryRequired, CorrectionProposalStoreError.ledgerUntrusted:
      ledgerState = .untrusted(.durabilityUnconfirmed)
    default:
      break
    }
  }

  static func wireState(_ state: CorrectionProposalTargetState)
    -> TelemetryService.LearnFromEditsTelemetry.TargetState
  {
    switch state {
    case .existingWord: return .existingWord
    case .newWord: return .newWord
    }
  }

  static func wireSurface(_ surface: Surface) -> TelemetryService.LearnFromEditsTelemetry.Surface {
    switch surface {
    case .card: return .card
    case .pending: return .pending
    }
  }

  static func wireKind(_ kind: CorrectionLedgerUntrustedKind)
    -> TelemetryService.LearnFromEditsTelemetry.LedgerUntrustedKind
  {
    switch kind {
    case .unreadable: return .unreadable
    case .corrupt: return .corrupt
    case .unsupportedVersion: return .unsupportedVersion
    case .unknownStatus: return .unknownStatus
    case .durabilityUnconfirmed: return .durabilityUnconfirmed
    }
  }
}
