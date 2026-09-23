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
  private(set) var startedTargets: [PastedRegionTarget] = []
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
    startedTargets.append(target)
    self.onEvent = onEvent
  }
  func stop() {
    stops += 1
    onEvent = nil
  }
  /// What the fake flushes on `finish`: nil ends without a burst.
  var pendingRegionOnFinish: String?
  private(set) var finishes: [PastedRegionEndReason] = []
  func finish(_ reason: PastedRegionEndReason) {
    // Production stops BEFORE delivering the events.
    guard let handler = onEvent else { return }
    onEvent = nil
    finishes.append(reason)
    if let region = pendingRegionOnFinish { handler(.settled(region: region)) }
    handler(.ended(reason))
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
  func selectedRange(of element: AXUIElement) -> PastedRegionSelectedRange { .unavailable }
  func readValue(of element: AXUIElement) -> PastedRegionValueRead { .text(value) }
  // An `AXValue` host: the range reader is never consulted here.
  func characterCount(of element: AXUIElement) -> PastedRegionCountRead { .absent }
  func string(of element: AXUIElement, location: Int, length: Int) -> PastedRegionValueRead {
    .absent
  }
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
      return CorrectionJudgeCapabilities(canRunOnThisMac: true, executionIdentity: ["arm": "fake"])
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
  let library = LearnedLibraryFake()
  let presenter = LearnedPresenterSpy()
  let telemetry = LearnTelemetrySpy()
  let coordinator: LearnedCorrectionCoordinator
  let saira = CustomWord(canonical: "Saira")

  final class Knobs {
    var toggle = true
    var judgeAvailable = true
    /// Production: the AFM judge's own deadline plus one second. A test that
    /// holds the judge shortens it so a wedged judge is proven bounded fast.
    var judgeDeadlineSeconds: Double = WordSuggestionService.correctionJudgeDeadlineSeconds + 1
    var frontmost: FrontmostApplication? = FrontmostApplication(
      pid: 42, bundleID: "com.apple.Notes")
    /// Production grace: ten more capture attempts. The test sleeper is immediate
    /// unless a test installs one that moves the world between attempts.
    var captureRetries = 10
    var sleeper: (Int) async -> Void = { _ in }
  }
  let knobs = Knobs()

  init() {
    library.userWords = [saira]
    coordinator = LearnedCorrectionCoordinator(vocabulary: library.access, telemetry: telemetry)
    coordinator.attach(presenter: presenter)
  }

  /// The live "Saira" word after a learn: the sound-alike landed and is marked.
  func learnedSaira() -> CustomWord? { library.userWords.first { $0.id == saira.id } }

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
    deps.captureRetries = knobs.captureRetries
    deps.sleepMs = { ms in await knobs.sleeper(ms) }
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

  @Test("gate order in the deferred task: model, destination, then the observer's own skips; no language gate")
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
    // No language gate (founder 2026-09-21, every language): an unknown or
    // undetermined dictation language reaches the destination gate like any
    // other, and is reported by THAT gate's reason, never as a language skip.
    knobs.frontmost = FrontmostApplication(pid: 7, bundleID: "com.apple.Mail")
    watcher.pasteCompleted(paste(bundle: "com.apple.Notes", language: "xx"))
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(telemetry.events.last == .skipped(.destinationMismatch))
    watcher.pasteCompleted(paste(bundle: "com.apple.Notes", language: nil))
    #expect(await waitForEvents(telemetry, count: 3))
    #expect(telemetry.events.last == .skipped(.destinationMismatch))

    // No app blocklist (founder 2026-09-19): a terminal is watched like any
    // app; only the destination identity gate applies.
    watcher.pasteCompleted(paste(bundle: "com.apple.Terminal"))
    #expect(await waitForEvents(telemetry, count: 4))
    #expect(telemetry.events.last == .skipped(.destinationMismatch), "mismatch, not a blocklist")
    #expect(observer.captures.isEmpty, "no Accessibility work before the gates pass")

    knobs.frontmost = FrontmostApplication(pid: 42, bundleID: "com.apple.Notes")
    // A secure field is final at once; "no focused element" and "text not
    // found" get the capture grace (one attempt plus `captureRetries` retries)
    // before they are reported, because a key-event paste lands after the
    // completion event.
    let attempts = knobs.captureRetries + 1
    observer.captureOutcomes =
      [.skipped(.secureField)] + Array(repeating: .skipped(.noFocusedElement), count: attempts)
      + Array(repeating: .ended(.dictatedTextNotFound), count: attempts)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 5))
    #expect(telemetry.events.last == .skipped(.secureField))
    #expect(observer.captures.count == 1)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 6))
    #expect(telemetry.events.last == .skipped(.noFocusedElement))
    #expect(observer.captures.count == 1 + attempts)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 7))
    #expect(telemetry.events.last == .observationEnded(.dictatedTextNotFound, 0, .other))
    #expect(observer.captures.count == 1 + 2 * attempts && observer.captures.allSatisfy { $0.0 == 42 })
    #expect(observer.starts == 0)
  }

  @Test(
    "capture grace: a host whose paste lands late (no focus, then the old text, then the new text) is captured on the third read, with nothing reported for the misses"
  )
  func captureGraceLandsLate() async {
    // The observer's unstable range snapshot (#3073) reports as this outcome
    // precisely because it is the one the grace retries.
    #expect(ObservedCorrectionWatcher.deservesCaptureGrace(.ended(.dictatedTextNotFound)))
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .skipped(.noFocusedElement), .ended(.dictatedTextNotFound),
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    #expect(observer.captures.count == 3)
    #expect(telemetry.events.isEmpty, "no skip and no end for the two misses")
    #expect(watcher.isWatching)
  }

  @Test("capture grace stops at the toggle going off during the wait: one toggle_off, one capture, no start")
  func captureGraceStopsAtToggleOff() async {
    let knobs = knobs
    var watcherRef: ObservedCorrectionWatcher?
    knobs.sleeper = { _ in
      knobs.toggle = false
      watcherRef?.learnFromEditsChanged(isOn: false)
    }
    let watcher = makeWatcher()
    watcherRef = watcher
    observer.captureOutcomes = Array(repeating: .ended(.dictatedTextNotFound), count: knobs.captureRetries + 1)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events == [.skipped(.toggleOff)])
    #expect(observer.captures.count == 1 && observer.starts == 0)
    #expect(watcher.isWatching == false && watcher.toggledOffMidWatch == 1)
    // The loop's own toggle re-read finds the watch already cancelled: no second skip.
    #expect(await waitUntil { observer.captures.count == 1 })
    #expect(telemetry.events.count == 1)
  }

  @Test("capture grace stops when a dictation starts during the wait: one next_dictation_started row, no start, no later skip")
  func captureGraceStopsAtRecordingStart() async {
    let knobs = knobs
    var watcherRef: ObservedCorrectionWatcher?
    knobs.sleeper = { _ in watcherRef?.recordingStarted() }
    let watcher = makeWatcher()
    watcherRef = watcher
    observer.captureOutcomes = Array(repeating: .ended(.dictatedTextNotFound), count: knobs.captureRetries + 1)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events == [.observationEnded(.nextDictationStarted, 0, .other)])
    #expect(observer.captures.count == 1 && observer.starts == 0)
    #expect(watcher.isWatching == false)
  }

  @Test("capture grace spends the paste's own ceiling budget: the target started after every wait still carries the original paste time")
  func captureGraceKeepsThePasteTime() async throws {
    let knobs = knobs
    let clock = clock
    knobs.sleeper = { ms in clock.now += ms }
    let watcher = makeWatcher()
    clock.now = 1_000
    let retries = knobs.captureRetries
    observer.captureOutcomes =
      Array(repeating: .ended(.dictatedTextNotFound), count: retries)
      + [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 1_000))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    #expect(observer.captures.count == retries + 1)
    #expect(clock.now == 1_000 + retries * 150, "\(retries) waits of 150 ms, 1.5 s in production")
    #expect(observer.captures.allSatisfy { $0.2 == 1_000 }, "every retry names the ORIGINAL paste time")
    let started = try #require(observer.startedTargets.first)
    #expect(started.pastedAtMs == 1_000)
  }

  @Test("capture grace stops at a destination change between attempts: the wait is where the world moves")
  func captureGraceRechecksGates() async {
    let knobs = knobs
    // The sleeper stands in for the wall-clock gap between attempts; here the
    // person switches to Mail during the first gap.
    knobs.sleeper = { _ in knobs.frontmost = FrontmostApplication(pid: 7, bundleID: "com.apple.Mail") }
    let watcher = makeWatcher()
    observer.captureOutcomes = Array(repeating: .ended(.dictatedTextNotFound), count: knobs.captureRetries + 1)
    watcher.pasteCompleted(paste())
    #expect(await waitForEvents(telemetry, count: 1))
    #expect(telemetry.events.last == .skipped(.destinationMismatch))
    #expect(observer.captures.count == 1, "one miss, one gap, then the gate refused a second read")
    #expect(observer.starts == 0 && watcher.isWatching == false)
  }

  @Test(
    "a settled edit is aligned, filtered, judged once and saved at once with an Undo pill; the same snapshot settles nothing new"
  )
  func settledBurstSaves() async throws {
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
    #expect(
      request.context == "Ask sarah today" && request.language == "en",
      "the judge's `Sentence:` is the PASTED text; the edit reaches it only as the pair")
    #expect(telemetry.events.contains(.judged(.rules, .verdict, 1, 1)))
    #expect(telemetry.events.contains(.added(.existingWord)))
    #expect(presenter.offers.count == 1 && presenter.offers.first?.canonical == "Saira")
    #expect(presenter.offers.first?.kind == .updated && presenter.offers.first?.wordID == saira.id)
    let live = try #require(learnedSaira())
    #expect(live.aliases == ["sarah"] && live.learnedAliases == ["sarah"], "saved and marked")
    #expect(coordinator.undoRecord?.pillID == presenter.offers.first?.id)

    // The identical snapshot settling again is not a new burst.
    observer.fire(.settled(region: "Ask Saira today"))
    await Task.yield()
    #expect(judge.requests.count == 1)
    observer.fire(.ended(.focusChanged))
    #expect(telemetry.events.last == .observationEnded(.focusChanged, 1, .native))
    #expect(watcher.isWatching == false)
  }

  @Test("a half-typed fix that only deletes letters never reaches the judge and is counted (#3105)")
  func deletionOnlyEditIsWithheldAndCounted() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "One more try, maybe if I do fewer words.", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste("One more try, maybe if I do fewer words."))
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.changed(region: "One more try, maybe if I drds."))
    observer.fire(.settled(region: "One more try, maybe if I drds."))
    await Task.yield()
    #expect(judge.requests.isEmpty, "a deletion-only run is not judged")
    observer.fire(.ended(.focusChanged))
    #expect(await waitUntil { !watcher.isWatching })
    #expect(telemetry.events.last == .observationEnded(.focusChanged, 1, .native))
    #expect(telemetry.unfinishedEditCounts.last == 1)
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
    #expect(presenter.offers.isEmpty && library.saves.isEmpty)
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
    // A new dictation finishes the observation through the observer (the
    // held answer stays valid, #996 cursor-aware settling); the NEW PASTE is
    // what supersedes it.
    watcher.recordingStarted()
    #expect(telemetry.events.last == .observationEnded(.nextDictationStarted, 1, .native))
    #expect(observer.finishes == [.nextDictationStarted] && observer.stops == 0)
    watcher.pasteCompleted(paste())
    judge.release()
    #expect(await waitForEvents(telemetry, count: 2))
    #expect(await waitUntil { watcher.staleResults == 1 })
    #expect(presenter.offers.isEmpty && library.saves.isEmpty)
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
    "a dictation after the observer ended on its own keeps the held answer and adds no second observation row"
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
    // The user dictates again while the judge still holds: the snapshot is
    // evidence about the paste it came from, so the answer stays valid
    // (#996 cursor-aware settling); the ended observation is not re-reported.
    watcher.recordingStarted()
    #expect(observer.stops == 0 && observer.finishes.isEmpty && telemetry.events.count == 1)
    judge.release()
    #expect(await waitUntil { presenter.offers.count == 1 })
    #expect(watcher.staleResults == 0)
    #expect(telemetry.events.filter { if case .observationEnded = $0 { true } else { false } }.count == 1)
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

  @Test(
    "a dictation right after a settled burst does not void it: the observation ends as next_dictation and the burst is still judged and proposed"
  )
  func dictationAfterSettledBurstStillProposes() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    // Same turn, before the judge task gets the main actor. The snapshot is
    // evidence about THIS paste; the next dictation does not change that
    // (Wispr Flow's second stop signal, Codex r30).
    watcher.recordingStarted()
    #expect(telemetry.events == [.observationEnded(.nextDictationStarted, 1, .native)])
    #expect(observer.finishes == [.nextDictationStarted])
    #expect(await waitUntil { presenter.offers.count == 1 })
    #expect(presenter.offers.first?.canonical == "Saira")
    #expect(watcher.staleResults == 0)
  }

  @Test("a dictation while a fix is pending (seen, not yet settled) flushes it through the observer and proposes it")
  func dictationFlushesPendingFix() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.changed(region: "Ask Saira today"))
    observer.pendingRegionOnFinish = "Ask Saira today"
    watcher.recordingStarted()
    #expect(observer.finishes == [.nextDictationStarted])
    #expect(telemetry.events == [.observationEnded(.nextDictationStarted, 1, .native)])
    #expect(await waitUntil { presenter.offers.count == 1 })
    #expect(presenter.offers.first?.canonical == "Saira")
    // A second recordingStarted after the end is a no-op: one row, no cancel.
    watcher.recordingStarted()
    #expect(telemetry.events.filter { if case .observationEnded = $0 { true } else { false } }.count == 1)
  }

  @Test(
    "a presenter that starts a dictation inside the first pill ends the observation as next_dictation; the rest of the answer is still saved"
  )
  func reentrantDictationDuringOffer() async {
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah about the invoice", pastedAtMs: 0))
    ]
    presenter.onOffer = { _ in watcher.recordingStarted() }
    watcher.pasteCompleted(paste("Ask sarah about the invoice"))
    #expect(await waitUntil { observer.starts == 1 })
    // Two pairs in one burst, both judged as corrections.
    observer.fire(.settled(region: "Ask Saira about the invoyce"))
    #expect(await waitUntil { presenter.offers.count == 2 })
    #expect(judge.requests.first?.candidates.count == 2)
    #expect(library.saves.count == 2 && library.userWords.count == 2, "both pairs landed")
    #expect(watcher.staleResults == 0)
    #expect(observer.finishes == [.nextDictationStarted])
    #expect(telemetry.events.contains(.observationEnded(.nextDictationStarted, 1, .native)))
    #expect(telemetry.events.filter { $0 == .added(.existingWord) || $0 == .added(.newWord) }.count == 2)
  }

  @Test("a bypass is reported as its own outcome, never as 'all false', and saves nothing")
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
    "a pair the word already covers is filtered before the judge; a pair the user undid may be learned again (no rejection memory)"
  )
  func coveredAndUndone() async throws {
    library.userWords = [CustomWord(canonical: "Saira", aliases: ["sarah"])]
    let watcher = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.settled(region: "Ask Saira today"))
    observer.fire(.ended(.focusChanged))
    #expect(await waitUntil { !watcher.isWatching })
    #expect(judge.requests.isEmpty, "nothing eligible remained after the filter")
    #expect(presenter.offers.isEmpty && library.saves.isEmpty)

    // Learn, undo, fix again: the pair is offered again.
    library.userWords = [saira]
    let watcher2 = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher2.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 2 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { presenter.offers.count == 1 })
    let pill = try #require(presenter.offers.first)
    #expect(coordinator.undo(pillID: pill.id) == .undone)
    #expect(learnedSaira()?.aliases.isEmpty == true)
    observer.fire(.ended(.focusChanged))
    #expect(await waitUntil { !watcher2.isWatching })

    let watcher3 = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    watcher3.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 3 })
    observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { presenter.offers.count == 2 }, "learned again after Undo")
    #expect(learnedSaira()?.learnedAliases == ["sarah"])
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
    // "Saira" is token 302 (300 fillers, "please", "ask").
    let centred = ObservedCorrectionWatcher.contextExcerpt(long, focusTokens: 302..<303)
    #expect(centred.utf16.count <= 600 && centred.contains("ask Saira about the invoices today"))
    #expect(centred.hasPrefix("word "), "starts on a word boundary")
    #expect(centred.hasSuffix("today"), "the end of the text is kept when the window is clamped there")
    #expect(ObservedCorrectionWatcher.contextExcerpt(long, focusTokens: 900..<901).hasPrefix("word word"), "no such token: the prefix")
    #expect(ObservedCorrectionWatcher.contextExcerpt(long).hasPrefix("word word"), "no focus: the prefix")
    let early = "ask Saira today " + filler
    #expect(ObservedCorrectionWatcher.contextExcerpt(early, focusTokens: 1..<2).hasPrefix("ask Saira today"))
    // tokenSpan counts the way the aligner splits: any whitespace, runs collapsed.
    let spaced = "a  b\tc\nd"
    let span = ObservedCorrectionWatcher.tokenSpan(2..<4, in: spaced)
    #expect(span.map { String(spaced[$0]) } == "c\nd")
    #expect(ObservedCorrectionWatcher.tokenSpan(4..<5, in: spaced) == nil)
  }

  @Test(
    "two eligible edits more than a judge window apart are judged in TWO requests, each with its own sentence; two inside one window share a request"
  )
  func distantCandidatesGetTheirOwnWindow() async throws {
    let watcher = makeWatcher()
    let filler = String(repeating: "word ", count: 300)  // 1,500 units, over two windows
    let pasted = "ask sara today " + filler + "call sarah tonight"
    let edited = "ask Saira today " + filler + "call Saira tonight"
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: pasted, pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.changed(region: edited))
    observer.fire(.settled(region: edited))
    #expect(await waitUntil { judge.requests.count == 2 })
    // The two requests are asked from two tasks; the judge records them in
    // completion order, so find each by its candidate rather than by position.
    let first = try #require(judge.requests.first { $0.candidates.map(\.original) == ["sara"] })
    let second = try #require(judge.requests.first { $0.candidates.map(\.original) == ["sarah"] })
    #expect(first.context.contains("ask sara today"))
    #expect(second.context.contains("call sarah tonight"))
    #expect(!first.context.contains("sarah") && !second.context.contains("sara today"))
    #expect(await waitUntil { learnedSaira()?.learnedAliases.count == 2 }, "both sound-alikes landed on Saira")

    // Control: two edits inside one window share one request.
    let watcher2 = makeWatcher()
    observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "ask jon today and call tomm tonight", pastedAtMs: 0))
    ]
    watcher2.pasteCompleted(paste("ask jon today and call tomm tonight"))
    #expect(await waitUntil { observer.starts == 2 })
    observer.fire(.settled(region: "ask John today and call Tom tonight"))
    #expect(await waitUntil { judge.requests.count == 3 })
    #expect(judge.requests.last?.candidates.map(\.original) == ["jon", "tomm"])
  }

  @Test("windowGroups: the anchor always owns its window; runs inside join it; the rest anchor the next")
  func windowGroupsPartition() {
    let filler = String(repeating: "word ", count: 300)
    let pasted = "ask sara today " + filler + "call sarah tonight"
    let edited = "ask Saira today " + filler + "call Saira tonight"
    let runs = EditAlignment.align(pasted: pasted, edited: edited).runs
    let inputs = CorrectionCandidateFilter.Inputs(
      userWords: [], packTerms: [])
    let filtered = CorrectionCandidateFilter.filter(runs: runs, inputs: inputs)
    let groups = ObservedCorrectionWatcher.windowGroups(filtered, in: pasted)
    #expect(groups.map { $0.map(\.run.coreOriginal) } == [["sara"], ["sarah"]])
    let near = CorrectionCandidateFilter.filter(
      runs: EditAlignment.align(pasted: "ask sara and call sarah", edited: "ask Saira and call Saira").runs,
      inputs: inputs)
    #expect(ObservedCorrectionWatcher.windowGroups(near, in: "ask sara and call sarah").count == 1)

    // The anchor is the run `prepare` puts first (a capitalised replacement
    // outranks a lowercase one in source order), so the group's window is the
    // request's window: "sarah -> Saira" far away anchors group 1 and "jon ->
    // john" (lowercase) anchors group 2, and every request's candidates sit
    // inside its own context.
    let mixed = "ask jon today " + filler + "call sarah tonight"
    let mixedRuns = CorrectionCandidateFilter.filter(
      runs: EditAlignment.align(pasted: mixed, edited: "ask john today " + filler + "call Saira tonight").runs,
      inputs: inputs)
    let mixedGroups = ObservedCorrectionWatcher.windowGroups(mixedRuns, in: mixed)
    #expect(mixedGroups.map { $0.map(\.run.coreOriginal) } == [["sarah"], ["jon"]])
    for group in mixedGroups {
      let prepared = CorrectionCandidateFilter.prepare(group)
      let anchor = prepared.byID[prepared.candidates[0].id]!
      let window = ObservedCorrectionWatcher.excerptWindow(mixed, focusTokens: anchor.run.originalRange)
      for f in group {
        let span = ObservedCorrectionWatcher.tokenSpan(f.run.originalRange, in: mixed)!
        #expect(span.lowerBound >= window.lowerBound && span.upperBound <= window.upperBound)
      }
    }

    // The same pair twice, far apart, is one candidate in one group.
    let twice = "ask sarah today " + filler + "call sarah tonight"
    let twiceRuns = CorrectionCandidateFilter.filter(
      runs: EditAlignment.align(pasted: twice, edited: "ask Saira today " + filler + "call Saira tonight").runs,
      inputs: inputs)
    #expect(twiceRuns.count == 2)
    let twiceGroups = ObservedCorrectionWatcher.windowGroups(twiceRuns, in: twice)
    #expect(twiceGroups.map { $0.map(\.run.coreOriginal) } == [["sarah"]])
  }

  @Test("a long region's judge context is centred on a PREPARED candidate, not on an earlier run the filter dropped")
  func contextCentredOnAPreparedCandidate() async throws {
    // The first edit is a pair the word already covers (the filter drops it
    // before the judge); the second, 1,500 units later, is the candidate.
    library.userWords = [CustomWord(id: saira.id, canonical: "Saira", aliases: ["sara"])]
    let watcher = makeWatcher()
    let filler = String(repeating: "word ", count: 300)
    let pasted = "ask sara today " + filler + "call sarah tonight"
    let edited = "ask Saira today " + filler + "call Saira tonight"
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: pasted, pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.changed(region: edited))
    observer.fire(.settled(region: edited))
    #expect(await waitUntil { !judge.requests.isEmpty })
    let request = try #require(judge.requests.first)
    #expect(request.candidates.map(\.original) == ["sarah"])
    #expect(
      request.context.contains("call sarah tonight"),
      "the judge sees the PASTED sentence around the candidate: its `Sentence:` contract")
    #expect(
      !request.context.contains("Saira"),
      "the edited spelling reaches the judge only inside the `Edit:` pair, never in the sentence")
    #expect(request.context.utf16.count <= CorrectionJudgeRequest.maxContextUTF16)
    // The candidate pair is the one saved.
    #expect(await waitUntil { learnedSaira()?.learnedAliases == ["sarah"] })
    #expect(learnedSaira()?.aliases == ["sara", "sarah"])
  }

  @Test(
    "a burst the observer flushes right before textbox_emptied (a fix typed and SENT) is still judged and saved: an ENDED watch answers, only a cancelled or superseded one drops"
  )
  func flushedBurstBeforeEndStillSaves() async throws {
    let watcher = makeWatcher()
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste())
    #expect(await waitUntil { observer.starts == 1 })
    // The observer's `end(.textboxEmptied)` flush: `.settled` then `.ended`, back to back.
    observer.fire(.changed(region: "Ask Saira today"))
    observer.fire(.settled(region: "Ask Saira today"))
    observer.fire(.ended(.textboxEmptied))
    #expect(watcher.isWatching == false)
    #expect(await waitUntil { learnedSaira()?.learnedAliases == ["sarah"] })
    #expect(presenter.offers.first?.canonical == "Saira")
    #expect(telemetry.events.contains(.observationEnded(.textboxEmptied, 1, .native)))
  }

  @Test("a recognised browser destination is counted as `browser`; another Electron host as `manual_accessibility`; the rest `native`")
  func appClass() async {
    let watcher = makeWatcher()
    knobs.frontmost = FrontmostApplication(pid: 42, bundleID: "com.google.Chrome")
    observer.captureOutcomes = [.captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))]
    watcher.pasteCompleted(paste(bundle: "com.google.Chrome"))
    #expect(await waitUntil { observer.starts == 1 })
    observer.fire(.ended(.focusChanged))
    #expect(telemetry.events.last == .observationEnded(.focusChanged, 0, .browser))
  }
}
