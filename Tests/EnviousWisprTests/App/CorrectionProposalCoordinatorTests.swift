import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit

// MARK: - Test doubles shared by the coordinator and watcher suites

/// Records every learn-from-edits emission the coordinator and watcher make.
@MainActor
final class LearnTelemetrySpy: LearnFromEditsRuntimeTelemetrySink {
  enum Event: Equatable {
    case skipped(T.SkipReason)
    // Auto-learn (2026-09-21 plan): the learned coordinator's three rows.
    case added(T.AddedState)
    case undoShown
    case undone(T.UndoKind, T.UndoOutcome)
    case observationEnded(PastedRegionEndReason, Int, T.AppClass)
    case judged(T.Arm, T.JudgeOutcome, Int, Int)
    case proposed(T.TargetState)
    case cardShown
    case cardExpired
    case resolved(T.Decision, T.Surface, T.TargetState, T.ResolutionOutcome)
    case saveFailed(T.SaveFailure)
    case ledgerUntrusted(T.LedgerUntrustedKind, T.LedgerDisposition)
  }
  private(set) var events: [Event] = []

  func learnSkipped(reason: T.SkipReason) { events.append(.skipped(reason)) }
  func learnObservationEnded(
    reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int
  ) {
    events.append(.observationEnded(reason, settledBursts, appClass))
  }
  func learnJudged(
    arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int,
    queueWaitMs: Int?
  ) {
    events.append(.judged(arm, outcome, candidates, accepted))
  }
  func learnProposed(state: T.TargetState) { events.append(.proposed(state)) }
  func learnCardShown() { events.append(.cardShown) }
  func learnCardExpired() { events.append(.cardExpired) }
  func learnResolved(
    decision: T.Decision, surface: T.Surface, state: T.TargetState, outcome: T.ResolutionOutcome
  ) {
    events.append(.resolved(decision, surface, state, outcome))
  }
  func learnSaveFailed(reason: T.SaveFailure) { events.append(.saveFailed(reason)) }
  func learnLedgerUntrusted(kind: T.LedgerUntrustedKind, disposition: T.LedgerDisposition) {
    events.append(.ledgerUntrusted(kind, disposition))
  }
  func learnAdded(state: T.AddedState) { events.append(.added(state)) }
  func learnUndoShown() { events.append(.undoShown) }
  func learnUndone(kind: T.UndoKind, outcome: T.UndoOutcome) {
    events.append(.undone(kind, outcome))
  }
}

/// Stands in for the overlay (5f): records offers and result morphs.
@MainActor
final class PresenterSpy: CorrectionProposalPresenting {
  private(set) var offers: [CorrectionProposalCardModel] = []
  private(set) var results: [(CorrectionProposalCardModel, CorrectionPresentationToken)] = []
  /// Runs synchronously inside `offer`, to stage a presenter that re-enters.
  var onOffer: ((CorrectionProposalCardModel) -> Void)?
  func offer(_ model: CorrectionProposalCardModel) {
    offers.append(model)
    onOffer?(model)
  }
  func showResult(_ model: CorrectionProposalCardModel, presentation: CorrectionPresentationToken) {
    results.append((model, presentation))
  }
}

/// A scripted word library: values in, saves recorded, failures on demand.
@MainActor
final class WordLibraryFake {
  var userWords: [CustomWord] = []
  var packTerms: [CustomWord] = []
  var refresh: CorrectionWordListRead?
  /// nil = every save lands (and is applied to `userWords`); a string refuses.
  var saveRefusal: String?
  /// When true the save reports success but writes nothing (the silent
  /// non-write the landed check exists for is upstream; here we model a
  /// coordinator that lied).
  var saveLies = false
  /// Runs after a save is recorded (before it returns): lets a test flip a
  /// ledger fault at the exact instant the vocabulary lands.
  var onSave: (() -> Void)?
  private(set) var saves: [(CustomWord, String)] = []

