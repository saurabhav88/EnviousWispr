import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #3546 A3: the Parakeet Ultra upgrade pills (downloading, installing, ready). When these
/// fail, an upgrade pill covers a recording or another card, the download line restarts the
/// pill's dwell or brings back a pill that already left, a pill counts as shown when nobody
/// saw it, or a new user is told about an upgrade they never had.
@MainActor
@Suite("Parakeet Ultra upgrade pills (#3546 A3)", .tags(.productOutcome))
struct ParakeetUpgradePillTests {

  static func model(_ phase: ParakeetUpgradePillModel.Phase) -> ParakeetUpgradePillModel {
    ParakeetUpgradePillModel(phase: phase)
  }

  // MARK: - Reducer admission

  @Test("an upgrade pill takes a free slot, never a busy pipeline or another card")
  func admission() {
    var free = OverlayReducer()
    let admitted = free.reduce(.parakeetUpgrade(Self.model(.downloading(fraction: 0))))
    #expect(admitted.didChange)
    guard case .parakeetUpgrade? = free.state.current?.content else {
      Issue.record("the downloading pill did not take the free slot")
      return
    }

    var busy = OverlayReducer()
    _ = busy.reduce(.pipeline(.processing(phase: .transcribing)))
    #expect(busy.reduce(.parakeetUpgrade(Self.model(.ready))).didChange == false)

    var carded = OverlayReducer()
    _ = carded.reduce(.bluetoothAwareness)
    #expect(carded.reduce(.parakeetUpgrade(Self.model(.ready))).didChange == false)
    #expect(carded.state.current?.content == .bluetoothAwareness)

    // A notice another feature may replace still holds the user's text here.
    var retained = OverlayReducer()
    _ = retained.reduce(.retainedClipboardFallback(takeID: "take-1"))
    let notice = retained.state.current
    #expect(retained.reduce(.parakeetUpgrade(Self.model(.ready))).didChange == false)
    #expect(retained.state.current == notice)
  }

  @Test("a pipeline presentation replaces an upgrade pill, and an upgrade pill replaces its own")
  func replacement() {
    var reducer = OverlayReducer()
    _ = reducer.reduce(.parakeetUpgrade(Self.model(.installing)))
    let installingID = reducer.state.current?.id
    _ = reducer.reduce(.parakeetUpgrade(Self.model(.ready)))
    #expect(reducer.state.current?.id != installingID)
    #expect(reducer.state.current?.content == .parakeetUpgrade(Self.model(.ready)))

    _ = reducer.reduce(.pipeline(.warning(reason: .polishFailed)))
    guard case .notice? = reducer.state.current?.content else {
      Issue.record("a pipeline warning must replace the upgrade pill")
      return
    }
  }

