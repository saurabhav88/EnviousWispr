import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

// DEBUG only: the suites read the presenter's DEBUG observers (`isPendingForTesting`,
// `isShowingForTesting`), which a Release build does not compile.
#if DEBUG

/// #3438 chunk 6. The card after a dictation whose AI polish did not run because its chosen
/// model is not set up. When this fails, the card shows for the wrong take, shows twice in one
/// episode, never comes back after a repair, stays after its problem was fixed, or a button
/// answers a card that is no longer on screen.
@MainActor
@Suite("AI polish setup card after a dictation (#3438)", .tags(.productOutcome))
struct PolishSetupCardPresenterTests {

  // MARK: - Overlay fake (the Bluetooth card's harness shape)

  @MainActor
  final class Overlay: OverlayPresenting {
    var slotIsFree = true
    var defersResult = false
    var deferredHostAccepts = true
    private(set) var requests = 0
    private(set) var shownModels: [PolishSetupCardModel] = []
    private(set) var currentReceipt: PillReceipt?
    private var onFinish: (() -> Void)?
    private var onNotNow: (() -> Void)?
    private var heldResult: ((PillPresentationResult) -> Void)?
    private var heldReceipt: PillReceipt?
    /// The last request's own result callback, kept so a test can make the host answer twice.
    private var lastSink: ((PillPresentationResult) -> Void)?

    var cardIsShowing: Bool { currentReceipt != nil }
    var featureSlotIsAvailable: Bool { slotIsFree }

    func present(_ request: PillRequest) -> PillReceipt? {
      guard case .polishSetupCard(let model, let finish, let notNow) = request else { return nil }
      requests += 1
      guard slotIsFree else { return nil }
      shownModels.append(model)
      onFinish = finish
      onNotNow = notNow
      let receipt = PillReceipt(presentationID: PresentationID())
      currentReceipt = receipt
      slotIsFree = false
      return receipt
    }

    @discardableResult
    func present(_ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void)
      -> PillReceipt?
    {
      lastSink = onResult
      guard let receipt = present(request) else {
        onResult(.notPresented)
        return nil
      }
      guard defersResult else {
        onResult(.presented(receipt))
        return receipt
      }
      heldResult = onResult
      heldReceipt = receipt
      return receipt
    }

    /// The director's deferred first render, with its identity gate.
    func releaseDeferredResult() {
      guard let sink = heldResult else { return }
      heldResult = nil
      let receipt = heldReceipt
      heldReceipt = nil
      guard let receipt, receipt == currentReceipt else {
        sink(.notPresented)
        return
      }
      if deferredHostAccepts {
        sink(.presented(receipt))
      } else {
        currentReceipt = nil
        slotIsFree = true
        sink(.notPresented)
      }
    }

    /// The host answers the last request AGAIN with `.presented` (a misbehaving host), through
    /// the presenter's own callback.
    func replayPresented(_ receipt: PillReceipt) {
      lastSink?(.presented(receipt))
    }

    func update(_ update: PillUpdate) {}
    func dismissCurrent(_ mode: PillDismissal) {
      currentReceipt = nil
      slotIsFree = true
    }
    func dismissIfCurrent(_ receipt: PillReceipt) {
      guard receipt == currentReceipt else { return }
      currentReceipt = nil
      slotIsFree = true
    }
    func isCurrent(_ receipt: PillReceipt) -> Bool { receipt == currentReceipt }

    func pressFinish() { onFinish?() }
    func pressNotNow() { onNotNow?() }

    /// Something else (a recording, a warning) took the slot; the callbacks survive so a stale
    /// press can be fired.
    func simulateReplacement() {
      currentReceipt = PillReceipt(presentationID: PresentationID())
      slotIsFree = false
    }
  }

  // MARK: - World

