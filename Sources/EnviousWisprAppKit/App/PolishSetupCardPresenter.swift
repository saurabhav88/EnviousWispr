import EnviousWisprCore
import Foundation

/// The card after a dictation whose AI polish did not run because its chosen model is not set
/// up (#3438, plan §3.4). At most one shown per warning episode; offered only for a concluded
/// take the warning owner took in, whose typed outcome confirmed the problem.
///
/// Ownership follows the Bluetooth card (`BluetoothAwarenessPresenter`): a request the overlay
/// admitted but has not drawn yet is PENDING; once drawn it is CURRENT. Only a drawn card
/// spends the episode's allowance and reports `shown`, and only while its ticket is still live.
/// Every card freezes what it showed (the take, the ticket, the problem and provider), so its
/// buttons and rows describe that card even after settings change. A limb: when it fails, a
/// reminder is missing; dictation is unaffected.
@MainActor
final class PolishSetupCardPresenter {
  /// What one card is about, frozen when it was offered: the take, the permission it was
  /// raised under, its subject and the exact words it shows.
  struct Card: Equatable {
    /// A setup card spends its warning episode's allowance; an outside-stop notice (#3988)
    /// spends the allowance its stopped engine earned.
    enum Ticket: Equatable {
      case setup(PolishSetupCardTicket)
      case outsideStop(OutsideStopNoticeTicket)
    }

    let takeID: UUID
    let ticket: Ticket
    let subject: PolishSetupPromptSubject
    let model: PolishSetupCardModel
  }

  enum Answer {
    case finishSetup
    case notNow
    /// #3988: closes an outside-stop notice.
    case ok
    /// #3988: the repeat notice's button: opens AI Polish to pick another engine.
    case chooseEngine
  }

  private let overlay: any OverlayPresenting
  private let monitor: PolishSetupMonitor
  private let openAIPolish: @MainActor () -> Void
  private let log: @MainActor (String) -> Void

  /// Admitted, waiting for its first render.
  private var pending: (attempt: UInt64, card: Card, receipt: PillReceipt?)?
  /// On screen.
  private var current: (attempt: UInt64, card: Card, receipt: PillReceipt)?
  private var attempts: UInt64 = 0
  private var reconciling = false

  init(
    overlay: any OverlayPresenting, monitor: PolishSetupMonitor,
    openAIPolish: @escaping @MainActor () -> Void,
    log: @escaping @MainActor (String) -> Void = PolishSetupCardPresenter.appLog
  ) {
    self.overlay = overlay
    self.monitor = monitor
    self.openAIPolish = openAIPolish
    self.log = log
  }

  // MARK: - Offer

  /// Whether a concluded take's outcome may raise the card: a confirmed (actionable) setup
  /// problem that actually kept polish from running. Readiness alone never raises it.
  static func isCandidate(_ outcome: PolishTakeOutcome) -> Bool {
    guard outcome.setupProblem != nil else { return false }
    switch outcome.result {
    case .skippedSilently, .skippedWithNotice, .failed: return true
    case .notRequested, .polished, .bypassed, .cancelled: return false
    }
  }

  /// Called with a take the warning owner has just TAKEN IN (its stale and duplicate checks
  /// passed). Asks the overlay once; a refusal keeps the allowance for a later take. When the
  /// same completion scheduled a data-loss disclosure (`dataLossDisclosureScheduled`), that
  /// disclosure replaces anything shown now, so no card is offered and the allowance waits.
  /// #3988: a take that missed polish because the engine was stopped from outside raises the
  /// outside-stop notice instead, under the monitor's frozen-miss rules.
  func offer(after outcome: PolishTakeOutcome, dataLossDisclosureScheduled: Bool) {
    let missedOutsideStop = PolishSetupMonitor.outsideStopMissed(outcome) != nil
    guard missedOutsideStop || Self.isCandidate(outcome) else { return }
    guard dataLossDisclosureScheduled == false else {
      log("card not offered: a data-loss disclosure follows this dictation")
      return
    }
    guard pending == nil, current == nil else {
      log("card not offered: one is already pending or shown")
      return
    }
    guard let takeID = UUID(uuidString: outcome.takeID) else {
      // No card without its join key: a card row must name its take.
      log("card not offered: take id is not a UUID")
      return
    }
    let card: Card
    if missedOutsideStop {
      guard let ticket = monitor.outsideStopNoticeTicket(for: outcome) else {
        log("outside-stop notice not offered: not earned, already shown, or no longer applies")
        return
      }
      let stop = ticket.stop
      card = Card(
        takeID: takeID, ticket: .outsideStop(ticket),
        subject: PolishSetupPromptSubject(
          problem: .localEngineStoppedOutside(stop.provider, stop), provider: stop.provider),
        model: PolishSetupCardModel(outsideStop: stop, variant: ticket.variant))
    } else {
      // The ticket and subject are read AFTER ingestion, so a take that started with no episode
      // (an unknown key presence its own read resolved) can raise the episode's card.
      guard let ticket = monitor.cardTicket(), let subject = monitor.promptSubject else {
        log("card not offered: not eligible (answered, spent, or nothing to show)")
        return
      }
      card = Card(
        takeID: takeID, ticket: .setup(ticket), subject: subject,
        model: PolishSetupCardModel(problem: subject.problem))
    }
    attempts &+= 1
    let attempt = attempts
    var settledSynchronously = false
    let dismissAnswer: Answer = card.model.variant == nil ? .notNow : .ok
    let primaryAnswer: Answer = card.model.variant == nil ? .finishSetup : .chooseEngine
    let admitted = overlay.present(
      .polishSetupCard(
        model: card.model,
        onFinishSetup: { [weak self] in self?.answer(primaryAnswer, attempt: attempt) },
        onNotNow: { [weak self] in self?.answer(dismissAnswer, attempt: attempt) }),
      onResult: { [weak self] result in
        // One result per request: a repeated answer from the host settles nothing again.
        guard settledSynchronously == false else { return }
        settledSynchronously = true
        self?.settle(result, attempt: attempt, card: card)
      })
    if !settledSynchronously {
      pending = (attempt, card, admitted)
      log("card admitted, waiting for its first render")
    }
  }

