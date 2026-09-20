import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

// MARK: - Fixtures

enum CorrectionCardFixture {
  static func model(
    id: UUID = UUID(), original: String = "sarah", corrected: String = "Saira",
    state: CorrectionCardState = .existingWord(name: "Saira"),
    phase: CorrectionProposalCardModel.Phase = .offer
  ) -> CorrectionProposalCardModel {
    CorrectionProposalCardModel(
      id: id, pairKey: "sarah\u{1F}saira", original: original, corrected: corrected,
      state: state, phase: phase)
  }
}

/// Stands in for the director on the adapter's side: records requests, answers
/// `onResult` when the test says so, records dismissals and result morphs.
@MainActor
final class CorrectionOverlayHostFake: CorrectionProposalOverlayHosting {
  private(set) var requests: [CorrectionProposalCardModel] = []
  private(set) var accepts: [(CorrectionPresentationToken) -> Void] = []
  private(set) var rejects: [(CorrectionPresentationToken) -> Void] = []
  private(set) var endeds: [(CorrectionPresentationToken, CorrectionPresentationEnd) -> Void] = []
  private(set) var stillWanted: [() -> Bool] = []
  private(set) var pendingResults: [(PillPresentationResult) -> Void] = []
  private(set) var resolved: [(UUID, PresentationID, CorrectionCardResult)] = []
  /// nil = refuse admission synchronously.
  var admitAs: PresentationID? = PresentationID()
  /// true = hold `onResult` for the test to answer (a deferred first render).
  var deferResult = false

  func present(
    _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt? {
    guard
      case .correctionProposal(let model, let isStillWanted, let onAccept, let onReject, let onEnded) =
        request
    else {
      Issue.record("the adapter presented something other than a correction card")
      return nil
    }
    requests.append(model)
    stillWanted.append(isStillWanted)
    accepts.append(onAccept)
    rejects.append(onReject)
    endeds.append(onEnded)
    guard let id = admitAs else {
      onResult(.notPresented)
      return nil
    }
    let receipt = PillReceipt(presentationID: id)
    if deferResult {
      pendingResults.append(onResult)
    } else {
      onResult(.presented(receipt))
    }
    return receipt
  }

  /// The director's rule, mirrored: a deferred render commits only while the
  /// owner still wants it; otherwise the relay hears `notPresented`.
  func answerPending() {
    let waiting = pendingResults
    pendingResults = []
    let wanted = stillWanted.last?() ?? false
    for answer in waiting {
      answer(wanted ? .presented(PillReceipt(presentationID: admitAs ?? PresentationID())) : .notPresented)
    }
  }

  func resolveCorrectionProposal(
    id: UUID, presentation: PresentationID, outcome: CorrectionCardResult
  ) {
    resolved.append((id, presentation, outcome))
  }
}

// MARK: - Reducer

@Suite("Correction card: reducer transitions (#996 step 9)", .tags(.productOutcome))
struct CorrectionProposalCardReducerTests {

  private static func card(_ reducer: OverlayReducer) -> CorrectionProposalCardModel? {
    guard case .correctionProposal(let model)? = reducer.state.current?.content else { return nil }
    return model
  }

  @Test("an offer is admitted on an idle, empty slot with the chip's hover-pausable 8 s dwell and a spoken sentence")
  func admittedWhenIdleAndEmpty() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = CorrectionCardFixture.model()
    let plan = r.reduce(.correctionProposed(model))
    #expect(plan.didChange)
    let shown = try #require(plan.presentation)
    #expect(shown.id == id && shown.content == .correctionProposal(model))
    #expect(shown.expiry == .after(seconds: 8, pausesOnHover: true))
    #expect(shown.requestedWidth == .fixed(440) && shown.reservesFixedHeight == nil)
    #expect(plan.expiryCommand == .arm(id: id, seconds: 8, target: .presentation))
    #expect(plan.announcement?.isHighPriority == false)
    #expect(plan.announcement?.text.contains("sarah was corrected to Saira") == true)
    #expect(r.state.current == shown && r.state.pipelineIntent == .hidden)
    #expect(r.state.featureSlotIsAvailable == false, "a card with buttons is not a free slot")
  }

