import ApplicationServices
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit

// MARK: - Fakes

/// A scripted observer: capture answers from a queue, events fired by the test.
@MainActor
final class ObserverFake: PastedRegionObserving {
  var captureOutcomes: [PastedRegionCaptureOutcome] = []
  private(set) var captures: [(pid_t, String, Int)] = []
  private(set) var starts = 0
  private(set) var stops = 0
  private var onEvent: (@MainActor (PastedRegionEvent) -> Void)?
  var isObserving: Bool { onEvent != nil }

  static func target(pasted: String, pastedAtMs: Int, manual: Bool = false) -> PastedRegionTarget {
    // Built through the real locator on fake handles; the watcher never
    // touches the element.
    let scheduler = ObserverClock()
    let ax = CaptureAX(value: "Note: \(pasted) please", manual: manual)
    let observer = PastedRegionObserver(ax: ax, scheduler: scheduler)
    guard
      case .captured(let t) = observer.capture(pid: 42, pastedText: pasted, pastedAtMs: pastedAtMs)
    else { fatalError("fixture capture failed") }
    return t
  }

  func capture(pid: pid_t, pastedText: String, pastedAtMs: Int) -> PastedRegionCaptureOutcome {
    captures.append((pid, pastedText, pastedAtMs))
    return captureOutcomes.isEmpty ? .ended(.captureUnsupported) : captureOutcomes.removeFirst()
  }
  func start(
    _ target: PastedRegionTarget, onEvent: @escaping @MainActor (PastedRegionEvent) -> Void
  ) {
    starts += 1
    self.onEvent = onEvent
  }
  func stop() {
    stops += 1
    onEvent = nil
  }
  func fire(_ event: PastedRegionEvent) { onEvent?(event) }
}

/// Minimal AX fake only used to build a real `PastedRegionTarget` fixture.
@MainActor
private final class CaptureAX: PastedRegionAXOperations {
  let value: String
  let manual: Bool
  init(value: String, manual: Bool) {
    self.value = value
    self.manual = manual
  }
  func isTrusted() -> Bool { true }
  func isProcessRunning(_ pid: pid_t) -> Bool { true }
  func applicationElement(pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
  func focusedElement(pid: pid_t) -> PastedRegionFocus {
    .element(AXUIElementCreateApplication(pid + 10_000))
  }
  func setMessagingTimeout(_ element: AXUIElement, seconds: Double) -> Bool { true }
  func frontmostPID() -> pid_t? { 42 }
  func subrole(of element: AXUIElement) -> SelectionReader.SubroleOutcome { .subrole(nil) }
  func supportsManualAccessibility(_ application: AXUIElement) -> Bool { manual }
  func enableManualAccessibility(_ application: AXUIElement) -> Bool { true }
  func readValue(of element: AXUIElement) -> PastedRegionValueRead { .text(value) }
  func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? { nil }
}

@MainActor
final class ObserverClock: PastedRegionScheduling {
  var now = 0
  var nowMs: Int { now }
  @MainActor final class Work: PastedRegionScheduledWork { func cancel() {} }
  func schedule(afterMs: Int, _ action: @escaping @MainActor () -> Void)
    -> any PastedRegionScheduledWork
  {
    Work()
  }
}

/// A judge that answers from a script and records every request. The answer
/// can be held until the test releases it, to stage stale results.
final class JudgeFake: CorrectionJudging, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [CorrectionJudgeRequest] = []
  var requests: [CorrectionJudgeRequest] { lock.withLock { _requests } }
  /// Verdict for every candidate id: true = correction.
  var answer: (Int) -> Bool = { _ in true }
  var bypass: CorrectionJudgeBypass?
  var languages: Set<String>? = ["en", "de"]
  private var gate: CheckedContinuation<Void, Never>?
  var holdAnswers = false
  /// Hold the capabilities read too, to stage an interruption at that boundary.
  var holdCapabilities = false
  private var _capabilitiesRequests = 0
  var capabilitiesRequests: Int { lock.withLock { _capabilitiesRequests } }