  private func settle(_ result: PillPresentationResult, attempt: UInt64, card: Card) {
    // Only the newest attempt clears the pending slot; an older result settles nothing else.
    if pending?.attempt == attempt { pending = nil }
    guard attempt == attempts else {
      // A cancelled attempt that still reached the screen is removed, never left unowned.
      if case .presented(let receipt) = result { overlay.dismissIfCurrent(receipt) }
      return
    }
    guard case .presented(let receipt) = result else {
      log("card refused by the overlay; the allowance is kept")
      return
    }
    // Spend only while the ticket is live: a card drawn after its episode ended is withdrawn.
    guard spend(card.ticket) else {
      overlay.dismissIfCurrent(receipt)
      log("card withdrawn at first render: its episode no longer applies")
      return
    }
    current = (attempt, card, receipt)
    monitor.recordPrompt(
      .card, .shown, subject: card.subject, takeID: card.takeID, variant: card.model.variant)
    log("card shown")
  }

  // MARK: - Answers

  private func answer(_ answer: Answer, attempt: UInt64) {
    // Bound to the card that drew the button, still on screen, and acted on at most once.
    reconcile()
    guard let shown = current, shown.attempt == attempt else { return }
    // Each card answers only with its own buttons: a notice has no setup action, and only the
    // repeat notice has Choose engine.
    let reported: PolishSetupPromptEvent.Action
    switch (answer, shown.card.ticket) {
    case (.finishSetup, .setup): reported = .finishSetup
    case (.notNow, .setup): reported = .notNow
    case (.ok, .outsideStop): reported = .ok
    case (.chooseEngine, .outsideStop(let notice)) where notice.variant == .escalated:
      reported = .chooseEngine
    case (.finishSetup, .outsideStop), (.notNow, .outsideStop), (.ok, .setup),
      (.chooseEngine, .setup), (.chooseEngine, .outsideStop):
      return
    }
    current = nil
    overlay.dismissIfCurrent(shown.receipt)
    monitor.recordPrompt(
      .card, reported, subject: shown.card.subject, takeID: shown.card.takeID,
      variant: shown.card.model.variant)
    switch shown.card.ticket {
    case .setup(let ticket):
      if answer == .finishSetup {
        openAIPolish()
      } else {
        // Only the card, only for the episode it showed.
        monitor.acknowledge(.card, in: ticket.episode)
      }
    case .outsideStop:
      // The notice was spent when it appeared. Choose engine opens AI Polish, where provider
      // requirements and setup status are shown; OK only closes it.
      if answer == .chooseEngine { openAIPolish() }
    }
  }

  private func spend(_ ticket: Card.Ticket) -> Bool {
    switch ticket {
    case .setup(let setup): return monitor.cardPresented(setup)
    case .outsideStop(let notice): return monitor.outsideStopNoticePresented(notice)
    }
  }

  private func stillApplies(_ ticket: Card.Ticket) -> Bool {
    switch ticket {
    case .setup(let setup): return monitor.cardStillApplies(setup)
    case .outsideStop(let notice): return monitor.outsideStopNoticeStillApplies(notice)
    }
  }

  // MARK: - Invalidation

  /// The warning owner's episode state changed (told synchronously): a pending or shown card
  /// whose episode ended, whose eligibility was lost (polish off, onboarding reset, a new
  /// provider, model or key, a confirmed repair) leaves now. A card the overlay already
  /// replaced (a recording, another feature) is released without touching the slot.
  func reconcile() {
    guard !reconciling else { return }
    reconciling = true
    defer { reconciling = false }
    if let waiting = pending, !stillApplies(waiting.card.ticket) {
      pending = nil
      attempts &+= 1  // the outstanding result can no longer commit
      if let receipt = waiting.receipt { overlay.dismissIfCurrent(receipt) }
      log("pending card cancelled: its episode no longer applies")
    }
    if let shown = current {
      if !overlay.isCurrent(shown.receipt) {
        current = nil
      } else if !stillApplies(shown.card.ticket) {
        current = nil
        overlay.dismissIfCurrent(shown.receipt)
        log("shown card withdrawn: its episode no longer applies")
      }
    }
  }

  /// App teardown: no result or button may act after this.
  func stop() {
    attempts &+= 1
    if let waiting = pending, let receipt = waiting.receipt { overlay.dismissIfCurrent(receipt) }
    if let shown = current { overlay.dismissIfCurrent(shown.receipt) }
    pending = nil
    current = nil
  }

  #if DEBUG
    var isPendingForTesting: Bool { pending != nil }
    var isShowingForTesting: Bool { current != nil }
  #endif

  static func appLog(_ message: String) {
    Task {
      await AppLogger.shared.log(
        "polish setup card: \(message)", level: .info, category: "PolishSetup")
    }
  }
}