  @Test("refused while the pipeline is busy, while another feature or notice holds the slot, and for a result-phase model")
  func refusals() {
    var busy = OverlayReducer()
    busy.startRecordingForTests(audioLevel: 0.2)
    let before = busy.state.current
    #expect(busy.reduce(.correctionProposed(CorrectionCardFixture.model())) == .noChange)
    #expect(busy.state.current == before)

    var bluetooth = OverlayReducer()
    _ = bluetooth.reduce(.bluetoothAwareness)
    #expect(bluetooth.reduce(.correctionProposed(CorrectionCardFixture.model())) == .noChange)
    #expect(bluetooth.state.current?.content == .bluetoothAwareness)

    var importing = OverlayReducer()
    _ = importing.reduce(.importStatus(message: "Importing…"))
    #expect(importing.reduce(.correctionProposed(CorrectionCardFixture.model())) == .noChange)
    guard case .notice? = importing.state.current?.content else {
      Issue.record("the import notice was displaced")
      return
    }

    var empty = OverlayReducer()
    #expect(
      empty.reduce(.correctionProposed(CorrectionCardFixture.model(phase: .result(.saved))))
        == .noChange, "a result cannot create a card")
    #expect(empty.state.current == nil)
  }

  @Test("a card on screen is not displaced by import status, Bluetooth or a different proposal; it is refreshed only by its own offer, keeping identity and dwell")
  func selfOnlyRefresh() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = CorrectionCardFixture.model()
    _ = r.reduce(.correctionProposed(model))

    #expect(r.reduce(.importStatus(message: "Imported 3 words")) == .noChange)
    #expect(r.reduce(.bluetoothAwareness) == .noChange)
    #expect(r.reduce(.correctionProposed(CorrectionCardFixture.model(original: "invoyce", corrected: "invoice"))) == .noChange)
    #expect(Self.card(r)?.id == model.id, "another proposal waits in Pending")

    // Same model again: nothing to redraw, the dwell is left alone.
    let same = r.reduce(.correctionProposed(model))
    #expect(same.didChange == false && same.presentation?.id == id && same.expiryCommand == .unchanged)

    // A changed state line: same identity, redrawn, dwell NOT restarted.
    let renamed = CorrectionCardFixture.model(id: model.id, state: .newWord)
    let refreshed = r.reduce(.correctionProposed(renamed))
    #expect(refreshed.didChange && refreshed.presentation?.id == id)
    #expect(refreshed.expiryCommand == .unchanged, "a refresh never restarts the dwell")
    #expect(Self.card(r) == renamed)

    // A result never goes back to an offer through a late refresh.
    _ = r.reduce(.correctionProposalResolved(id: model.id, presentation: id, outcome: .saved))
    #expect(r.reduce(.correctionProposed(model)) == .noChange)
    #expect(Self.card(r)?.phase == .result(.saved))
  }

  @Test("a matching resolution morphs the card in place: same identity, result phase, fresh 3 s dwell; stale pairs are no-ops")
  func resultMorph() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = CorrectionCardFixture.model()
    _ = r.reduce(.correctionProposed(model))
    _ = r.reduce(.hoverChanged(id, true))

    #expect(r.reduce(.correctionProposalResolved(id: UUID(), presentation: id, outcome: .saved)) == .noChange)
    #expect(r.reduce(.correctionProposalResolved(id: model.id, presentation: PresentationID(), outcome: .saved)) == .noChange)
    #expect(Self.card(r)?.phase == .offer)

    let plan = r.reduce(.correctionProposalResolved(id: model.id, presentation: id, outcome: .alreadyInYourWords))
    #expect(plan.didChange && plan.presentation?.id == id)
    #expect(Self.card(r)?.phase == .result(.alreadyInYourWords))
    #expect(plan.presentation?.expiry == .after(seconds: 3, pausesOnHover: false))
    #expect(plan.expiryCommand == .arm(id: id, seconds: 3, target: .presentation))
    #expect(r.state.isHovered == false, "the result's own dwell runs even under the pointer")

    // A second resolution on a result is stale.
    #expect(r.reduce(.correctionProposalResolved(id: model.id, presentation: id, outcome: .saved)) == .noChange)
    // The result expires as an ended presentation with the expired reason.
    let expired = r.reduce(.expiryFired(id))
    #expect(expired.presentation == nil && r.state.current == nil)
    #expect(expired.effects == [.correctionProposalEnded(id: model.id, presentation: id, reason: .expired)])
  }

  @Test("Accept and Reject are delivered only for the shown proposal in the offer phase; a result has no buttons")
  func actions() {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = CorrectionCardFixture.model()
    _ = r.reduce(.correctionProposed(model))

    #expect(r.reduce(.action(id, .acceptCorrectionProposal(id: UUID()))) == .noChange, "wrong proposal")
    #expect(r.reduce(.action(PresentationID(), .acceptCorrectionProposal(id: model.id))) == .noChange, "stale presentation")
    let accept = r.reduce(.action(id, .acceptCorrectionProposal(id: model.id)))
    #expect(accept.deliverAction == .acceptCorrectionProposal(id: model.id) && accept.didChange == false)
    let reject = r.reduce(.action(id, .rejectCorrectionProposal(id: model.id)))
    #expect(reject.deliverAction == .rejectCorrectionProposal(id: model.id))

    _ = r.reduce(.correctionProposalResolved(id: model.id, presentation: id, outcome: .saved))
    #expect(r.reduce(.action(id, .acceptCorrectionProposal(id: model.id))) == .noChange, "no buttons on a result")
    #expect(r.reduce(.action(id, .rejectCorrectionProposal(id: model.id))) == .noChange, "no buttons on a result")
    #expect(r.state.current?.id == id, "a result stays until its own dwell fires; nothing dismisses it")
  }

  @Test("hover pauses the offer's dwell and leaving re-arms it from full; expiry ends the card as expired and frees the slot")
  func hoverAndExpiry() {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let model = CorrectionCardFixture.model()
    _ = r.reduce(.correctionProposed(model))
    #expect(r.reduce(.hoverChanged(id, true)).expiryCommand == .cancel)
    #expect(r.reduce(.expiryFired(id)) == .noChange, "a hovered card does not expire")
    #expect(r.reduce(.hoverChanged(id, false)).expiryCommand == .arm(id: id, seconds: 8, target: .presentation))
    let expired = r.reduce(.expiryFired(id))
    #expect(expired.presentation == nil && expired.expiryCommand == .cancel)
    #expect(expired.effects == [.correctionProposalEnded(id: model.id, presentation: id, reason: .expired)])
    #expect(r.state.featureSlotIsAvailable, "the slot is free again")
    #expect(r.reduce(.expiryFired(id)) == .noChange, "reported once")
  }

  @Test("the pipeline preempts the card exactly once per presentation: a notice, a recording, or hidden")
  func preemption() throws {
    // Real ids: a constant id factory would make the incoming pill LOOK like a
    // same-id morph of the card, which is exactly the case that must not end it.
    let model = CorrectionCardFixture.model()

    var notice = OverlayReducer()
    _ = notice.reduce(.correctionProposed(model))
    let noticeCard = try #require(notice.state.current?.id)
    let replaced = notice.reduce(.pipeline(.processing(phase: .transcribing)))
    #expect(replaced.effects == [.correctionProposalEnded(id: model.id, presentation: noticeCard, reason: .preempted)])
    #expect(replaced.presentation?.id != noticeCard)
    #expect(notice.reduce(.pipeline(.hidden)).effects == [], "the card ended once")

    var recording = OverlayReducer()
    _ = recording.reduce(.correctionProposed(model))
    let recordingCard = try #require(recording.state.current?.id)
    let started = recording.startRecordingForTests(audioLevel: 0.1)
    #expect(
      started.effects == [
        .recordingStateChanged(true),
        .correctionProposalEnded(id: model.id, presentation: recordingCard, reason: .preempted),
      ])
    guard case .recording? = recording.state.current?.content else {
      Issue.record("the recording did not take the slot")
      return
    }

    var hidden = OverlayReducer()
    _ = hidden.reduce(.correctionProposed(model))
    let hiddenCard = try #require(hidden.state.current?.id)
    let emptied = hidden.reduce(.pipeline(.hidden))
    #expect(emptied.effects == [.correctionProposalEnded(id: model.id, presentation: hiddenCard, reason: .preempted)])
    #expect(emptied.presentation == nil && hidden.state.current == nil)

    // A same-id morph is NOT a preemption: the result morph keeps the card.
    var morph = OverlayReducer()
    _ = morph.reduce(.correctionProposed(model))
    let morphCard = try #require(morph.state.current?.id)
    let result = morph.reduce(.correctionProposalResolved(id: model.id, presentation: morphCard, outcome: .saved))
    #expect(result.effects.isEmpty && result.presentation?.id == morphCard)
  }
}