  @Test("progress morphs the downloading pill in place and leaves its dwell armed")
  func progressMorphs() {
    var reducer = OverlayReducer()
    let first = reducer.reduce(.parakeetUpgrade(Self.model(.downloading(fraction: 0.1))))
    guard case .arm(_, let seconds, _) = first.expiryCommand else {
      Issue.record("the downloading pill must arm its dwell")
      return
    }
    #expect(seconds == 6)
    let id = reducer.state.current?.id
    let plan = reducer.reduce(.parakeetUpgradeProgress(fraction: 0.4))
    #expect(plan.didChange)
    #expect(plan.expiryCommand == .unchanged, "a progress tick must not restart the dwell")
    #expect(reducer.state.current?.id == id)
    #expect(
      reducer.state.current?.content == .parakeetUpgrade(Self.model(.downloading(fraction: 0.4))))
  }

  @Test("progress never brings back a pill that left, and never morphs another pill")
  func progressIsInert() {
    var empty = OverlayReducer()
    #expect(empty.reduce(.parakeetUpgradeProgress(fraction: 0.5)).didChange == false)
    #expect(empty.state.current == nil)

    var ready = OverlayReducer()
    _ = ready.reduce(.parakeetUpgrade(Self.model(.ready)))
    #expect(ready.reduce(.parakeetUpgradeProgress(fraction: 0.5)).didChange == false)

    var expired = OverlayReducer()
    _ = expired.reduce(.parakeetUpgrade(Self.model(.downloading(fraction: 0.1))))
    let id = try? #require(expired.state.current?.id)
    if let id { _ = expired.reduce(.expiryFired(id)) }
    #expect(expired.state.current == nil)
    #expect(expired.reduce(.parakeetUpgradeProgress(fraction: 0.9)).didChange == false)
    #expect(expired.state.current == nil)
  }

  @Test("the installing pill waits for its replacement; ready leaves after three seconds")
  func expiries() {
    var installing = OverlayReducer()
    #expect(installing.reduce(.parakeetUpgrade(Self.model(.installing))).expiryCommand == .cancel)
    var ready = OverlayReducer()
    guard
      case .arm(_, let seconds, _) = ready.reduce(.parakeetUpgrade(Self.model(.ready)))
        .expiryCommand
    else {
      Issue.record("the ready pill must arm a dwell")
      return
    }
    #expect(seconds == 3)
  }

  @Test("the pills say the approved words and are announced")
  func copy() {
    #expect(
      DictationNarrator.parakeetUpgradeTitle(for: .downloading(fraction: 0))
        == "Downloading Parakeet Ultra")
    #expect(
      DictationNarrator.parakeetUpgradeSubtitle(for: .downloading(fraction: 0))
        == "Keep dictating. We’ll switch when it’s ready.")
    #expect(
      DictationNarrator.parakeetUpgradeTitle(for: .installing) == "Installing Parakeet Ultra…")
    #expect(DictationNarrator.parakeetUpgradeSubtitle(for: .installing) == "Ready in a few seconds")
    #expect(DictationNarrator.parakeetUpgradeTitle(for: .ready) == "Parakeet Ultra is ready")
    #expect(DictationNarrator.parakeetUpgradeSubtitle(for: .ready) == "Press to dictate")
    let entry = PillCatalog.entry(
      for: .parakeetUpgrade(Self.model(.installing)), id: PresentationID())
    #expect(entry.announcement?.text == "Installing Parakeet Ultra. Ready in a few seconds")
  }

  // MARK: - Presenter

  @MainActor
  final class Overlay: OverlayPresenting {
    var slotIsFree = true
    var hostAccepts = true
    /// Holds `.presented` until `deliverPendingResults()`, like a deferred first render.
    var deferResults = false
    private var pendingResults: [() -> Void] = []
    private(set) var presented: [ParakeetUpgradePillModel] = []
    private(set) var progress: [Double] = []
    private(set) var current: PillReceipt?

    var featureSlotIsAvailable: Bool { slotIsFree }

    func present(_ request: PillRequest) -> PillReceipt? {
      guard case .parakeetUpgrade(let model, _) = request, slotIsFree else { return nil }
      presented.append(model)
      let receipt = PillReceipt(presentationID: PresentationID())
      current = receipt
      return receipt
    }

    func present(_ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void)
      -> PillReceipt?
    {
      guard let receipt = present(request), hostAccepts else {
        onResult(.notPresented)
        return nil
      }
      if deferResults {
        pendingResults.append { onResult(.presented(receipt)) }
      } else {
        onResult(.presented(receipt))
      }
      return receipt
    }

    func deliverPendingResults() {
      let results = pendingResults
      pendingResults = []
      for result in results { result() }
    }

    func update(_ update: PillUpdate) {
      if case .parakeetUpgradeProgress(let fraction) = update { progress.append(fraction) }
    }
    func dismissCurrent(_ mode: PillDismissal) { current = nil }
    func dismissIfCurrent(_ receipt: PillReceipt) { if current == receipt { current = nil } }
    func isCurrent(_ receipt: PillReceipt) -> Bool { current == receipt }
    func expire() { current = nil }
  }

  static func defaults() -> UserDefaults {
    TestDefaults.suite("test.upgrade-pills.\(UUID().uuidString)")!
  }

  static func downloading(_ fraction: Double) -> ParakeetUpgradeCoordinator.BackgroundUpgradeState {
    .downloading(fraction: fraction, bytesWritten: 1, totalBytes: 100)
  }

  static func activated(
    _ model: ParakeetModel, trigger: ParakeetUpgradeCoordinator.SelectionTrigger
  ) -> ParakeetUpgradeCoordinator.Outcome {
    .activated(
      ParakeetUpgradeCoordinator.LoadFacts(
        selection: ParakeetModelSelection(
          model: model, revision: "95eaa59a", directory: URL(fileURLWithPath: "/tmp/x"),
          cacheOnly: true, displayBytes: 1, repairable: false, generation: 1),
        priorModel: .v3, attempts: 1, loadMilliseconds: 10, trigger: trigger))
  }

  @Test("the downloading pill shows once; later progress moves its line only while it is current")
  func downloadingOnceWithProgress() {
    let overlay = Overlay()
    let defaults = Self.defaults()
    let presenter = ParakeetUpgradePillPresenter(
      overlay: overlay, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    presenter.backgroundUpgradeChanged(Self.downloading(0))
    presenter.backgroundUpgradeChanged(Self.downloading(0.3))
    #expect(overlay.presented.count == 1)
    #expect(overlay.progress == [0.3])
    overlay.expire()
    presenter.backgroundUpgradeChanged(Self.downloading(0.6))
    #expect(overlay.presented.count == 1, "never brought back after it left")
    #expect(overlay.progress == [0.3])

    let relaunched = ParakeetUpgradePillPresenter(
      overlay: overlay, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    relaunched.backgroundUpgradeChanged(Self.downloading(0.7))
    #expect(overlay.presented.count == 1, "shown once per Ultra revision, across launches")
  }

  @Test("the downloading pill leaves when the download stops, and a late render spends nothing")
  func downloadStopRemovesThePill() {
    let overlay = Overlay()
    let defaults = Self.defaults()
    let presenter = ParakeetUpgradePillPresenter(
      overlay: overlay, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    presenter.backgroundUpgradeChanged(Self.downloading(0.2))
    #expect(overlay.current != nil)
    presenter.backgroundUpgradeChanged(.declined)
    #expect(overlay.current == nil, "Cancel takes the downloading pill away")

    // The host renders after the download already stopped.
    let late = Overlay()
    late.deferResults = true
    let lateDefaults = Self.defaults()
    let latePresenter = ParakeetUpgradePillPresenter(
      overlay: late, targetCacheKey: "ultra-key", defaults: lateDefaults, isUltraReady: { true }, log: { _ in })
    latePresenter.backgroundUpgradeChanged(Self.downloading(0.2))
    latePresenter.backgroundUpgradeChanged(.idle)
    late.deliverPendingResults()
    #expect(late.current == nil)
    #expect(
      lateDefaults.bool(
        forKey: ParakeetUpgradePillPresenter.shownKey(.downloading, cacheKey: "ultra-key"))
        == false)
  }

  // MARK: - Real director, deferred first render

  let clock = LearnedPillClock()
  let host = WindowlessOverlayHost()

  /// A real director whose first render runs when the test says so.
  func director(_ announcements: Box<[OverlayAnnouncement]>) -> (
    OverlayDirector, () -> (() -> Void)?
  ) {
    var deferred: (() -> Void)?
    let d = OverlayDirector(
      host: host, scheduler: clock.scheduler,
      announce: { announcements.value.append($0) },
      livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {},
      advisoryHint: { _ in nil }, selections: { .shipped },
      firstRenderSchedule: { deferred = $0 })
    return (d, { deferred })
  }

  @MainActor
  final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
  }

  static func isShowingUpgrade(_ d: OverlayDirector) -> Bool {
    if case .parakeetUpgrade? = d.renderModel.state.presentation?.content { return true }
    return false
  }

  @Test("a Cancel before the first render: no downloading pill is drawn or spoken, nothing spent")
  func cancelBeforeFirstRenderProducesNoFrameOrAnnouncement() throws {
    let announcements = Box<[OverlayAnnouncement]>([])
    let (d, deferred) = director(announcements)
    let defaults = Self.defaults()
    let presenter = ParakeetUpgradePillPresenter(
      overlay: d, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    presenter.backgroundUpgradeChanged(Self.downloading(0.1))
    presenter.backgroundUpgradeChanged(.declined)
    let render = try #require(deferred())
    render()
    #expect(Self.isShowingUpgrade(d) == false)
    #expect(announcements.value.isEmpty)
    #expect(
      defaults.bool(
        forKey: ParakeetUpgradePillPresenter.shownKey(.downloading, cacheKey: "ultra-key"))
        == false)

    // Control: the same path without the Cancel draws, speaks and spends once.
    let spoken = Box<[OverlayAnnouncement]>([])
    let (shown, shownRender) = director(spoken)
    let shownDefaults = Self.defaults()
    let shownPresenter = ParakeetUpgradePillPresenter(
      overlay: shown, targetCacheKey: "ultra-key", defaults: shownDefaults, isUltraReady: { true }, log: { _ in })
    shownPresenter.backgroundUpgradeChanged(Self.downloading(0.1))
    let renderShown = try #require(shownRender())
    renderShown()
    #expect(Self.isShowingUpgrade(shown))
    #expect(spoken.value.count == 1)
    #expect(
      shownDefaults.bool(
        forKey: ParakeetUpgradePillPresenter.shownKey(.downloading, cacheKey: "ultra-key")))
  }

  @Test("Ultra unloaded before the first render: no ready pill is drawn or spoken, nothing spent")
  func readyNotDrawnOnceUltraIsNoLongerReady() throws {
    let announcements = Box<[OverlayAnnouncement]>([])
    let (d, deferred) = director(announcements)
    let defaults = Self.defaults()
    var ultraReady = true
    let presenter = ParakeetUpgradePillPresenter(
      overlay: d, targetCacheKey: "ultra-key", defaults: defaults,
      isUltraReady: { ultraReady }, log: { _ in })
    presenter.observe(Self.activated(.ultra, trigger: .backgroundAdmission))
    ultraReady = false
    let render = try #require(deferred())
    render()
    #expect(Self.isShowingUpgrade(d) == false)
    #expect(announcements.value.isEmpty)
    #expect(
      defaults.bool(forKey: ParakeetUpgradePillPresenter.shownKey(.ready, cacheKey: "ultra-key"))
        == false)
  }

  /// When this fails, a press during the switch leaves "Installing Parakeet Ultra…" on screen
  /// forever, or the press's waiter removes the "Parakeet Ultra is ready" pill that replaced it.
  @Test("a press during the switch shows Installing, which leaves when the switch settles")
  func pressDuringActivationShowsAndClearsInstalling() async throws {
    let (released, release) = AsyncStream<Void>.makeStream()
    func waitForRelease() async -> EngineCoordinator.PressReadiness {
      for await _ in released { break }
      return .ready
    }

    // Settled with Installing still current: the waiter removes its own pill.
    let quiet = Box<[OverlayAnnouncement]>([])
    let (d, deferred) = director(quiet)
    let waiter = ColdPressGuard.reconcileParakeetUpgrade(
      overlay: d, model: nil, isActivating: { true }, ensureSelectedReady: waitForRelease)
    let render = try #require(deferred())
    render()
    guard case .parakeetUpgrade(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the Installing pill did not render")
      return
    }
    #expect(shown.phase == .installing)
    release.yield()
    release.finish()
    // Bounded: the waiter is the subject's own completion signal.
    let settled = await withDeadline(seconds: 5) { await waiter.value; return true }
    #expect(settled == true)
    #expect(Self.isShowingUpgrade(d) == false, "Installing leaves when the switch settles")
  }

  @Test("the press waiter never removes the Ready pill that replaced Installing")
  func pressWaiterLeavesTheReadyPill() async throws {
    let (released, release) = AsyncStream<Void>.makeStream()
    func waitForRelease() async -> EngineCoordinator.PressReadiness {
      for await _ in released { break }
      return .ready
    }
    let spoken = Box<[OverlayAnnouncement]>([])
    let (d, deferred) = director(spoken)
    let waiter = ColdPressGuard.reconcileParakeetUpgrade(
      overlay: d, model: nil, isActivating: { true }, ensureSelectedReady: waitForRelease)
    let firstRender = try #require(deferred())
    firstRender()
    d.present(.parakeetUpgrade(ParakeetUpgradePillModel(phase: .ready), isStillWanted: { true }))
    release.yield()
    release.finish()
    let settled = await withDeadline(seconds: 5) { await waiter.value; return true }
    #expect(settled == true)
    guard case .parakeetUpgrade(let shown)? = d.renderModel.state.presentation?.content else {
      Issue.record("the Ready pill was removed by the press waiter")
      return
    }
    #expect(shown.phase == .ready)
  }

  @Test("an allowance is spent only when the pill reached the screen")
  func spentOnlyWhenPresented() {
    let overlay = Overlay()
    overlay.slotIsFree = false
    let defaults = Self.defaults()
    let presenter = ParakeetUpgradePillPresenter(
      overlay: overlay, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    presenter.backgroundUpgradeChanged(Self.downloading(0.1))
    #expect(overlay.presented.isEmpty)
    #expect(
      defaults.bool(
        forKey: ParakeetUpgradePillPresenter.shownKey(.downloading, cacheKey: "ultra-key"))
        == false)
    overlay.slotIsFree = true
    presenter.backgroundUpgradeChanged(Self.downloading(0.2))
    #expect(overlay.presented.count == 1, "a later tick shows it once the slot is free")
  }

  @Test("ready shows once for an upgrade on this Mac, never for a new user's first load")
  func readyOnlyForUpgraders() {
    let overlay = Overlay()
    let presenter = ParakeetUpgradePillPresenter(
      overlay: overlay, targetCacheKey: "ultra-key", defaults: Self.defaults(), isUltraReady: { true }, log: { _ in })
    presenter.observe(Self.activated(.ultra, trigger: .selectionPoint))
    #expect(overlay.presented.isEmpty, "a launch load with no download seen is not an upgrade")
    presenter.observe(Self.activated(.v3, trigger: .backgroundAdmission))
    #expect(overlay.presented.isEmpty, "v3 serving is not Ultra ready")
    presenter.observe(Self.activated(.ultra, trigger: .backgroundAdmission))
    #expect(overlay.presented == [ParakeetUpgradePillModel(phase: .ready)])
    presenter.observe(Self.activated(.ultra, trigger: .backgroundAdmission))
    #expect(overlay.presented.count == 1, "once")

    let seen = Overlay()
    let defaults = Self.defaults()
    let upgrader = ParakeetUpgradePillPresenter(
      overlay: seen, targetCacheKey: "ultra-key", defaults: defaults, isUltraReady: { true }, log: { _ in })
    upgrader.backgroundUpgradeChanged(Self.downloading(0.5))
    upgrader.observe(Self.activated(.ultra, trigger: .selectionPoint))
    #expect(
      seen.presented.last == ParakeetUpgradePillModel(phase: .ready),
      "a relaunch activation after this Mac saw the download is still the upgrade")
  }
}