  @MainActor @Observable
  final class World {
    var onboardingComplete = true { didSet { onTransition?() } }
    var configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-test", credentialRevision: 1)
    { didSet { onTransition?() } }
    var openAIKeySaved: Bool? = false { didSet { onTransition?() } }
    var egOneInstall: EGOneInstallState = .notInstalled { didSet { onTransition?() } }
    /// #3988: EG-1's unresolved outside stop and its health (red = the restart failed).
    var egOneStop: OutsideStopContext? { didSet { onTransition?() } }
    var egOneHealth: EGOneHealth = .green { didSet { onTransition?() } }
    @ObservationIgnored var onTransition: (() -> Void)?

    var inputs: PolishSetupInputs {
      var facts = PolishSetupFacts(
        egOneInstall: egOneInstall, egOneHealth: egOneHealth,
        s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
        appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
        validationProvider: nil, cloudValidation: .idle,
        credentialRevisions: [.openAI: 1], cloudVerdicts: [:],
        openAIKeySaved: openAIKeySaved, geminiKeySaved: true, claudeKeySaved: true,
        ollamaSetup: .ready, ollamaModel: .installed)
      facts.egOneOutsideStop = egOneStop
      return PolishSetupInputs(
        onboardingComplete: onboardingComplete, configuration: configuration, facts: facts,
        ollamaLastCommitAt: nil)
    }
  }

  @MainActor
  final class Log {
    var rows: [PolishSetupPromptEvent] = []
    var opened = 0
  }

  private struct Fixture {
    let world: World
    let overlay: Overlay
    let monitor: PolishSetupMonitor
    let card: PolishSetupCardPresenter
    let log: Log
  }