// MARK: - Director

@MainActor
@Suite("Correction card: director binding, admission and ends (#996 step 9)", .tags(.productOutcome))
struct CorrectionProposalCardDirectorTests {

  private final class Armed {
    var work: OverlayScheduledWork?
  }

  private final class Log {
    var accepted: [CorrectionPresentationToken] = []
    var rejected: [CorrectionPresentationToken] = []
    var ended: [(CorrectionPresentationToken, CorrectionPresentationEnd)] = []
    var results: [PillPresentationResult] = []
    var announcements: [OverlayAnnouncement] = []
  }

  private func director(_ armed: Armed, _ log: Log) -> (OverlayDirector, WindowlessOverlayHost) {
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { armed.work = $0 },
      announce: { log.announcements.append($0) },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    return (d, host)
  }

  private func request(
    _ model: CorrectionProposalCardModel, _ log: Log, stillWanted: @escaping () -> Bool = { true }
  ) -> PillRequest {
    .correctionProposal(
      model: model,
      isStillWanted: stillWanted,
      onAccept: { log.accepted.append($0) },
      onReject: { log.rejected.append($0) },
      onEnded: { log.ended.append(($0, $1)) })
  }

  @Test("a press on the admitted card reaches its handler with the presentation's own UUID as the token; a stale press reaches nothing")
  func pressesCarryThePresentationIdentity() throws {
    let armed = Armed()
    let log = Log()
    let (d, host) = director(armed, log)
    let model = CorrectionCardFixture.model()
    let receipt = try #require(d.present(request(model, log)) { log.results.append($0) })
    #expect(log.results == [.presented(receipt)])
    #expect(log.announcements.count == 1 && log.announcements.first?.isHighPriority == false)
    #expect(armed.work != nil, "the offer's dwell armed")

    try host.sendUserActionThroughRoot(.acceptCorrectionProposal(id: model.id), for: receipt)
    #expect(log.accepted == [CorrectionPresentationToken(id: receipt.presentationID.rawValue)])
    try host.sendUserActionThroughRoot(.rejectCorrectionProposal(id: UUID()), for: receipt)
    #expect(log.rejected.isEmpty, "a press for a different proposal is dropped")

    // Resolve, then the old offer's press is dead and the result expires as ended.
    d.resolveCorrectionProposal(id: model.id, presentation: receipt.presentationID, outcome: .saved)
    guard case .correctionProposal(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the card left the screen on resolution")
      return
    }
    #expect(shown.phase == .result(.saved) && d.isCurrent(receipt))
    try host.sendUserActionThroughRoot(.acceptCorrectionProposal(id: model.id), for: receipt)
    #expect(log.accepted.count == 1, "no buttons on a result")
    let work = try #require(armed.work)
    work.fire()
    #expect(d.renderModel.state.presentation == nil)
    #expect(log.ended.map(\.1) == [.expired])
    #expect(log.ended.first?.0 == CorrectionPresentationToken(id: receipt.presentationID.rawValue))
  }