  var access: CorrectionVocabularyAccess {
    CorrectionVocabularyAccess(
      userWords: { [unowned self] in self.userWords },
      packTerms: { [unowned self] in self.packTerms },
      refreshTrustworthy: { [unowned self] in self.refresh ?? .fresh(self.userWords) },
      save: { [unowned self] word, spelling in
        self.saves.append((word, spelling))
        defer { self.onSave?() }
        if let refusal = self.saveRefusal { return refusal }
        if !self.saveLies {
          if let i = self.userWords.firstIndex(where: { $0.id == word.id }) {
            self.userWords[i] = word
          } else {
            self.userWords.append(word)
          }
        }
        return nil
      },
      classify: { _ in .person })
  }
}

/// A store whose commit can be made to fail on demand, on a temp directory.
final class LedgerFaults: @unchecked Sendable {
  private let lock = NSLock()
  private var _failCommit = false
  var failCommit: Bool {
    get { lock.withLock { _failCommit } }
    set { lock.withLock { _failCommit = newValue } }
  }
}

func makeFaultableStore() -> (CorrectionProposalStore, LedgerFaults, URL) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("ew-coordinator-\(UUID().uuidString)", isDirectory: true)
  let faults = LedgerFaults()
  var ops = CorrectionProposalStore.FileOps.live
  let liveCommit = ops.commit
  ops.commit = { tmp, final in
    if faults.failCommit { throw CocoaError(.fileWriteNoPermission) }
    try liveCommit(tmp, final)
  }
  return (CorrectionProposalStore(directory: dir, fileOps: ops), faults, dir)
}

// MARK: - Coordinator

@MainActor
@Suite("CorrectionProposalCoordinator (#996 steps 8–10)", .tags(.productOutcome))
struct CorrectionProposalCoordinatorTests {
  typealias C = CorrectionProposalCoordinator
  typealias T = TelemetryService.LearnFromEditsTelemetry

  let store: CorrectionProposalStore
  let faults: LedgerFaults
  let dir: URL
  let library = WordLibraryFake()
  let presenter = PresenterSpy()
  let telemetry = LearnTelemetrySpy()
  let coordinator: C
  let saira = CustomWord(canonical: "Saira", aliases: ["sara"])

  init() {
    (store, faults, dir) = makeFaultableStore()
    library.userWords = [saira]
    coordinator = C(
      store: store, vocabulary: library.access, presenter: presenter, telemetry: telemetry,
      now: { Date(timeIntervalSince1970: 1_000_000) })
    coordinator.initialize()
  }

  private func mint(_ original: String = "sarah", _ corrected: String = "Saira") -> UUID {
    let state: CorrectionProposalTargetState =
      library.userWords.first { $0.canonical == corrected }.map { .existingWord($0.id) } ?? .newWord
    guard
      case .minted(let id) = coordinator.propose(
        original: original, corrected: corrected, state: state, language: "en",
        contextExcerpt: "Ask \(original) today", sourceBundleID: "com.apple.Notes",
        advisorySafeAlias: true)
    else {
      Issue.record("expected minted")
      return UUID()
    }
    return id
  }

  private func admit(_ id: UUID) -> CorrectionPresentationToken {
    let token = CorrectionPresentationToken()
    coordinator.presentationAdmitted(id: id, token: token)
    return token
  }

  // MARK: Step 8

  @Test(
    "a new pair is persisted as pending BEFORE the single offer; the same pair again only refreshes"
  )
  func proposeThenPresentOnce() throws {
    let id = mint()
    let stored = try #require(coordinator.proposal(id: id))
    #expect(stored.status == .pending && stored.overlayAttempted)
    #expect(presenter.offers.map(\.id) == [id])
    #expect(telemetry.events == [.proposed(.existingWord)])
    // Reload from disk: the attempt flag survives, so a relaunch never re-offers.
    let again = CorrectionProposalStore(directory: dir)
    _ = again.load()
    #expect(again.ledger?.proposal(id: id)?.overlayAttempted == true)

    let second = coordinator.propose(
      original: "sarah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
      contextExcerpt: "Call sarah", sourceBundleID: "com.apple.Mail", advisorySafeAlias: nil)
    #expect(second == .refreshed(id))
    #expect(coordinator.proposal(id: id)?.contextExcerpt == "Call sarah")
    #expect(coordinator.proposal(id: id)?.sourceBundleID == "com.apple.Mail")
    #expect(presenter.offers.count == 1, "a refresh never earns a second offer")
    coordinator.present(id: id)
    #expect(presenter.offers.count == 1, "an explicit present after the attempt is a no-op")
  }