  private static func fixture(keySaved: Bool? = false) -> Fixture {
    let world = World()
    world.openAIKeySaved = keySaved
    let overlay = Overlay()
    let log = Log()
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs },
      reportPrompt: { log.rows.append($0) },
      recordKeyEvidence: { _, state, _ in world.openAIKeySaved = state.asSavedFlag })
    let card = PolishSetupCardPresenter(
      overlay: overlay, monitor: monitor, openAIPolish: { log.opened += 1 }, log: { _ in })
    monitor.onEpisodeChange = { [weak card] in card?.reconcile() }
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    monitor.start()
    return Fixture(world: world, overlay: overlay, monitor: monitor, card: card, log: log)
  }

  /// A concluded take, taken in by the monitor exactly as the app's ingest hook does, then
  /// offered to the card.
  @discardableResult
  private static func conclude(
    _ fx: Fixture, result: PolishTakeResult = .skippedWithNotice,
    evidence: PolishSetupEvidence? = .cloudKeyMissing,
    tag: PolishSetupProblemTag? = .cloudKeyMissing, takeID: UUID = UUID(),
    dataLossDisclosure: Bool = false
  ) -> UUID {
    let outcome = PolishTakeOutcome(
      takeID: takeID.uuidString, context: fx.monitor.freezeTakeContext(), result: result,
      evidence: evidence, setupProblem: tag, observedAt: .now)
    if fx.monitor.ingest(outcome) {
      fx.card.offer(after: outcome, dataLossDisclosureScheduled: dataLossDisclosure)
    }
    return takeID
  }

  private static let openAIKeyMissing = PolishSetupPromptSubject(
    problem: .cloudKeyMissing(.openAI), provider: .openAI)

  // MARK: - Showing

  @Test("a confirmed setup problem shows the card once, with the take's ID and what it showed")
  func showsOncePerEpisode() throws {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    let take = Self.conclude(fx)
    #expect(fx.overlay.cardIsShowing)
    #expect(fx.overlay.shownModels == [PolishSetupCardModel(problem: .cloudKeyMissing(.openAI))])
    #expect(
      fx.log.rows == [
        PolishSetupPromptEvent(
          surface: .card, action: .shown, subject: Self.openAIKeyMissing, takeID: take)
      ])
    // Drawing the card spent the episode's allowance, before any button answered (#3442 row 44).
    #expect(fx.monitor.cardTicket() == nil, "a drawn card left the allowance unspent")
    // The same episode: no second card, even for a later take.
    fx.overlay.pressNotNow()
    Self.conclude(fx)
    #expect(fx.overlay.requests == 1)
  }

  @Test("polished, short, off, cancelled, unconfirmed or Apple takes never raise the card")
  func excludedOutcomes() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx, result: .polished, evidence: nil, tag: nil)
    Self.conclude(fx, result: .bypassed, evidence: nil, tag: nil)
    Self.conclude(fx, result: .notRequested, evidence: nil, tag: nil)
    Self.conclude(fx, result: .cancelled, evidence: nil, tag: nil)
    // Evidence the app did not confirm (an unreadable key, Gemini's text-only rejection).
    Self.conclude(fx, result: .skippedWithNotice, evidence: .cloudKeyUnreadable, tag: nil)
    Self.conclude(fx, result: .failed, evidence: .cloudKeyRejectedClassified, tag: nil)
    #expect(fx.overlay.requests == 0)
    // The monitor's own intake and ticket also refuse those takes, so ask the card's own
    // yes-or-no directly: an unconfirmed problem is declined for every skipping result, and the
    // same outcome with a confirmed problem is accepted (#3442 row 43).
    for result in [PolishTakeResult.skippedWithNotice, .failed, .skippedSilently] {
      func outcome(_ tag: PolishSetupProblemTag?) -> PolishTakeOutcome {
        PolishTakeOutcome(
          takeID: UUID().uuidString, context: fx.monitor.freezeTakeContext(), result: result,
          evidence: .cloudKeyMissing, setupProblem: tag, observedAt: .now)
      }
      #expect(PolishSetupCardPresenter.isCandidate(outcome(nil)) == false)
      #expect(PolishSetupCardPresenter.isCandidate(outcome(.cloudKeyMissing)))
    }
  }

  @Test("readiness alone never raises the card")
  func readinessAloneIsNotEnough() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    // The key is missing and the episode is open, but no take concluded.
    #expect(fx.monitor.eligibleProblem == .cloudKeyMissing(.openAI))
    fx.card.reconcile()
    #expect(fx.overlay.requests == 0)
  }

  @Test("a take whose key presence was unknown opens the episode and shows the card")
  func unknownPresenceTakeShowsTheCard() {
    // Presence unknown from launch: no episode, no warning.
    let fx = Self.fixture(keySaved: nil)
    defer { fx.monitor.stop() }
    #expect(fx.monitor.currentEpisode == nil)
    Self.conclude(fx)
    #expect(fx.monitor.currentEpisode != nil)
    #expect(fx.overlay.cardIsShowing)
  }

  @Test("refused by a busy overlay: nothing is spent or reported, and a later take tries again")
  func refusalKeepsTheAllowance() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.slotIsFree = false
    Self.conclude(fx)
    #expect(fx.overlay.requests == 1)
    #expect(fx.log.rows.isEmpty)
    #expect(fx.monitor.cardTicket() != nil, "the allowance was spent by a refusal")
    fx.overlay.slotIsFree = true
    Self.conclude(fx)
    #expect(fx.overlay.cardIsShowing)
    #expect(fx.log.rows.map(\.action) == [.shown])
  }

  @Test("a deferred first render commits once; a duplicate result spends nothing more")
  func deferredPresentation() throws {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.defersResult = true
    Self.conclude(fx)
    #expect(fx.card.isPendingForTesting)
    #expect(fx.log.rows.isEmpty, "shown before the card was drawn")
    #expect(fx.monitor.cardTicket() != nil)
    fx.overlay.releaseDeferredResult()
    #expect(fx.card.isShowingForTesting)
    #expect(fx.log.rows.map(\.action) == [.shown])
    #expect(fx.monitor.cardTicket() == nil)
    // The host repeats itself through the presenter's own callback: still one shown row, and
    // the card stays.
    let receipt = try #require(fx.overlay.currentReceipt)
    fx.overlay.replayPresented(receipt)
    #expect(fx.log.rows.map(\.action) == [.shown])
    #expect(fx.overlay.cardIsShowing)
    #expect(fx.card.isShowingForTesting)
  }

  @Test("a deferred card refused at first render keeps the allowance")
  func deferredRefusal() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.defersResult = true
    fx.overlay.deferredHostAccepts = false
    Self.conclude(fx)
    fx.overlay.releaseDeferredResult()
    #expect(fx.card.isPendingForTesting == false)
    #expect(fx.log.rows.isEmpty)
    #expect(fx.monitor.cardTicket() != nil)
  }

  // MARK: - Leaving

  @Test("a pending card whose episode ends in the same turn is cancelled and never shown")
  func pendingCardCancelledOnRepair() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.defersResult = true
    Self.conclude(fx)
    #expect(fx.card.isPendingForTesting)
    // The key is saved before the first render.
    fx.world.openAIKeySaved = true
    #expect(fx.card.isPendingForTesting == false)
    #expect(fx.overlay.cardIsShowing == false)
    fx.overlay.releaseDeferredResult()
    #expect(fx.log.rows.isEmpty)
  }

  @Test("a shown card leaves when polish is turned off, onboarding resets, or the model changes")
  func shownCardLeavesWhenItStopsApplying() {
    for change in [0, 1, 2] {
      let fx = Self.fixture()
      defer { fx.monitor.stop() }
      Self.conclude(fx)
      #expect(fx.overlay.cardIsShowing)
      switch change {
      case 0:
        fx.world.configuration = PolishSetupConfiguration(
          provider: .none, model: "", credentialRevision: nil)
      case 1:
        fx.world.onboardingComplete = false
      default:
        fx.world.configuration = PolishSetupConfiguration(
          provider: .egOne, model: "eg-1", credentialRevision: nil)
      }
      #expect(fx.overlay.cardIsShowing == false, "change \(change)")
      #expect(fx.card.isShowingForTesting == false, "change \(change)")
    }
  }

  @Test("a recording that replaced the card releases it; its buttons then do nothing")
  func replacedCardButtonsAreInert() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx)
    fx.overlay.simulateReplacement()
    let replacement = fx.overlay.currentReceipt
    // No reconcile in between: the buttons themselves must notice.
    fx.overlay.pressNotNow()
    fx.overlay.pressFinish()
    #expect(fx.log.rows.map(\.action) == [.shown])
    #expect(fx.log.opened == 0)
    #expect(fx.overlay.currentReceipt == replacement, "a stale press dismissed another occupant")
  }

  // MARK: - Answers

  @Test("Finish setup opens AI Polish once and reports what the card showed")
  func finishSetup() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    let take = Self.conclude(fx)
    fx.overlay.pressFinish()
    fx.overlay.pressFinish()
    #expect(fx.log.opened == 1)
    #expect(fx.overlay.cardIsShowing == false)
    #expect(
      fx.log.rows.last
        == PolishSetupPromptEvent(
          surface: .card, action: .finishSetup, subject: Self.openAIKeyMissing, takeID: take))
    #expect(fx.log.rows.count == 2)
    // Finish setup is not an acknowledgement of the banner or the leave pop-up.
    #expect(fx.monitor.shows(.banner))
    #expect(fx.monitor.shows(.leaveDialog))
  }

  @Test("Not now answers only the card, for the episode it showed")
  func notNow() throws {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    let take = Self.conclude(fx)
    let episode = try #require(fx.monitor.currentEpisode)
    fx.overlay.pressNotNow()
    #expect(fx.overlay.cardIsShowing == false)
    #expect(
      fx.log.rows.last
        == PolishSetupPromptEvent(
          surface: .card, action: .notNow, subject: Self.openAIKeyMissing, takeID: take))
    #expect(fx.monitor.currentEpisode == episode)
    #expect(fx.monitor.shows(.banner))
    #expect(fx.monitor.shows(.leaveDialog))
    #expect(fx.log.opened == 0)
  }

  @Test("after a repair, the same problem again is a new episode and may show the card again")
  func repairThenRecurrence() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx)
    fx.overlay.pressNotNow()
    fx.world.openAIKeySaved = true
    fx.world.openAIKeySaved = false
    Self.conclude(fx)
    #expect(fx.overlay.requests == 2)
    #expect(fx.overlay.cardIsShowing)
  }

  @Test("a local engine not downloaded shows its own reason")
  func localEngineReason() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.world.configuration = PolishSetupConfiguration(
      provider: .egOne, model: "eg-1", credentialRevision: nil)
    Self.conclude(
      fx, result: .skippedSilently, evidence: .localEngineNotReady, tag: .localNotDownloaded)
    #expect(
      fx.overlay.shownModels == [PolishSetupCardModel(problem: .localEngineNotDownloaded(.egOne))])
  }

  @Test("a dictation that also lost data shows no card; the allowance waits for a later take")
  func dataLossDisclosureWins() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx, dataLossDisclosure: true)
    #expect(fx.overlay.requests == 0)
    #expect(fx.log.rows.isEmpty)
    #expect(fx.monitor.cardTicket() != nil)
    Self.conclude(fx)
    #expect(fx.overlay.cardIsShowing)
  }

  @Test("a new recording cancels a pending card; its late first render shows nothing")
  func recordingStartCancelsPending() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.defersResult = true
    Self.conclude(fx)
    #expect(fx.card.isPendingForTesting)
    // What the take-start hook does.
    fx.card.stop()
    fx.overlay.releaseDeferredResult()
    #expect(fx.log.rows.isEmpty)
    #expect(fx.overlay.cardIsShowing == false)
    #expect(fx.monitor.cardTicket() != nil, "a cancelled card spent the allowance")
  }

  @Test("a local engine starting to download withdraws the card; the episode and its memory stay")
  func informationalStateWithdrawsTheCard() throws {
    for pendingCard in [false, true] {
      let fx = Self.fixture()
      defer { fx.monitor.stop() }
      fx.world.configuration = PolishSetupConfiguration(
        provider: .egOne, model: "eg-1", credentialRevision: nil)
      fx.overlay.defersResult = pendingCard
      Self.conclude(
        fx, result: .skippedSilently, evidence: .localEngineNotReady, tag: .localNotDownloaded)
      let episode = try #require(fx.monitor.currentEpisode)
      fx.world.egOneInstall = .downloading(fractionCompleted: 0.1, upgrade: nil)
      #expect(fx.overlay.cardIsShowing == false, "pending: \(pendingCard)")
      #expect(fx.card.isShowingForTesting == false)
      #expect(fx.card.isPendingForTesting == false)
      #expect(fx.monitor.currentEpisode == episode, "the episode ended")
      fx.overlay.releaseDeferredResult()
      #expect(fx.log.rows.filter { $0.action == .shown }.count == (pendingCard ? 0 : 1))
    }
  }

  @Test("the card reads the approved words")
  func words() {
    #expect(PolishSetupSurfaceCopy.cardTitle == "Finish setting up AI polish")
    #expect(PolishSetupSurfaceCopy.cardNotNow == "Not now")
    #expect(
      PolishSetupCardModel(problem: .cloudKeyMissing(.openAI)).line
        == "OpenAI needs an API key. Pasted without AI polish.")
    // A fragment that starts lower case after a colon elsewhere starts the card's sentence.
    #expect(
      PolishSetupCardModel(problem: .localEngineDownloadPaused(.s1Mini)).line
        == "The S1-mini download is paused. Pasted without AI polish.")
    #expect(
      PolishSetupCardModel(problem: .cloudKeyMissing(.openAI)).announcement
        == "Finish setting up AI polish. OpenAI needs an API key. Pasted without AI polish.")
    let setup = PolishSetupCardModel(problem: .cloudKeyMissing(.openAI))
    #expect(setup.primaryLabel == "Finish setup")
    #expect(setup.dismissLabel == "Not now")
    #expect(setup.variant == nil)
  }

  // MARK: - #3988: a local engine stopped outside the app

  private static let egOneSetup = PolishSetupConfiguration(
    provider: .egOne, model: "eg-1", credentialRevision: nil)

  private static func stop(
    _ generation: Int, _ pressure: OutsideStopContext.MemoryPressure? = .warning
  ) -> OutsideStopContext {
    OutsideStopContext(provider: .egOne, generation: generation, memoryPressure: pressure)
  }

  /// EG-1 installed, chosen, and stopped from outside as `stop`.
  private static func stoppedFixture(_ stop: OutsideStopContext = Self.stop(1)) -> Fixture {
    let fx = fixture()
    fx.world.egOneInstall = .installed(version: "1.2")
    fx.world.configuration = egOneSetup
    fx.world.egOneStop = stop
    return fx
  }

  /// A take that missed polish because of `stop`, taken in and offered as the app does.
  @discardableResult
  private static func concludeMiss(
    _ fx: Fixture, stop: OutsideStopContext, takeID: UUID = UUID(),
    dataLossDisclosure: Bool = false
  ) -> UUID {
    let outcome = PolishTakeOutcome(
      takeID: takeID.uuidString, context: fx.monitor.freezeTakeContext(),
      result: .skippedSilently, evidence: .localEngineNotReady, setupProblem: nil,
      observedAt: .now, outsideStopMiss: stop, outsideStopRecovery: stop)
    if fx.monitor.ingest(outcome) {
      fx.card.offer(after: outcome, dataLossDisclosureScheduled: dataLossDisclosure)
    }
    return takeID
  }

  private static func subject(_ stop: OutsideStopContext) -> PolishSetupPromptSubject {
    PolishSetupPromptSubject(problem: .localEngineStoppedOutside(.egOne, stop), provider: .egOne)
  }

  @Test("a take that missed polish shows the first notice once: its own title and words, OK only")
  func firstNoticeShowsOnce() throws {
    let fx = Self.stoppedFixture()
    defer { fx.monitor.stop() }
    let take = Self.concludeMiss(fx, stop: Self.stop(1))
    let model = try #require(fx.overlay.shownModels.last)
    #expect(model == PolishSetupCardModel(outsideStop: Self.stop(1)))
    #expect(model.title == "AI polish skipped")
    #expect(
      model.line
        == "This dictation was pasted without AI polish. Your Mac was low on memory at the time. We'll try again automatically."
    )
    #expect(model.primaryLabel == nil, "no button that would open Settings")
    #expect(model.dismissLabel == "OK")
    #expect(model.variant == .first)
    #expect(model.announcement == "\(model.title). \(model.line)")
    #expect(
      fx.log.rows
        == [
          PolishSetupPromptEvent(
            surface: .card, action: .shown, subject: Self.subject(Self.stop(1)), takeID: take)
        ])
    // Spent on appearing: another take for the same stop raises nothing.
    fx.overlay.pressNotNow()
    Self.concludeMiss(fx, stop: Self.stop(1))
    #expect(fx.overlay.requests == 1)
  }

  @Test("normal or unknown memory reads the plain sentence")
  func genericWords() {
    for pressure in [OutsideStopContext.MemoryPressure.normal, nil] {
      #expect(
        PolishSetupCardModel(outsideStop: Self.stop(1, pressure)).line
          == "This dictation was pasted without AI polish. We'll try again automatically.")
    }
  }

  @Test("OK closes the notice once, reports ok, and never opens Settings")
  func okAnswer() throws {
    let fx = Self.stoppedFixture()
    defer { fx.monitor.stop() }
    let take = Self.concludeMiss(fx, stop: Self.stop(1))
    // The setup action has no button here; a stray one does nothing.
    fx.overlay.pressFinish()
    #expect(fx.overlay.cardIsShowing)
    fx.overlay.pressNotNow()
    fx.overlay.pressNotNow()
    #expect(fx.overlay.cardIsShowing == false)
    #expect(fx.log.opened == 0)
    #expect(
      fx.log.rows.map(\.action) == [.shown, .ok]
        && fx.log.rows.last
          == PolishSetupPromptEvent(
            surface: .card, action: .ok, subject: Self.subject(Self.stop(1)), takeID: take))
  }

  @Test("the engine coming back before the first render or while shown keeps the notice")
  func readinessKeepsTheNotice() throws {
    let fx = Self.stoppedFixture()
    defer { fx.monitor.stop() }
    fx.overlay.defersResult = true
    Self.concludeMiss(fx, stop: Self.stop(1))
    #expect(fx.card.isPendingForTesting)
    fx.world.egOneStop = nil
    #expect(fx.card.isPendingForTesting, "ready before the first render cancelled the notice")
    fx.overlay.releaseDeferredResult()
    #expect(fx.card.isShowingForTesting)
    #expect(fx.overlay.shownModels.last?.line.contains("low on memory") == true, "frozen words")
    fx.world.egOneHealth = .green
    fx.card.reconcile()
    #expect(fx.card.isShowingForTesting, "a shown notice left because the engine is back")
  }

  @Test("a refused, cancelled or replayed notice spends nothing; each new stop gets its own")
  func spendingRules() throws {
    let fx = Self.stoppedFixture()
    defer { fx.monitor.stop() }
    fx.overlay.slotIsFree = false
    Self.concludeMiss(fx, stop: Self.stop(1))
    #expect(fx.log.rows.isEmpty)
    // A data-loss disclosure follows this dictation: not offered, still owed.
    fx.overlay.slotIsFree = true
    Self.concludeMiss(fx, stop: Self.stop(1), dataLossDisclosure: true)
    #expect(fx.overlay.requests == 1)
    // The allowance was kept: the next take for the same stop shows it, once.
    let take = Self.concludeMiss(fx, stop: Self.stop(1))
    #expect(fx.card.isShowingForTesting)
    let receipt = try #require(fx.overlay.currentReceipt)
    fx.overlay.replayPresented(receipt)
    #expect(fx.log.rows.filter { $0.action == .shown }.count == 1)
    #expect(fx.log.rows.last?.takeID == take)
    fx.overlay.pressNotNow()

    // A second physical stop: its own notice.
    fx.world.egOneStop = Self.stop(2, nil)
    Self.concludeMiss(fx, stop: Self.stop(2, nil))
    #expect(fx.card.isShowingForTesting)
    #expect(
      fx.overlay.shownModels.last?.line
        == "This dictation was pasted without AI polish. We'll try again automatically.")
  }

  @Test("onboarding reset, another model or a failed restart withdraws the notice")
  func withdrawal() throws {
    let pending = Self.stoppedFixture()
    defer { pending.monitor.stop() }
    pending.overlay.defersResult = true
    Self.concludeMiss(pending, stop: Self.stop(1))
    pending.world.onboardingComplete = false
    #expect(pending.card.isPendingForTesting == false)
    pending.overlay.releaseDeferredResult()
    #expect(pending.log.rows.isEmpty, "a cancelled notice spent the allowance")

    let shown = Self.stoppedFixture()
    defer { shown.monitor.stop() }
    Self.concludeMiss(shown, stop: Self.stop(1))
    #expect(shown.card.isShowingForTesting)
    shown.world.egOneHealth = .red(reason: "crashed_twice")
    #expect(shown.card.isShowingForTesting == false, "a failed restart has its own status")

    let switched = Self.stoppedFixture()
    defer { switched.monitor.stop() }
    Self.concludeMiss(switched, stop: Self.stop(1))
    switched.world.configuration = PolishSetupConfiguration(
      provider: .s1Mini, model: "s1-mini", credentialRevision: nil)
    #expect(switched.card.isShowingForTesting == false)
  }
}