  @Test("expiry ends the card as expired; a pipeline pill ends it as preempted; each exactly once")
  func endsAreReportedOnce() throws {
    let armed = Armed()
    let log = Log()
    let (d, host) = director(armed, log)
    let model = CorrectionCardFixture.model()
    let first = try #require(d.present(request(model, log)))
    try #require(armed.work).fire()
    #expect(d.renderModel.state.presentation == nil)
    #expect(log.ended.map(\.1) == [.expired])
    #expect(log.rejected.isEmpty, "expiry is not Reject")

    let second = try #require(d.present(request(model, log)))
    d.present(.warning(reason: .polishFailed))
    #expect(log.ended.map(\.1) == [.expired, .preempted])
    #expect(log.ended.last?.0 == CorrectionPresentationToken(id: second.presentationID.rawValue))
    #expect(d.isCurrent(second) == false)
    d.dismissCurrent(.silent)
    #expect(log.ended.count == 2, "the replaced card is not reported again")
  }

  @Test("a same-proposal refresh keeps the original binding: presses and the end still reach the first owner")
  func refreshKeepsTheOriginalBinding() throws {
    let armed = Armed()
    let first = Log()
    let second = Log()
    let (d, host) = director(armed, first)
    let model = CorrectionCardFixture.model()
    let receipt = try #require(d.present(request(model, first)))
    let refreshed = d.present(
      request(CorrectionCardFixture.model(id: model.id, state: .newWord), second))
    #expect(refreshed == nil, "a refresh keeps the incumbent's receipt; it is not a new admission")
    guard case .correctionProposal(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the card left the screen on refresh")
      return
    }
    #expect(shown.state == .newWord && d.isCurrent(receipt))

    try host.sendUserActionThroughRoot(.acceptCorrectionProposal(id: model.id), for: receipt)
    #expect(first.accepted.count == 1 && second.accepted.isEmpty)
    let work = try #require(armed.work)
    work.fire()
    #expect(first.ended.map(\.1) == [.expired] && second.ended.isEmpty)
  }

