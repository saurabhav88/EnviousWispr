import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLocalPolish

/// #4845 LIFE-5 / D-G: the "AI polish download complete" pill.
///
/// **Product Outcome.** When this fails, the pill shows during Setup, covers a recording or
/// another card, is lost for good because the overlay was busy once, announces a model the user
/// already switched away from, or counts as shown when nobody saw it (so it never shows).
@MainActor
@Suite("AI polish download complete pill (#4845)", .tags(.productOutcome))
struct PolishDownloadPillTests {

  // MARK: - Reducer and catalog

  static let model = PolishDownloadPillModel(modelName: "EG-1 Mini")

  @Test("the pill takes a free idle slot only, with the ready pill's three-second dwell")
  func admission() {
    var free = OverlayReducer()
    let admitted = free.reduce(.polishDownloadComplete(Self.model))
    #expect(free.state.current?.content == .polishDownloadComplete(Self.model))
    guard case .arm(_, let seconds, _) = admitted.expiryCommand else {
      Issue.record("the pill must arm its dwell")
      return
    }
    #expect(seconds == 3)

    var busy = OverlayReducer()
    _ = busy.reduce(.pipeline(.processing(phase: .transcribing)))
    #expect(busy.reduce(.polishDownloadComplete(Self.model)).didChange == false)

    var carded = OverlayReducer()
    _ = carded.reduce(.bluetoothAwareness)
    #expect(carded.reduce(.polishDownloadComplete(Self.model)).didChange == false)
    #expect(carded.state.current?.content == .bluetoothAwareness)
  }