  var capabilities: CorrectionJudgeCapabilities {
    get async {
      lock.withLock { _capabilitiesRequests += 1 }
      if holdCapabilities {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          lock.withLock { gate = c }
        }
      }
      return CorrectionJudgeCapabilities(
        canRunOnThisMac: true, supportedLanguages: languages, executionIdentity: ["arm": "fake"])
    }
  }

  func judge(_ request: CorrectionJudgeRequest) async -> CorrectionJudgeOutcome {
    lock.withLock { _requests.append(request) }
    if holdAnswers {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        lock.withLock { gate = c }
      }
    }
    if let bypass { return .bypass(bypass) }
    let answer = self.answer
    return .verdict(
      request.candidates.map {
        CorrectionJudgeDecision(
          id: $0.id, verdict: answer($0.id) ? .correctionAndSafe : .notCorrection)
      })
  }

  func release() {
    let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      let c = gate
      gate = nil
      return c
    }
    c?.resume()
  }
}

/// Parks until the watcher's deferred work has produced `count` telemetry
/// events, with a fail-fast deadline (the subject announces through the spy).
@MainActor
func waitForEvents(_ spy: LearnTelemetrySpy, count: Int, deadlineMs: Int = 2000) async -> Bool {
  let start = ContinuousClock.now
  while spy.events.count < count {
    if ContinuousClock.now - start > .milliseconds(deadlineMs) { return false }
    await Task.yield()
  }
  return true
}

/// Parks until `condition` holds, with a fail-fast deadline. Every party here
/// is on the main actor, so a yield gives the watcher's deferred task its turn.
@MainActor
func waitUntil(deadlineMs: Int = 2000, _ condition: @MainActor () -> Bool) async -> Bool {
  let start = ContinuousClock.now
  while !condition() {
    if ContinuousClock.now - start > .milliseconds(deadlineMs) { return false }
    await Task.yield()
  }
  return true
}

// MARK: - Watcher

@MainActor
@Suite("ObservedCorrectionWatcher (#996 steps 1–7)", .tags(.productOutcome), .serialized)
struct ObservedCorrectionWatcherTests {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  let observer = ObserverFake()
  let clock = ObserverClock()
  let judge = JudgeFake()
  let library = WordLibraryFake()
  let presenter = PresenterSpy()
  let telemetry = LearnTelemetrySpy()
  let coordinator: CorrectionProposalCoordinator
  let saira = CustomWord(canonical: "Saira")

  final class Knobs {
    var toggle = true
    var judgeAvailable = true
    /// Production: the AFM judge's own deadline plus one second. A test that
    /// holds the judge shortens it so a wedged judge is proven bounded fast.
    var judgeDeadlineSeconds: Double = WordSuggestionService.correctionJudgeDeadlineSeconds + 1
    var frontmost: FrontmostApplication? = FrontmostApplication(
      pid: 42, bundleID: "com.apple.Notes")
  }
  let knobs = Knobs()

  init() {
    let (store, _, _) = makeFaultableStore()
    library.userWords = [saira]
    coordinator = CorrectionProposalCoordinator(
      store: store, vocabulary: library.access, presenter: presenter, telemetry: telemetry)
    coordinator.initialize()
  }

  func makeWatcher() -> ObservedCorrectionWatcher {
    let judge = judge
    let knobs = knobs
    let observer = observer
    let clock = clock
    let library = library
    var deps = ObservedCorrectionWatcherDependencies(
        isLearnFromEditsOn: { knobs.toggle },
        selectJudge: {
          knobs.judgeAvailable ? SelectedCorrectionJudge(arm: .rules, judge: judge) : nil
        },
        frontmost: { knobs.frontmost },
        observer: observer,
        nowMs: { clock.nowMs },
        userWords: { library.userWords },
        packTerms: { library.packTerms },
        coordinator: coordinator,
        telemetry: telemetry)
    deps.judgeDeadlineSeconds = knobs.judgeDeadlineSeconds
    return ObservedCorrectionWatcher(dependencies: deps)
  }