  @Test("an end callback that presents a newer pill wins: the stale plan is discarded, not applied over it")
  func endCallbackMayReenter() throws {
    let armed = Armed()
    let log = Log()
    let (d, _) = director(armed, log)
    let model = CorrectionCardFixture.model()
    let reentrant = PillRequest.correctionProposal(
      model: model, isStillWanted: { true },
      onAccept: { _ in }, onReject: { _ in },
      onEnded: { token, reason in
        log.ended.append((token, reason))
        // The owner reacts to the end by raising its own notice.
        d.present(.warning(reason: .polishFailed))
      })
    _ = try #require(d.present(reentrant))

    // Preemption by a pipeline notice: the re-entrant warning must be what stays.
    d.present(.processing(phase: .transcribing))
    #expect(log.ended.map(\.1) == [.preempted])
    guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
      Issue.record("the re-entrant pill is not on screen")
      return
    }
    #expect(notice.kind == .notification, "the warning, not the processing pill, holds the slot")
    #expect(d.renderModel.state.presentation?.id == d.renderModel.state.dwell?.id)

    // Preemption by a recording COMMIT: same rule through the two-stage path.
    d.dismissCurrent(.silent)
    let again = PillRequest.correctionProposal(
      model: model, isStillWanted: { true },
      onAccept: { _ in }, onReject: { _ in },
      onEnded: { token, reason in
        log.ended.append((token, reason))
        d.present(.warning(reason: .polishFailed))
      })
    _ = try #require(d.present(again))
    d.present(
      .recording(
        RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 }, recordingElapsedProvider: { nil },
          isLocked: false)))
    #expect(log.ended.map(\.1) == [.preempted, .preempted])
    guard case .notice? = d.renderModel.state.presentation?.content else {
      Issue.record("the recording overwrote the re-entrant warning")
      return
    }
  }

  @Test("a deferred first render is rolled back unrendered when the proposal was resolved from Pending meanwhile")
  func deferredRenderHonoursTheOwner() throws {
    final class Deferral {
      var block: (() -> Void)?
    }
    let deferral = Deferral()
    let log = Log()
    let host = WindowlessOverlayHost()
    let d = OverlayDirector(
      host: host,
      scheduler: .manual { _ in },
      announce: { log.announcements.append($0) },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { deferral.block = $0 })
    let library = WordLibraryFake()
    let telemetry = LearnTelemetrySpy()
    let (store, _, _) = makeFaultableStore()
    let saira = CustomWord(canonical: "Saira")
    library.userWords = [saira]
    let coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: library.access, presenter: nil, telemetry: telemetry)
    coordinator.initialize()
    let presenter = CorrectionProposalOverlayPresenter(host: d, coordinator: coordinator)
    coordinator.attach(presenter: presenter)

    guard
      case .minted(let id) = coordinator.propose(
        original: "sarah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    #expect(deferral.block != nil, "the first render is deferred a run loop")
    #expect(host.presented.isEmpty && log.announcements.isEmpty)
    // Pending wins the race before the run loop turns.
    #expect(coordinator.resolve(id: id, .accept, surface: .pending) == .accepted(.aliasAdded))
    deferral.block?()
    #expect(host.presented.isEmpty, "the card must never reach the screen")
    #expect(log.announcements.isEmpty, "nothing was spoken")
    #expect(telemetry.events.contains(.cardShown) == false && telemetry.events.contains(.cardExpired) == false)
    #expect(d.renderModel.state.presentation == nil && coordinator.currentPresentation.isEmpty)
    #expect(coordinator.proposal(id: id)?.status == .accepted)
  }

  @Test("Accept on the real card shows its result on the same identity for three seconds, then expires without counting; the offer check does not refuse the result")
  func resultRendersAfterAcceptThroughTheRealOwner() throws {
    let armed = Armed()
    let log = Log()
    let (d, host) = director(armed, log)
    let library = WordLibraryFake()
    let telemetry = LearnTelemetrySpy()
    let (store, _, _) = makeFaultableStore()
    let saira = CustomWord(canonical: "Saira")
    library.userWords = [saira]
    let coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: library.access, presenter: nil, telemetry: telemetry)
    coordinator.initialize()
    let presenter = CorrectionProposalOverlayPresenter(host: d, coordinator: coordinator)
    coordinator.attach(presenter: presenter)

    guard
      case .minted(let id) = coordinator.propose(
        original: "sarah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    #expect(host.presented.count == 1, "the offer is on screen")
    let receipt = try #require(d.renderModel.state.presentation.map { PillReceipt(presentationID: $0.id) })
    #expect(telemetry.events.contains(.cardShown))

    try host.sendUserActionThroughRoot(.acceptCorrectionProposal(id: id), for: receipt)
    #expect(coordinator.proposal(id: id)?.status == .accepted, "the card's Accept resolved the proposal")
    guard case .correctionProposal(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the result must stay on screen after Accept")
      return
    }
    #expect(shown.phase == .result(.saved) && shown.id == id, "same proposal, result phase")
    #expect(d.renderModel.state.presentation?.id == receipt.presentationID, "same identity, morphed in place")
    #expect(host.presented.count == 2 && host.presented.last?.isFresh == false, "the result rendered as a morph, not a fresh panel")
    #expect(log.announcements.count == 1, "the result speaks through the card's own label, not a second catalog announcement")
    let dwell = try #require(d.renderModel.state.dwell)
    #expect(dwell.id == receipt.presentationID && dwell.seconds == OverlayReducer.correctionResultDwellSeconds)

    let work = try #require(armed.work)
    work.fire()
    #expect(d.renderModel.state.presentation == nil, "the result expired and freed the slot")
    #expect(telemetry.events.contains(.cardExpired) == false, "a shown result does not count as an unanswered card")
    #expect(coordinator.currentPresentation.isEmpty)
  }

  @Test("an owner check that presents a newer pill from inside itself loses to that pill: no rollback, no render of the stale offer, whether it answers true or false")
  func ownerCheckMayReenter() throws {
    for answer in [true, false] {
      let armed = Armed()
      let log = Log()
      let (d, host) = director(armed, log)
      let model = CorrectionCardFixture.model()
      // The check raises a warning as a side effect; that warning must win.
      let request = PillRequest.correctionProposal(
        model: model,
        isStillWanted: {
          d.present(.warning(reason: .polishFailed))
          return answer
        },
        onAccept: { log.accepted.append($0) }, onReject: { log.rejected.append($0) },
        onEnded: { log.ended.append(($0, $1)) })
      let receipt = d.present(request) { log.results.append($0) }
      _ = receipt
      #expect(log.results == [.notPresented], "the stale offer owes its caller only false (answer \(answer))")
      guard case .notice(let notice)? = d.renderModel.state.presentation?.content else {
        Issue.record("the re-entrant warning is not on screen (answer \(answer))")
        return
      }
      #expect(notice.kind == .notification)
      #expect(d.renderModel.state.presentation?.id == d.renderModel.state.dwell?.id, "the warning keeps its own timer")
      #expect(host.presented.count == 1 && host.isShowing, "exactly one render: the warning")
      #expect(armed.work != nil, "the warning's expiry is armed, not cancelled by the stale offer")
      // The reducer had admitted the offer before the render, so the warning
      // preempts it there and the end is reported; the owner was answered
      // `.notPresented` and never `.presented`, so the coordinator's phase gate
      // (`presentationEnded` needs an admitted token) drops it. What must not
      // happen is a SECOND end from a rollback of the newer warning.
      #expect(log.ended.map(\.1) == [.preempted], "one reducer-level end, no rollback end (answer \(answer))")
    }
  }

  @Test("declined admission answers notPresented with no receipt and no end; a different feature holding the slot declines")
  func declinedAdmission() throws {
    let armed = Armed()
    let log = Log()
    let (d, _) = director(armed, log)
    d.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
    let receipt = d.present(request(CorrectionCardFixture.model(), log)) { log.results.append($0) }
    #expect(receipt == nil && log.results == [.notPresented])
    #expect(log.ended.isEmpty && log.accepted.isEmpty)
  }
}