  @Test("a rejected pair is never minted again, and a ledger write failure mints nothing")
  func rejectedPairAndWriteFailure() {
    let id = mint()
    let token = admit(id)
    #expect(coordinator.resolve(id: id, .reject, surface: .card(token)) == .rejected)
    #expect(
      coordinator.propose(
        original: "sarah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil) == .refusedRejectedPair)
    // A different corrected spelling is a different pair and is minted.
    faults.failCommit = true
    #expect(
      coordinator.propose(
        original: "sarah", corrected: "Sarah Khan", state: .newWord, language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil) == .writeFailed)
    #expect(coordinator.ledgerState == .untrusted(.durabilityUnconfirmed))
    #expect(
      telemetry.events.filter { if case .proposed = $0 { return true } else { return false } }.count
        == 1)
  }

  // MARK: Step 9

  @Test(
    "shown counts only on admission; expiry counts once and leaves the proposal pending with no second attempt"
  )
  func admissionAndExpiry() {
    let id = mint()
    #expect(telemetry.events.contains(.cardShown) == false)
    let token = admit(id)
    #expect(telemetry.events.contains(.cardShown))
    coordinator.presentationEnded(id: id, token: token, reason: .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1)
    coordinator.presentationEnded(id: id, token: token, reason: .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1, "a stale end is ignored")
    // Admission is consumed by the one offer: a delayed duplicate admission
    // after the expiry, a second token, and an unknown id count nothing, and
    // the proposal being pending with its attempt recorded does not revive it.
    let again = admit(id)
    coordinator.presentationAdmitted(id: id, token: again)
    coordinator.presentationAdmitted(id: id, token: CorrectionPresentationToken())
    coordinator.presentationAdmitted(id: UUID(), token: CorrectionPresentationToken())
    #expect(telemetry.events.filter { $0 == .cardShown }.count == 1, "one offer, one admission")
    #expect(coordinator.currentPresentation[id] == nil, "the late admission is not current")
    coordinator.presentationEnded(id: id, token: again, reason: .preempted)
    coordinator.presentationEnded(id: id, token: again, reason: .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1, "ended stays ended")
    #expect(coordinator.proposal(id: id)?.status == .pending)
    #expect(coordinator.openProposalsNewestFirst.map(\.id) == [id])
    coordinator.present(id: id)
    #expect(presenter.offers.count == 1)
    // A click from the expired card is stale; Pending can still resolve it.
    #expect(coordinator.resolve(id: id, .accept, surface: .card(token)) == .stalePresentation)
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.aliasAdded))
    // A result card timing out after the resolution is not an expired offer.
    let late = CorrectionPresentationToken()
    coordinator.presentationAdmitted(id: id, token: late)
    coordinator.presentationEnded(id: id, token: late, reason: .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1)
    #expect(telemetry.events.filter { $0 == .cardShown }.count == 1, "a terminal proposal is not shown")

    // A refusal leaves the proposal PENDING, and its result card expiring is
    // still not an unanswered offer: the phase, not the status, decides. The
    // target goes missing AFTER the mint (the mint reads the live list), so the
    // stored state names a word that Accept can no longer find.
    guard
      case .minted(let gone) = coordinator.propose(
        original: "sairah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    #expect(coordinator.proposal(id: gone)?.state == .existingWord(saira.id))
    library.userWords = []
    let goneToken = admit(gone)
    #expect(telemetry.events.filter { $0 == .cardShown }.count == 2)
    #expect(coordinator.resolve(id: gone, .accept, surface: .card(goneToken)) == .refused(.targetGone))
    #expect(presenter.results.last?.0.phase == .result(.couldNotSave))
    #expect(coordinator.proposal(id: gone)?.status == .pending)
    coordinator.presentationEnded(id: gone, token: goneToken, reason: .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1, "a result card is not an offer")
    coordinator.presentationAdmitted(id: gone, token: CorrectionPresentationToken())
    #expect(telemetry.events.filter { $0 == .cardShown }.count == 2, "the offer was consumed")
    // A pending proposal from an earlier launch has no offer in memory: admission counts nothing.
    let orphan = mint("saraah", "Saira")
    let fresh = C(
      store: store, vocabulary: library.access, presenter: presenter, telemetry: telemetry,
      now: { Date(timeIntervalSince1970: 1_000_000) })
    fresh.initialize()
    #expect(fresh.proposal(id: orphan)?.overlayAttempted == true)
    fresh.presentationAdmitted(id: orphan, token: CorrectionPresentationToken())
    #expect(telemetry.events.filter { $0 == .cardShown }.count == 2, "persisted attempt is not an offer")
  }

  @Test("a proposal resolved from Pending before the overlay admitted its card spends the offer")
  func resolvedBeforeAdmission() {
    let accepted = mint("sarah", "Saira")
    #expect(coordinator.resolve(id: accepted, .accept, surface: .pending) == .accepted(.aliasAdded))
    coordinator.presentationAdmitted(id: accepted, token: CorrectionPresentationToken())
    #expect(telemetry.events.contains(.cardShown) == false)
    #expect(coordinator.currentPresentation[accepted] == nil)

    let rejected = mint("sarra", "Saira")
    #expect(coordinator.resolve(id: rejected, .reject, surface: .pending) == .rejected)
    coordinator.presentationAdmitted(id: rejected, token: CorrectionPresentationToken())
    #expect(telemetry.events.contains(.cardShown) == false)
    #expect(coordinator.currentPresentation.isEmpty)
    #expect(presenter.offers.count == 2 && presenter.results.isEmpty, "no card to morph")
  }

  // MARK: Step 10: accept

  @Test(
    "accept on an existing word: intent persisted first, alias appended through the save door, accepted persisted, result shown"
  )
  func acceptExistingWord() throws {
    let id = mint()
    let token = admit(id)
    #expect(coordinator.resolve(id: id, .accept, surface: .card(token)) == .accepted(.aliasAdded))
    let saved = try #require(library.saves.first)
    #expect(saved.0.id == saira.id && saved.0.aliases == ["sara", "sarah"] && saved.1 == "sarah")
    let stored = try #require(coordinator.proposal(id: id))
    #expect(stored.status == .accepted && stored.resolvedAt != nil)
    #expect(
      stored.acceptingIntent?.operation == .addAlias
        && stored.acceptingIntent?.targetWordID == saira.id)
    #expect(telemetry.events.last == .resolved(.accepted, .card, .existingWord, .aliasAdded))
    #expect(presenter.results.count == 1 && presenter.results.first?.1 == token)
    #expect(presenter.results.first?.0.phase == .result(.saved))
    // Terminal: further clicks are no-ops, nothing more is written.
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .alreadyResolved)
    #expect(coordinator.resolve(id: id, .reject, surface: .pending) == .alreadyResolved)
    #expect(library.saves.count == 1)
  }

  @Test("accept creating a new word: the id allocated in the intent is the id of the word written")
  func acceptNewWord() throws {
    let id = mint("kubernetees", "Kubernetes")
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.added))
    let stored = try #require(coordinator.proposal(id: id))
    let intent = try #require(stored.acceptingIntent)
    #expect(intent.operation == .createWord)
    let saved = try #require(library.saves.first?.0)
    #expect(
      saved.id == intent.targetWordID && saved.canonical == "Kubernetes"
        && saved.aliases == ["kubernetees"])
    #expect(
      saved.category == .person && saved.source == .user, "category from the injected classifier")
    #expect(telemetry.events.last == .resolved(.accepted, .pending, .newWord, .added))
  }

  @Test("accept on a pack term converts it to a user override carrying the sound-alike")
  func acceptPackOverride() throws {
    let pack = CustomWord(canonical: "Grafana", source: .pack)
    library.packTerms = [pack]
    let id = mint("rafana", "Grafana")
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.packOverride))
    let saved = try #require(library.saves.first?.0)
    #expect(saved.id == pack.id && saved.source == .user && saved.aliases == ["rafana"])
  }

  @Test(
    "already covered resolves accepted without a write; a pair whose original another word owns is refused"
  )
  func alreadyCoveredAndOwnedElsewhere() {
    let id = mint("sara", "Saira")
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.alreadyLanded))
    #expect(library.saves.isEmpty)

    // "sarah" is claimed by another word now.
    let other = CustomWord(canonical: "Sarah Connor", aliases: ["sarah"])
    library.userWords.append(other)
    let id2 = mint("sarah", "Saira")
    #expect(
      coordinator.resolve(id: id2, .accept, surface: .pending) == .refused(.aliasOwnedElsewhere))
    #expect(coordinator.proposal(id: id2)?.status == .pending)
    #expect(coordinator.proposal(id: id2)?.acceptingIntent == nil)
    #expect(telemetry.events.last == .saveFailed(.aliasOwnedElsewhere))
    #expect(library.saves.isEmpty)

    // The CORRECTED phrase claimed by another word since the proposal: refused too.
    library.userWords = [saira, CustomWord(canonical: "Sairaa", aliases: ["saira"])]
    let id3 = mint("sairah", "Saira")
    #expect(
      coordinator.resolve(id: id3, .accept, surface: .pending) == .refused(.aliasOwnedElsewhere))
    #expect(library.saves.isEmpty)

    // A shadowed alias: the intended word already carries "sara", but another
    // word now wins that trigger. That is not coverage; it refuses, and no
    // "already in Your Words" is claimed.
    library.userWords = [saira, CustomWord(canonical: "Sara Ali", aliases: ["sara"])]
    let id4 = mint("sara", "Saira")
    #expect(
      coordinator.resolve(id: id4, .accept, surface: .pending) == .refused(.aliasOwnedElsewhere))
    #expect(coordinator.proposal(id: id4)?.status == .pending)
    #expect(library.saves.isEmpty)
    #expect(
      telemetry.events.filter { $0 == .resolved(.accepted, .pending, .existingWord, .alreadyLanded) }
        .count == 1, "only the first, unshadowed case landed")
  }

  @Test(
    "the target deleted between proposal and accept is refused as target_gone before any intent is written"
  )
  func targetGone() {
    let id = mint()
    library.userWords = []
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .refused(.targetGone))
    #expect(coordinator.proposal(id: id)?.status == .pending)
    #expect(coordinator.proposal(id: id)?.acceptingIntent == nil)
    #expect(library.saves.isEmpty)
    #expect(telemetry.events.last == .saveFailed(.targetGone))
    // A word with that canonical under a NEW id keeps the promise: alias added to it.
    let reborn = CustomWord(canonical: "Saira")
    library.userWords = [reborn]
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.aliasAdded))
    #expect(library.saves.first?.0.id == reborn.id)
  }

  @Test(
    "a refused vocabulary write returns the proposal to pending, reports the fixed reason token and morphs the card"
  )
  func vocabularyWriteRefused() {
    library.saveRefusal = "The word could not be saved."
    let id = mint()
    let token = admit(id)
    #expect(
      coordinator.resolve(id: id, .accept, surface: .card(token)) == .refused(.vocabularyWriteFailed))
    #expect(presenter.results.first?.0.phase == .result(.couldNotSave))
    #expect(coordinator.proposal(id: id)?.status == .pending)
    #expect(telemetry.events.last == .saveFailed(.vocabularyWriteFailed))
    // Retry after the cause is gone.
    library.saveRefusal = nil
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.aliasAdded))
  }

  @Test(
    "intent write failure writes no vocabulary; accepted-write failure after a landed save keeps ACCEPTING and blocks Reject"
  )
  func ledgerFailuresAroundTheWrite() throws {
    let id = mint()
    faults.failCommit = true
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .refused(.ledgerWriteFailed))
    #expect(library.saves.isEmpty, "no vocabulary write without a persisted intent")
    #expect(coordinator.ledgerState == .untrusted(.durabilityUnconfirmed))
    // The next click retries recovery (the directory sync succeeds, so the
    // obligation clears) and then fails the intent write again: still nothing
    // written to the vocabulary.
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .refused(.ledgerWriteFailed))
    #expect(library.saves.isEmpty)
    // Recover: a trusted re-load restores the path.
    faults.failCommit = false
    coordinator.initialize()
    #expect(coordinator.ledgerState == .ready)
    #expect(coordinator.proposal(id: id)?.status == .pending)

    // Now fail only the FINAL write: the vocabulary lands, the ledger cannot
    // record it, the proposal stays accepting with its intent, and Reject is
    // refused meanwhile.
    library.onSave = { [faults] in faults.failCommit = true }
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .landedButUnrecorded)
    #expect(library.saves.count == 1, "the alias was written once")
    #expect(library.userWords.first?.aliases == ["sara", "sarah"])
    #expect(telemetry.events.last == .saveFailed(.ledgerWriteFailed))
    library.onSave = nil
    faults.failCommit = false
    // The next click retries the recovery (one trusted re-load), finds the
    // persisted ACCEPTING intent, and reconciles it from the live list: the
    // alias landed, so the proposal completes as accepted and the Reject is a
    // no-op on a terminal record. Nothing is written twice.
    #expect(coordinator.resolve(id: id, .reject, surface: .pending) == .alreadyResolved)
    #expect(coordinator.ledgerState == .ready)
    #expect(coordinator.proposal(id: id)?.status == .accepted)
    #expect(library.saves.count == 1, "reconciliation never repeats the write")
    #expect(telemetry.events.last == .resolved(.accepted, .pending, .existingWord, .alreadyLanded))
  }

  @Test(
    "reject writes the tombstone and the status atomically; a failed reject leaves pending and deletes nothing"
  )
  func rejectAtomic() throws {
    let id = mint()
    faults.failCommit = true
    #expect(coordinator.resolve(id: id, .reject, surface: .pending) == .refused(.ledgerWriteFailed))
    faults.failCommit = false
    coordinator.initialize()
    #expect(coordinator.proposal(id: id)?.status == .pending)
    #expect(coordinator.rejectedPairKeys.isEmpty)

    let token = admit(id)
    #expect(coordinator.resolve(id: id, .reject, surface: .card(token)) == .rejected)
    let stored = try #require(coordinator.proposal(id: id))
    #expect(stored.status == .rejected && coordinator.rejectedPairKeys == [stored.pairKey])
    #expect(library.saves.isEmpty && library.userWords == [saira], "Reject never touches a word")
    #expect(telemetry.events.last == .resolved(.rejected, .card, .existingWord, .tombstoned))
    #expect(presenter.results.first?.0.phase == .result(.wontAskAgain))
    // Persisted as one document: a fresh load agrees on both halves.
    let again = CorrectionProposalStore(directory: dir)
    _ = again.load()
    #expect(again.ledger?.proposal(id: id)?.status == .rejected)
    #expect(again.ledger?.isRejected(pairKey: stored.pairKey) == true)
  }

  // MARK: Reconciliation

  @Test(
    "an accepting proposal at launch: landed → accepted, missing → pending, unreadable → left alone"
  )
  func reconcileAtLaunch() throws {
    // Stage an `accepting` record directly, as a crash mid-accept would leave it.
    let id = mint()
    var staged = try #require(coordinator.proposal(id: id))
    staged.status = .accepting
    staged.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: staged.pairKey, operation: .addAlias, targetWordID: saira.id)
    try store.upsert(staged)

    // Unreadable library: nothing changes.
    library.refresh = .unreadable
    coordinator.initialize()
    #expect(coordinator.proposal(id: id)?.status == .accepting)
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .inProgress)
    #expect(coordinator.resolve(id: id, .reject, surface: .pending) == .inProgress)

    // Missing: back to pending, intent cleared, nothing written.
    library.refresh = .fresh([saira])
    coordinator.initialize()
    #expect(coordinator.proposal(id: id)?.status == .pending)
    #expect(coordinator.proposal(id: id)?.acceptingIntent == nil)
    #expect(library.saves.isEmpty)

    // Landed (the alias is on the target): completed as accepted, still no write.
    staged.status = .accepting
    staged.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: staged.pairKey, operation: .addAlias, targetWordID: saira.id)
    try store.upsert(staged)
    var landed = saira
    landed.aliases.append("sarah")
    library.refresh = .fresh([landed])
    coordinator.initialize()
    #expect(coordinator.proposal(id: id)?.status == .accepted)
    #expect(telemetry.events.last == .resolved(.accepted, .pending, .existingWord, .alreadyLanded))
    #expect(library.saves.isEmpty)
  }

  @Test(
    "a persisted accepting intent is reconciled on the next click: landed completes, missing lets the click proceed"
  )
  func nextAttemptReconciles() throws {
    let id = mint()
    var staged = try #require(coordinator.proposal(id: id))
    staged.status = .accepting
    staged.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: staged.pairKey, operation: .addAlias, targetWordID: saira.id)
    try store.upsert(staged)
    // Landed elsewhere (the alias is on the target): the click completes it.
    var landed = saira
    landed.aliases.append("sarah")
    library.refresh = .fresh([landed])
    #expect(coordinator.resolve(id: id, .reject, surface: .pending) == .accepted(.alreadyLanded))
    #expect(coordinator.proposal(id: id)?.status == .accepted && library.saves.isEmpty)

    // Missing: the click proceeds as a fresh decision on the now-pending record.
    let id2 = mint("sarra", "Saira")
    var staged2 = try #require(coordinator.proposal(id: id2))
    staged2.status = .accepting
    staged2.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: staged2.pairKey, operation: .addAlias, targetWordID: saira.id)
    try store.upsert(staged2)
    library.refresh = .fresh([saira])
    library.userWords = [saira]
    #expect(coordinator.resolve(id: id2, .reject, surface: .pending) == .rejected)
    #expect(coordinator.proposal(id: id2)?.status == .rejected)
  }

  @Test("a damaged ledger is moved aside and the path starts fresh, reported once; an unreadable one disables the path")
  func damagedAndUnreadableLedgers() throws {
    let (badStore, _, badDir) = makeFaultableStore()
    try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: badStore.fileURL)
    let spy = LearnTelemetrySpy()
    let c = C(store: badStore, vocabulary: library.access, presenter: presenter, telemetry: spy)
    c.initialize()
    c.initialize()
    #expect(c.ledgerState == .ready, "founder 2026-09-20: a damaged file moves aside and the ledger starts fresh")
    #expect(c.recoveredAtLaunch == .corrupt)
    #expect(spy.events == [.ledgerUntrusted(.corrupt, .recovered)], "reported once, as recovered")
    #expect(FileManager.default.fileExists(atPath: badStore.fileURL.path) == false, "moved aside")
    guard
      case .minted = c.propose(
        original: "a", corrected: "B", state: .newWord, language: "en", contextExcerpt: nil,
        sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("a fresh ledger accepts a proposal")
      return
    }

    // Unreadable (a directory where the file should be): nothing moves, the path is disabled.
    let (blindStore, _, blindDir) = makeFaultableStore()
    try FileManager.default.createDirectory(at: blindStore.fileURL, withIntermediateDirectories: true)
    let spy2 = LearnTelemetrySpy()
    let c2 = C(store: blindStore, vocabulary: library.access, presenter: presenter, telemetry: spy2)
    c2.initialize()
    c2.initialize()
    #expect(c2.ledgerState == .untrusted(.unreadable))
    #expect(c2.recoveredAtLaunch == nil)
    #expect(spy2.events == [.ledgerUntrusted(.unreadable, .blocked)])
    #expect(
      c2.propose(
        original: "a", corrected: "B", state: .newWord, language: "en", contextExcerpt: nil,
        sourceBundleID: nil, advisorySafeAlias: nil) == .ledgerUnavailable)
    #expect(c2.resolve(id: UUID(), .accept, surface: .pending) == .ledgerUnavailable)
    _ = blindDir
    #expect(c2.openProposalsByPairKey.isEmpty && c2.rejectedPairKeys.isEmpty, "an untrusted ledger reads as nothing")
  }

  @Test("launch prunes resolved payloads after the retention window and keeps pending ones")
  func initializePrunesResolvedPayloads() throws {
    let done = mint("sarah", "Saira")
    #expect(coordinator.resolve(id: done, .reject, surface: .pending) == .rejected)
    let open = mint("nadya", "Nadia")
    #expect(store.ledger?.proposals.count == 2)
    let later = Date(timeIntervalSince1970: 1_000_000 + CorrectionProposalStore.retentionAfterResolution + 1)
    let c = C(
      store: store, vocabulary: library.access, presenter: presenter, telemetry: LearnTelemetrySpy(),
      now: { later })
    c.initialize()
    #expect(c.ledgerState == .ready)
    #expect(c.proposal(id: done) == nil, "the rejected payload left at launch")
    #expect(c.proposal(id: open)?.status == .pending, "pending is never pruned")
    #expect(c.rejectedPairKeys.count == 1, "the tombstone outlives its payload")
  }

  @Test("the minted state follows the LIVE word list, not the classification the watcher made before the judge ran")
  func stateFollowsTheLiveListAtMint() {
    // The watcher said "new word"; the person added Saira while the judge thought.
    guard
      case .minted(let id) = coordinator.propose(
        original: "sarah", corrected: "Saira", state: .newWord, language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    #expect(coordinator.proposal(id: id)?.state == .existingWord(saira.id))
    #expect(telemetry.events.last == .proposed(.existingWord))
    #expect(presenter.offers.last?.state == .existingWord(name: "Saira"), "the card promises what Accept will do")
    // And the other way: a stale "existing" id for a word that is gone mints a new word.
    guard
      case .minted(let id2) = coordinator.propose(
        original: "nadya", corrected: "Nadia", state: .existingWord(UUID()), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    #expect(coordinator.proposal(id: id2)?.state == .newWord)
    #expect(telemetry.events.last == .proposed(.newWord))
  }

  @Test("a click on a card still on screen after the ledger went untrusted answers with couldNotSave and is counted")
  func clickOnACardAfterTheLedgerWentUntrusted() throws {
    let shown = mint()
    let token = admit(shown)
    // Another row's write fails past the temp stage: the ledger is untrusted.
    let other = mint("nadya", "Nadia")
    faults.failCommit = true
    #expect(coordinator.resolve(id: other, .reject, surface: .pending) == .refused(.ledgerWriteFailed))
    #expect(coordinator.ledgerState == .untrusted(.durabilityUnconfirmed))
    // The retry inside resolve re-reads the ledger; make that re-read fail too so
    // the click meets an untrusted ledger, as it would after a real disk fault.
    try FileManager.default.removeItem(at: store.fileURL)
    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
    let before = presenter.results.count
    #expect(coordinator.resolve(id: shown, .accept, surface: .card(token)) == .ledgerUnavailable)
    #expect(telemetry.events.last == .saveFailed(.ledgerUntrusted))
    #expect(presenter.results.count == before + 1, "the card is answered, not left looking live")
    #expect(presenter.results.last?.0.phase == .result(.couldNotSave))
    #expect(presenter.results.last?.1 == token)
    #expect(library.saves.isEmpty, "nothing written to the vocabulary")
  }

  @Test(
    "two pending proposals minted as NEW for the same spelling: accepting the first creates the word, the second is then an alias add, and its card and Pending row say so"
  )
  func twoPendingNewWordProposalsForOneSpelling() throws {
    let first = mint("kubernetees", "Kubernetes")
    let second = mint("cubernetes", "Kubernetes")
    #expect(coordinator.proposal(id: second)?.state == .newWord, "minted before the word existed")
    #expect(coordinator.resolve(id: first, .accept, surface: .pending) == .accepted(.added))
    let created = try #require(library.userWords.first { $0.canonical == "Kubernetes" })
    // The stored record still says new; the card and the row read the live list.
    let stale = try #require(coordinator.proposal(id: second))
    #expect(stale.state == .newWord)
    #expect(coordinator.cardState(for: stale) == .existingWord(name: "Kubernetes"))
    #expect(coordinator.resolve(id: second, .accept, surface: .pending) == .accepted(.aliasAdded))
    let landed = try #require(library.userWords.first { $0.canonical == "Kubernetes" })
    #expect(landed.id == created.id && Set(landed.aliases) == ["kubernetees", "cubernetes"])
    #expect(library.userWords.filter { $0.canonical == "Kubernetes" }.count == 1, "one word, not two")
    // The ledger record and the telemetry carry the LIVE state the click acted on.
    let resolved = try #require(coordinator.proposal(id: second))
    #expect(resolved.state == .existingWord(created.id))
    #expect(resolved.acceptingIntent?.operation == .addAlias)
    #expect(telemetry.events.last == .resolved(.accepted, .pending, .existingWord, .aliasAdded))
  }

  @Test("the card model carries the typed state for the target as it is now")
  func cardModel() throws {
    let id = mint()
    let model = try #require(presenter.offers.first)
    #expect(model.state == .existingWord(name: "Saira"))
    #expect(model.original == "sarah" && model.corrected == "Saira" && model.phase == .offer)
    let id2 = mint("kubernetees", "Kubernetes")
    #expect(
      presenter.offers.last?.id == id2 && presenter.offers.last?.state == .newWord)
    _ = id
  }
}