  @Test("the words and the spoken sentence are the approved ones")
  func copy() {
    #expect(DictationNarrator.polishDownloadCompleteTitle == "AI polish download complete")
    #expect(
      DictationNarrator.polishDownloadCompleteSubtitle(modelName: "EG-1 Mini")
        == "EG-1 Mini is on for your next dictation.")
    #expect(
      PillCatalog.announcement(for: .polishDownloadComplete(Self.model))
        == .medium("AI polish download complete. EG-1 Mini is on for your next dictation."))
    #expect(OverlayContent.polishDownloadComplete(Self.model).reChecksOwnerBeforeRender)
  }

  // MARK: - Presenter

  @MainActor
  final class Source: PolishDownloadNoticeSource {
    let modelID: LocalPolishModelID
    var pendingDownloadNotice: PolishDownloadNotice?
    var sharedServerReleases = 0
    var current = true
    var live = true
    private(set) var acknowledged: [UUID] = []
    init(_ model: LocalPolishModelID) { modelID = model }
    func isCurrent(_ notice: PolishDownloadNotice) async -> Bool {
      current && pendingDownloadNotice == notice
    }
    func isLive(_ notice: PolishDownloadNotice) -> Bool { live && pendingDownloadNotice == notice }
    func acknowledgeDownloadNotice(_ id: UUID) {
      acknowledged.append(id)
      if pendingDownloadNotice?.id == id { pendingDownloadNotice = nil }
    }
  }

  /// An overlay that admits into a free slot and can hold the first render, asking the owner's
  /// pre-render question when it lands, like the director's deferred render.
  @MainActor
  final class Overlay: OverlayPresenting {
    var slotIsFree = true
    var deferRender = false
    private var pending: [() -> Void] = []
    private(set) var requested: [PolishDownloadPillModel] = []
    private(set) var rendered: [PolishDownloadPillModel] = []
    var featureSlotIsAvailable: Bool { slotIsFree }

    func present(_ request: PillRequest) -> PillReceipt? { nil }

    func present(_ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void)
      -> PillReceipt?
    {
      guard case .polishDownloadComplete(let model, let isStillWanted) = request else {
        onResult(.notPresented)
        return nil
      }
      requested.append(model)
      guard slotIsFree else {
        onResult(.notPresented)
        return nil
      }
      let receipt = PillReceipt(presentationID: PresentationID())
      let render = { [weak self] in
        guard isStillWanted() else {
          onResult(.notPresented)
          return
        }
        self?.rendered.append(model)
        onResult(.presented(receipt))
      }
      if deferRender { pending.append(render) } else { render() }
      return receipt
    }

    func renderPending() {
      let work = pending
      pending = []
      for item in work { item() }
    }

    func update(_ update: PillUpdate) {}
    func dismissCurrent(_ mode: PillDismissal) {}
    func dismissIfCurrent(_ receipt: PillReceipt) {}
    func isCurrent(_ receipt: PillReceipt) -> Bool { false }
  }

  /// A manual clock for the retry.
  @MainActor
  final class Clock {
    private(set) var scheduled: [(Duration, @MainActor () -> Void)] = []
    func run() {
      let work = scheduled
      scheduled = []
      for (_, item) in work { item() }
    }
    var schedule: @MainActor (Duration, @escaping @MainActor () -> Void) -> Void {
      { [weak self] delay, work in self?.scheduled.append((delay, work)) }
    }
  }

  struct Rig {
    let presenter: PolishDownloadPillPresenter
    let source: Source
    let overlay: Overlay
    let clock: Clock
    let setup: Box
  }

  @MainActor
  final class Box {
    var complete = true
    var summary = false
  }

  static func notice(_ model: LocalPolishModelID = .egOne(.mini)) -> PolishDownloadNotice {
    PolishDownloadNotice(
      id: UUID(), model: model,
      endpoint: LocalPolishEndpoint(
        socketPath: "/tmp/eg1.sock", authToken: "t", contextTokens: 4096))
  }

  static func rig() -> Rig {
    let source = Source(.egOne(.mini))
    let overlay = Overlay()
    let clock = Clock()
    let box = Box()
    let presenter = PolishDownloadPillPresenter(
      overlay: overlay,
      inputs: .init(
        sources: { [source] },
        setupComplete: { box.complete },
        summaryHoldsServer: { box.summary },
        modelName: { _ in "EG-1 Mini" },
        schedule: clock.schedule, log: { _ in }))
    return Rig(presenter: presenter, source: source, overlay: overlay, clock: clock, setup: box)
  }



  @Test("nothing shows during Setup; the attempt at Setup's end shows it once and spends it")
  func waitsForSetup() async {
    let rig = Self.rig()
    let notice = Self.notice()
    rig.source.pendingDownloadNotice = notice
    rig.setup.complete = false
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.isEmpty, "the pill asked for the screen during Setup")
    rig.setup.complete = true
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.rendered == [Self.model])
    #expect(rig.source.acknowledged == [notice.id])
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.count == 1, "a spent notice showed again")
  }

  @Test("a busy slot keeps the notice and the next try shows it")
  func busySlotRetries() async {
    let rig = Self.rig()
    let notice = Self.notice()
    rig.source.pendingDownloadNotice = notice
    rig.overlay.slotIsFree = false
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.rendered.isEmpty && rig.source.acknowledged.isEmpty)
    #expect(rig.clock.scheduled.count == 1, "no retry was scheduled")
    #expect(rig.clock.scheduled.first?.0 == PolishDownloadPillPresenter.retryDelay)
    rig.overlay.slotIsFree = true
    rig.clock.run()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.rendered == [Self.model])
    #expect(rig.source.acknowledged == [notice.id])
    #expect(rig.clock.scheduled.isEmpty)
  }

  @Test(
    "a selection or server change before the first render rolls the pill back and spends nothing")
  func staleBeforeRender() async {
    let rig = Self.rig()
    let notice = Self.notice()
    rig.source.pendingDownloadNotice = notice
    rig.overlay.deferRender = true
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.count == 1)
    rig.source.live = false  // the user switched models, or the server was replaced
    rig.overlay.renderPending()
    #expect(rig.overlay.rendered.isEmpty, "a stale pill reached the screen")
    #expect(rig.source.acknowledged.isEmpty, "a pill nobody saw was counted as shown")

    // A summary taking the server during the same window does the same.
    rig.source.live = true
    rig.clock.run()
    await rig.presenter.awaitAttemptForTesting()
    rig.setup.summary = true
    rig.overlay.renderPending()
    #expect(rig.overlay.rendered.isEmpty && rig.source.acknowledged.isEmpty)
  }

  @Test("Setup reopening before the first render keeps the pill off screen")
  func setupRecheckedAtRender() async {
    let rig = Self.rig()
    rig.source.pendingDownloadNotice = Self.notice()
    rig.overlay.deferRender = true
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    rig.setup.complete = false  // Restart Setup from Diagnostics
    rig.overlay.renderPending()
    #expect(rig.overlay.rendered.isEmpty && rig.source.acknowledged.isEmpty)
  }

  @Test("a summary holding the server at the first try is waited out with the same notice")
  func summaryAtFirstTryIsWaitedOut() async {
    // When this fails, a download that finished during a meeting summary never shows its pill:
    // the release leaves the notice unchanged, so nothing new would ever ask again.
    let rig = Self.rig()
    let notice = Self.notice()
    rig.source.pendingDownloadNotice = notice
    rig.source.current = false  // the summary holds the server: not current for dictation
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.isEmpty)
    #expect(rig.clock.scheduled.count == 1, "nothing will ask again after the summary")
    rig.source.current = true  // released; the notice itself never changed
    rig.source.sharedServerReleases += 1
    rig.clock.run()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.rendered == [Self.model])
    #expect(rig.source.acknowledged == [notice.id])
  }

  @Test("a newer notice that arrives during an attempt is shown after it settles")
  func newerNoticeAfterSettle() async {
    let rig = Self.rig()
    let first = Self.notice()
    rig.source.pendingDownloadNotice = first
    rig.overlay.deferRender = true
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    let second = Self.notice()
    rig.source.pendingDownloadNotice = second  // a newer download confirmed meanwhile
    rig.presenter.attempt()  // busy: an attempt is in flight
    rig.overlay.renderPending()  // the first is no longer the pending one: rolled back
    await rig.presenter.awaitAttemptForTesting()
    rig.overlay.renderPending()
    #expect(rig.overlay.rendered == [Self.model], "the newer notice was missed")
    #expect(rig.source.acknowledged == [second.id])
  }

  @Test("a notice that is not current now is not requested, and is tried again while pending")
  func notCurrentIsNotRequested() async {
    let rig = Self.rig()
    rig.source.pendingDownloadNotice = Self.notice()
    rig.source.current = false
    rig.presenter.attempt()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.isEmpty)
    #expect(rig.clock.scheduled.count == 1)
    // Gone (spent elsewhere, or the selection changed): the retry asks nothing.
    rig.source.pendingDownloadNotice = nil
    rig.clock.run()
    await rig.presenter.awaitAttemptForTesting()
    #expect(rig.overlay.requested.isEmpty && rig.clock.scheduled.isEmpty)
  }
}