// MARK: - Adapter

@MainActor
@Suite("Correction card: presenter adapter bridges the coordinator (#996 step 9)", .tags(.productOutcome))
struct CorrectionProposalOverlayPresenterTests {
  let host = CorrectionOverlayHostFake()
  let library = WordLibraryFake()
  let telemetry = LearnTelemetrySpy()
  let coordinator: CorrectionProposalCoordinator
  let presenter: CorrectionProposalOverlayPresenter
  let saira = CustomWord(canonical: "Saira")

  init() {
    let (store, _, _) = makeFaultableStore()
    library.userWords = [saira]
    coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: library.access, presenter: nil, telemetry: telemetry)
    coordinator.initialize()
    presenter = CorrectionProposalOverlayPresenter(host: host, coordinator: coordinator)
    coordinator.attach(presenter: presenter)
  }

  private func mint(_ original: String = "sarah") -> UUID {
    guard
      case .minted(let id) = coordinator.propose(
        original: original, corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: nil, sourceBundleID: nil, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return UUID()
    }
    return id
  }

  @Test("an admitted offer is reported as shown under the presentation's UUID; a click resolves through the card surface and morphs the same identity")
  func offerAdmittedAndAccepted() throws {
    let id = mint()
    let presentation = try #require(host.admitAs)
    let token = CorrectionPresentationToken(id: presentation.rawValue)
    #expect(host.requests.map(\.id) == [id])
    #expect(coordinator.currentPresentation[id] == token)
    #expect(telemetry.events.contains(.cardShown))

    let accept = try #require(host.accepts.first)
    accept(token)
    #expect(coordinator.proposal(id: id)?.status == .accepted)
    #expect(host.resolved.count == 1)
    #expect(host.resolved.first?.0 == id && host.resolved.first?.1 == presentation)
    #expect(host.resolved.first?.2 == .saved)
    #expect(library.saves.count == 1)

    // The result card timing out is not an unanswered offer.
    let ended = try #require(host.endeds.first)
    ended(token, .expired)
    #expect(telemetry.events.contains(.cardExpired) == false)
    #expect(coordinator.currentPresentation[id] == nil)
  }

  @Test("an unanswered offer that expires counts once; Escape and preemption count nothing; a stale token is ignored")
  func endsReachTheCoordinator() throws {
    let id = mint()
    let presentation = try #require(host.admitAs)
    let token = CorrectionPresentationToken(id: presentation.rawValue)
    let ended = try #require(host.endeds.first)
    ended(CorrectionPresentationToken(), .expired)
    #expect(telemetry.events.contains(.cardExpired) == false, "a token the coordinator never admitted")
    ended(token, .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1)
    ended(token, .expired)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1, "reported once")
    #expect(coordinator.proposal(id: id)?.status == .pending, "the proposal waits in Pending")

    let second = mint("sarra")
    let secondPresentation = try #require(host.admitAs)
    let secondToken = CorrectionPresentationToken(id: secondPresentation.rawValue)
    let secondEnded = try #require(host.endeds.last)
    secondEnded(secondToken, .preempted)
    #expect(telemetry.events.filter { $0 == .cardExpired }.count == 1, "preemption is not expiry")
    #expect(coordinator.proposal(id: second)?.status == .pending)
  }

  @Test("declined admission shows nothing; a deferred admission after a Pending resolution dismisses the card and counts nothing")
  func declinedAndDelayedAdmission() throws {
    host.admitAs = nil
    let refused = mint()
    #expect(host.requests.count == 1 && telemetry.events.contains(.cardShown) == false)
    #expect(coordinator.currentPresentation[refused] == nil)
    #expect(coordinator.proposal(id: refused)?.overlayAttempted == true, "the one attempt is spent")

    host.admitAs = PresentationID()
    host.deferResult = true
    let late = mint("sarra")
    #expect(host.pendingResults.count == 1)
    let wanted = try #require(host.stillWanted.last)
    #expect(wanted(), "pending: still wanted")
    #expect(coordinator.resolve(id: late, .accept, surface: .pending) == .accepted(.aliasAdded))
    #expect(wanted() == false, "resolved from Pending: the offer is no longer wanted")
    host.answerPending()
    #expect(telemetry.events.contains(.cardShown) == false)
    #expect(coordinator.currentPresentation.isEmpty)
    #expect(host.resolved.isEmpty, "no card was current to morph")
  }
}