/// #3438 chunk 6. The same card through the REAL overlay director: its admission, refusal and
/// replacement rules, and a button pressed through the root view's own event path.
@MainActor
@Suite("AI polish setup card on the real overlay (#3438)", .tags(.productOutcome))
struct PolishSetupCardOverlayTests {

  private struct Fixture {
    let overlay: OverlayDirector
    let host: WindowlessOverlayHost
    let world: PolishSetupCardPresenterTests.World
    let monitor: PolishSetupMonitor
    let card: PolishSetupCardPresenter
    let rows: () -> [PolishSetupPromptEvent.Action]
  }

  @MainActor
  final class Rows {
    var actions: [PolishSetupPromptEvent.Action] = []
  }

  private static func fixture() -> Fixture {
    let (overlay, host) = OverlayTestDouble.headlessDirectorWithHost()
    let world = PolishSetupCardPresenterTests.World()
    let rows = Rows()
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs }, reportPrompt: { rows.actions.append($0.action) })
    let card = PolishSetupCardPresenter(
      overlay: overlay, monitor: monitor, openAIPolish: {}, log: { _ in })
    monitor.onEpisodeChange = { [weak card] in card?.reconcile() }
    monitor.start()
    return Fixture(
      overlay: overlay, host: host, world: world, monitor: monitor, card: card,
      rows: { rows.actions })
  }

  private static func conclude(_ fx: Fixture) {
    let outcome = PolishTakeOutcome(
      takeID: UUID().uuidString, context: fx.monitor.freezeTakeContext(),
      result: .skippedWithNotice, evidence: .cloudKeyMissing, setupProblem: .cloudKeyMissing,
      observedAt: .now)
    if fx.monitor.ingest(outcome) {
      fx.card.offer(after: outcome, dataLossDisclosureScheduled: false)
    }
  }

  private static func showsCard(_ overlay: OverlayDirector) -> Bool {
    if case .polishSetupCard? = overlay.renderModel.state.presentation?.content { return true }
    return false
  }

  @Test("#3988: the first notice on the real overlay reads what it shows, and OK closes it")
  func outsideStopNoticeOnTheRealOverlay() throws {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    let stop = OutsideStopContext(provider: .egOne, generation: 1, memoryPressure: .critical)
    fx.world.egOneInstall = .installed(version: "1.2")
    fx.world.configuration = PolishSetupConfiguration(
      provider: .egOne, model: "eg-1", credentialRevision: nil)
    fx.world.egOneStop = stop
    let outcome = PolishTakeOutcome(
      takeID: UUID().uuidString, context: fx.monitor.freezeTakeContext(),
      result: .skippedSilently, evidence: .localEngineNotReady, setupProblem: nil,
      observedAt: .now, outsideStopMiss: stop)
    #expect(fx.monitor.ingest(outcome))
    fx.card.offer(after: outcome, dataLossDisclosureScheduled: false)
    guard case .polishSetupCard(let model)? = fx.overlay.renderModel.state.presentation?.content
    else {
      Issue.record("the notice was not admitted")
      return
    }
    #expect(model == PolishSetupCardModel(outsideStop: stop))
    #expect(
      PillCatalog.announcement(for: .polishSetupCard(model)) == .medium(model.announcement),
      "VoiceOver reads the notice's own title and words")
    try fx.host.sendCurrentUserActionThroughRoot(.dismissPolishSetup)
    #expect(fx.overlay.renderModel.state.presentation == nil)
    #expect(fx.rows() == [.shown, .ok])
  }

  @Test("an idle overlay admits the card; Not now through the root view removes it")
  func admittedAndAnswered() throws {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx)
    #expect(Self.showsCard(fx.overlay))
    #expect(fx.rows() == [.shown])
    try fx.host.sendCurrentUserActionThroughRoot(.dismissPolishSetup)
    #expect(fx.overlay.renderModel.state.presentation == nil)
    #expect(fx.rows() == [.shown, .notNow])
  }

  @Test("the Bluetooth card holding the slot refuses it; nothing is spent")
  func refusedByAnotherFeature() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    fx.overlay.present(.bluetoothAwareness(onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
    Self.conclude(fx)
    guard case .bluetoothAwareness? = fx.overlay.renderModel.state.presentation?.content else {
      Issue.record("the card displaced the Bluetooth card")
      return
    }
    #expect(fx.rows().isEmpty)
    #expect(fx.monitor.cardTicket() != nil)
  }

  @Test("a warning pill or a recording replaces the card, and the card lets go")
  func replacedByThePipeline() {
    let fx = Self.fixture()
    defer { fx.monitor.stop() }
    Self.conclude(fx)
    #expect(Self.showsCard(fx.overlay))
    fx.overlay.present(.warning(reason: .polishFailed))
    #expect(Self.showsCard(fx.overlay) == false)
    fx.card.reconcile()
    #expect(fx.card.isShowingForTesting == false)
  }
}

#endif