  func paste(
    _ text: String = "Ask sarah today", bundle: String? = "com.apple.Notes",
    language: String? = "en"
  )
    -> PasteCompletionEvent
  {
    PasteCompletionEvent(pastedText: text, destinationBundleID: bundle, language: language)
  }

  @Test(
    "the synchronous callback never captures: toggle off and an active watch are the only two immediate skips, emitted deferred"
  )
  func synchronousChecks() async {
    let watcher = makeWatcher()
    knobs.toggle = false
    watcher.pasteCompleted(paste())
    #expect(telemetry.events.isEmpty, "the skip is deferred")
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events == [.skipped(.toggleOff)])
    #expect(observer.captures.isEmpty && watcher.isWatching == false)

    knobs.toggle = true
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(watcher.isWatching, "reserved before the deferred task runs")
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(telemetry.events.last == .skipped(.watchActive))
    #expect(await waitUntil { observer.starts == 1 })
    #expect(observer.captures.count == 1)
  }

  @Test("gate order in the deferred task: model, language, destination, then the observer's own skips")
  func gateOrder() async {
    let watcher = makeWatcher()
    knobs.judgeAvailable = false
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events.last == .skipped(.modelUnavailable))

    // A second paste with no judge clears its watch but reports nothing: the
    // selection is fixed for the launch and the first row already said it.
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { !watcher.isWatching })
    #expect(telemetry.events.count == 1, "model_unavailable is reported once per launch")

    knobs.judgeAvailable = true
    watcher.pasteCompleted(paste(language: "xx"))
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(telemetry.events.last == .skipped(.languageUnsupported))
    watcher.pasteCompleted(paste(language: nil))
    #expect(await waitForEvents(telemetry, count: 3))
    #expect(telemetry.events.last == .skipped(.languageUnsupported))

    // No app blocklist (founder 2026-09-19): a terminal is watched like any
    // app; only the destination identity gate applies.
    knobs.frontmost = FrontmostApplication(pid: 7, bundleID: "com.apple.Mail")
    watcher.pasteCompleted(paste(bundle: "com.apple.Terminal"))
    #expect(await waitForEvents(telemetry, count: 4))
    #expect(telemetry.events.last == .skipped(.destinationMismatch), "mismatch, not a blocklist")
    #expect(observer.captures.isEmpty, "no Accessibility work before the gates pass")

    knobs.frontmost = FrontmostApplication(pid: 42, bundleID: "com.apple.Notes")
    observer.captureOutcomes = [
      .skipped(.secureField), .skipped(.noFocusedElement), .ended(.dictatedTextNotFound),
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 5))
    #expect(telemetry.events.last == .skipped(.secureField))
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 6))
    #expect(telemetry.events.last == .skipped(.noFocusedElement))
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 7))
    #expect(telemetry.events.last == .observationEnded(.dictatedTextNotFound, 0, .other))
    #expect(observer.captures.map(\.0) == [42, 42, 42] && observer.starts == 0)
  }

  @Test(
    "a settled edit is aligned, filtered, judged once and proposed; the same snapshot settles nothing new"
  )
  func settledBurstProposes() async throws {
    let watcher = makeWatcher()
    clock.now = 500
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 500))
    ]
    watcher.pasteCompleted(paste())
    // The paste instant is stamped from the observer clock BEFORE deferral: a
    // clock moved after the callback does not change it.
    clock.now = 9_000
    #expect(await waitUntil { observer.starts == 1 })
    #expect(observer.captures.first?.2 == 500)

    observer.fire(.changed(region: "Ask Saira today"))
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(judge.requests.count == 1)
    let request = try #require(judge.requests.first)
    #expect(
      request.candidates.map(\.original) == ["sarah"]
        && request.candidates.map(\.replacement) == ["Saira"])
    #expect(request.context == "Ask Saira today" && request.language == "en")
    #expect(telemetry.events.contains(.judged(.rules, .verdict, 1, 1)))
    #expect(telemetry.events.contains(.proposed(.existingWord)))
    #expect(presenter.offers.count == 1 && presenter.offers.first?.corrected == "Saira")
    let stored = try #require(coordinator.openProposalsNewestFirst.first)
    #expect(
      stored.original == "sarah" && stored.state == .existingWord(saira.id)
        && stored.advisorySafeAlias == true)
    #expect(
      stored.sourceBundleID == "com.apple.Notes" && stored.contextExcerpt == "Ask Saira today")

    // The identical snapshot settling again is not a new burst.
    observer.fire(.settled(region: "Ask Saira today"))
    await Task.yield()
    #expect(judge.requests.count == 1)
    observer.fire(.ended(.focusChanged))
    #expect(telemetry.events.last == .observationEnded(.focusChanged, 1, .native))
    #expect(watcher.isWatching == false)
  }

  @Test(
    "two bursts at most, two judge calls at most, and burst two never re-sends burst one's pair")
  func twoBurstLimit() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah about the invoice", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste("Ask sarah about the invoice"))
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira about the invoice"))
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(judge.requests.count == 1)
    // Burst two: the first pair again plus a new one; only the new one is sent.
    observer.fire(.settled(region: "Ask Saira about the invoyce"))
    #expect(await waitForEvents(telemetry, count: 4))
    #expect(judge.requests.count == 2)
    #expect(judge.requests.last?.candidates.map(\.original) == ["invoice"])
    // Burst three is ignored entirely.
    observer.fire(.settled(region: "Ask Saira about the invoyces"))
    await Task.yield()
    await Task.yield()
    #expect(judge.requests.count == 2)
    observer.fire(.ended(.ceilingElapsed))
    #expect(telemetry.events.last == .observationEnded(.ceilingElapsed, 2, .native))
  }

  @Test("a judge that never answers is bounded: the call is reported as a deadline bypass and nothing is proposed")
  func wedgedJudgeIsBounded() async throws {
    knobs.judgeDeadlineSeconds = 0.05
    let watcher = makeWatcher()
    judge.holdAnswers = true
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.changed(region: "Ask Saira today"))
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(judge.requests.count == 1, "the judge was asked once")
    #expect(telemetry.events.last == .judged(.rules, .deadline, 1, 0))
    #expect(presenter.offers.isEmpty && coordinator.openProposalsNewestFirst.isEmpty)
    judge.release()  // the abandoned call finishes in the background; its answer is discarded
    await Task.yield()
    #expect(telemetry.events.filter { if case .judged = $0 { true } else { false } }.count == 1)
  }

  @Test("a judge answer for a superseded paste is dropped as stale and proposes nothing")
  func staleResult() async {
    let watcher = makeWatcher()
    judge.holdAnswers = true
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
      .skipped(.secureField),
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { judge.requests.count == 1 })
    // A new dictation and a new paste supersede the watch while the judge holds.
    watcher.recordingStarted()
    #expect(telemetry.events.last == .observationEnded(.nextDictationStarted, 1, .native))
    #expect(observer.stops == 1)
    watcher.pasteCompleted(paste())
    judge.release()
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(presenter.offers.isEmpty && coordinator.openProposalsNewestFirst.isEmpty)
    #expect(
      telemetry.events.filter { if case .judged = $0 { return true } else { return false } }.isEmpty
    )
  }

  @Test("a text change while the judge thinks makes the answer stale; a natural observer ending does not")
  func revisionStaleness() async {
    let watcher = makeWatcher()
    judge.holdAnswers = true
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { judge.requests.count == 1 })
    // The user keeps typing: a newer revision supersedes the held answer.
    observer.fire(.changed(region: "Ask Sairaa today"))
    judge.release()
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(presenter.offers.isEmpty)

    // Second watch: the observer ENDS naturally while the judge thinks; the
    // settled snapshot is still evidence, so the answer is used.
    observer.fire(.ended(.focusChanged))
    let watcher2 = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Call sarah now", pastedAtMs: 0))]
    watcher2.pasteCompleted(paste("Call sarah now"))
    #expect(await waitUntil { observer.starts == 2 })
    observer.fire(.settled(region: "Call Saira now"))
    #expect(await waitUntil { judge.requests.count == 2 })
    observer.fire(.ended(.ceilingElapsed))
    judge.release()
    #expect(await waitUntil { presenter.offers.count == 1 })
    #expect(watcher2.staleResults == 0)
  }

  @Test(
    "a dictation after the observer ended on its own voids the held answer without a second observation row"
  )
  func dictationAfterNaturalEnd() async {
    let watcher = makeWatcher()
    judge.holdAnswers = true
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { judge.requests.count == 1 })
    observer.fire(.ended(.focusChanged))
    #expect(telemetry.events == [.observationEnded(.focusChanged, 1, .native)])
    // The user dictates again while the judge still holds: the answer is about
    // text being replaced, so it is voided; the ended observation is not re-reported.
    watcher.recordingStarted()
    #expect(observer.stops == 0 && telemetry.events.count == 1)
    judge.release()
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(presenter.offers.isEmpty && coordinator.openProposalsNewestFirst.isEmpty)
    #expect(telemetry.events.count == 1, "no judged row for a voided answer")
  }

  @Test(
    "toggle off is honoured without an observer event: through the setting entry point, after the judge answers, and after the capabilities read"
  )
  func toggleOffWithoutObserverEvent() async {
    // 1. The settings observer entry point while the judge holds.
    let watcher = makeWatcher()
    judge.holdAnswers = true
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { judge.requests.count == 1 })
    knobs.toggle = false
    watcher.learnFromEditsChanged(isOn: false)
    #expect(observer.stops == 1 && watcher.isWatching == false && watcher.toggledOffMidWatch == 1)
    #expect(telemetry.events == [.skipped(.toggleOff)])
    watcher.learnFromEditsChanged(isOn: false)
    #expect(watcher.toggledOffMidWatch == 1 && telemetry.events.count == 1, "idempotent")
    judge.release()
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(presenter.offers.isEmpty && telemetry.events.count == 1)

    // 2. No entry point call at all: the setting is re-read when the answer lands.
    knobs.toggle = true
    let watcher2 = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Call sarah now", pastedAtMs: 0))]
    watcher2.pasteCompleted(paste("Call sarah now"))
    #expect(await waitUntil { observer.starts == 2 })
    observer.fire(.settled(region: "Call Saira now"))
    #expect(await waitUntil { judge.requests.count == 2 })
    knobs.toggle = false
    judge.release()
    #expect(await waitUntil { watcher2.staleResults == 1 })
    #expect(observer.stops == 2 && watcher2.toggledOffMidWatch == 1)
    #expect(telemetry.events == [.skipped(.toggleOff), .skipped(.toggleOff)])
    #expect(presenter.offers.isEmpty)

    // 3. Off during the capabilities read: nothing is captured, the paste is a skip.
    knobs.toggle = true
    judge.holdAnswers = false
    judge.holdCapabilities = true
    let watcher3 = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher3.pasteCompleted(paste())
    #expect(await waitUntil { judge.capabilitiesRequests == 3 })
    knobs.toggle = false
    judge.release()
    #expect(await waitForEvents(telemetry, count: 3))
    #expect(telemetry.events.last == .skipped(.toggleOff))
    #expect(observer.captures.count == 2 && watcher3.isWatching == false, "no AX work after the toggle")
  }

  @Test("a dictation before the queued judge task runs means the judge is never asked")
  func cancelBeforeJudgeTaskStarts() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    // Same turn, before the judge task gets the main actor.
    watcher.recordingStarted()
    #expect(telemetry.events == [.observationEnded(.nextDictationStarted, 1, .native)])
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(judge.requests.isEmpty, "a reserved call for a cancelled watch is not made")
    #expect(presenter.offers.isEmpty && telemetry.events.count == 1)
  }

  @Test("a presenter that starts a dictation inside the first offer stops the rest of the answer")
  func reentrantCancelDuringOffer() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah about the invoice", pastedAtMs: 0))
    ]
    presenter.onOffer = { _ in watcher.recordingStarted() }
    watcher.pasteCompleted(paste("Ask sarah about the invoice"))
    #expect(await waitUntil { observer.starts == 1 })
    // Two pairs in one burst, both judged as corrections.
    observer.fire(.settled(region: "Ask Saira about the invoyce"))
    #expect(await waitUntil { presenter.offers.count == 1 })
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(judge.requests.first?.candidates.count == 2)
    #expect(presenter.offers.count == 1 && coordinator.openProposalsNewestFirst.count == 1)
    #expect(telemetry.events.contains(.observationEnded(.nextDictationStarted, 1, .native)))
    #expect(telemetry.events.filter { $0 == .proposed(.existingWord) || $0 == .proposed(.newWord) }.count == 1)
  }

  @Test("a bypass is reported as its own outcome, never as 'all false', and proposes nothing")
  func bypass() async {
    let watcher = makeWatcher()
    judge.bypass = .deadline
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events.last == .judged(.rules, .deadline, 1, 0))
    #expect(presenter.offers.isEmpty)
  }

  @Test(
    "an open proposal for the pair is refreshed, not re-judged; a rejected pair is filtered before the judge"
  )
  func refreshAndRejected() async throws {
    // Existing open proposal for sarah → Saira.
    guard
      case .minted(let open) = coordinator.propose(
        original: "sarah", corrected: "Saira", state: .existingWord(saira.id), language: "en",
        contextExcerpt: "old", sourceBundleID: "com.apple.Mail", advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { coordinator.proposal(id: open)?.contextExcerpt == "Ask Saira today" })
    #expect(judge.requests.isEmpty, "nothing eligible remained after the filter")
    #expect(coordinator.proposal(id: open)?.sourceBundleID == "com.apple.Notes")
    #expect(presenter.offers.count == 1, "no second offer for the refreshed proposal")
  }

  @Test(
    "toggle off mid-watch stops capture at the next event; the context excerpt never splits a grapheme at 600 units"
  )
  func toggleOffMidWatchAndExcerpt() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    knobs.toggle = false
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(observer.stops == 1 && watcher.isWatching == false && watcher.toggledOffMidWatch == 1)
    #expect(telemetry.events.last == .skipped(.toggleOff), "counted, not dropped from the funnel")
    #expect(judge.requests.isEmpty)

    let flags = String(repeating: "🇩🇪", count: 200)  // 4 UTF-16 units each
    let excerpt = ObservedCorrectionWatcher.contextExcerpt(flags)
    #expect(excerpt.utf16.count == 600 && excerpt.count == 150)
    let odd = String(repeating: "x", count: 599) + "🇩🇪"
    #expect(ObservedCorrectionWatcher.contextExcerpt(odd).utf16.count == 599)
    // A long region is centred on the candidate, backed up to a word boundary,
    // so a fix at the END of a paragraph reaches the judge with its sentence.
    let filler = String(repeating: "word ", count: 300)  // 1,500 units
    let long = filler + "please ask Saira about the invoices today"
    let centred = ObservedCorrectionWatcher.contextExcerpt(long, around: "Saira")
    #expect(centred.utf16.count <= 600 && centred.contains("ask Saira about the invoices today"))
    #expect(centred.hasPrefix("word "), "starts on a word boundary")
    #expect(centred.hasSuffix("today"), "the end of the text is kept when the window is clamped there")
    #expect(ObservedCorrectionWatcher.contextExcerpt(long, around: "absent").hasPrefix("word word"), "no hit: the prefix")
    let early = "ask Saira today " + filler
    #expect(ObservedCorrectionWatcher.contextExcerpt(early, around: "Saira").hasPrefix("ask Saira today"))
  }
}