// MARK: - View

@MainActor
@Suite("Correction card: the rendered root (#996 step 9)", .tags(.productOutcome))
struct CorrectionProposalCardViewTests {

  @Test("the offer renders at the fixed 440 width with a content height, and the result phase is shorter than the offer")
  func rendersAtFixedWidthWithContentHeight() {
    let offer = RenderedPillHarness.rootSize(for: .correctionProposal(CorrectionCardFixture.model()))
    #expect(offer.width == 440, "the card asked for 440 and drew \(offer.width)")
    #expect(offer.height > 120 && offer.height < 240, "content-driven, not a reserved frame: \(offer.height)")

    let result = RenderedPillHarness.rootSize(
      for: .correctionProposal(CorrectionCardFixture.model(phase: .result(.saved))))
    #expect(result.width == 440)
    #expect(result.height > 0 && result.height < offer.height, "the buttons, state line and dwell bar are gone")
  }

  @Test("the dwell bar draws nothing without a dwell, the remainder of a running one, and full for an exhausted one")
  func dwellBarFollowsTheDirectorsWindow() {
    let now = Date()
    #expect(CorrectionCardDwellBar.plan(for: nil, at: now) == nil, "no dwell: the bar stays empty, never completed")
    let id = PresentationID()
    let running = OverlayDwellWindow(id: id, startedAt: now.addingTimeInterval(-2), seconds: 8)
    let plan = CorrectionCardDwellBar.plan(for: running, at: now)
    #expect(plan?.start == 0.25 && plan?.remaining == 6, "two of eight seconds gone: start a quarter in, six to go")
    let exhausted = OverlayDwellWindow(id: id, startedAt: now.addingTimeInterval(-9), seconds: 8)
    #expect(CorrectionCardDwellBar.plan(for: exhausted, at: now) == .init(start: 1, remaining: 0))
  }

  @Test("the copy is the founder's mock, word for word, and the offer sentence names both spellings")
  func copyIsTheMocks() {
    let existing = CorrectionCardFixture.model()
    let spoken = CorrectionProposalCardCopy.announcement(for: existing)
    #expect(spoken.contains("sarah") && spoken.contains("Saira") && spoken.contains("Accept"))
    let line = CorrectionProposalCardCopy.stateLine(for: .existingWord(name: "Saira"))
    #expect(line.lead == "Already in your words" && line.emphasis == "adds the mishearing to it")
    let fresh = CorrectionProposalCardCopy.stateLine(for: .newWord)
    #expect(fresh.lead == "New word" && fresh.emphasis == "saved with its first mishearing")

    let newWord = CorrectionCardFixture.model(original: "sorob", corrected: "Saurabh", state: .newWord)
    #expect(CorrectionProposalCardCopy.result(.saved, for: existing).text == "\u{201C}sarah\u{201D} added to Saira.")
    #expect(
      CorrectionProposalCardCopy.result(.saved, for: newWord).text
        == "Saurabh saved. \u{201C}sorob\u{201D} now becomes Saurabh.")
    #expect(
      CorrectionProposalCardCopy.result(.alreadyInYourWords, for: existing).text
        == "Already in your words. \u{201C}sarah\u{201D} becomes Saira.")
    #expect(
      CorrectionProposalCardCopy.result(.wontAskAgain, for: existing).text
        == "Dismissed. We won\u{2019}t ask about this pair again.")
    #expect(CorrectionProposalCardCopy.result(.couldNotSave, for: existing).text == "Couldn\u{2019}t save. Try again in Pending.")
    #expect(
      CorrectionProposalCardCopy.result(.savedButNotRecorded, for: existing).text
        == "Saved, but couldn\u{2019}t record it. Check Pending.")
    #expect(CorrectionProposalCardCopy.result(.saved, for: existing).tone == .ok)
    #expect(CorrectionProposalCardCopy.result(.wontAskAgain, for: existing).tone == .dim)
    #expect(CorrectionProposalCardCopy.result(.couldNotSave, for: existing).tone == .error)
    #expect(
      CorrectionProposalCardCopy.announcement(for: CorrectionCardFixture.model(phase: .result(.saved)))
        == "\u{201C}sarah\u{201D} added to Saira.")
  }
}
