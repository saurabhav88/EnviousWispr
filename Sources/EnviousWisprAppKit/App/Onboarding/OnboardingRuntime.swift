import EnviousWisprCore
import Foundation
import Observation

/// The slow-network notice (#4528 plan §3.4, M9): bytes per second over the last 10 s of
/// samples; the notice shows after 20 s below 1 MB/s. Informational only: nothing here cancels,
/// restarts or retries a download. Samples belong to one download identity and reset when it
/// changes.
struct OnboardingSlowNetworkMonitor: Equatable {
  static let window: TimeInterval = 10
  static let slowFor: TimeInterval = 20
  /// 1 MB/s in the decimal units macOS shows.
  static let slowBytesPerSecond: Double = 1_000_000

  private var identity: String?
  private var samples: [(at: Date, bytes: Int64)] = []
  private var slowSince: Date?
  private(set) var isSlow = false

  static func == (a: Self, b: Self) -> Bool {
    a.identity == b.identity && a.isSlow == b.isSlow && a.slowSince == b.slowSince
      && a.samples.map(\.bytes) == b.samples.map(\.bytes)
      && a.samples.map(\.at) == b.samples.map(\.at)
  }

  /// Records one sample; `identity` nil means nothing is downloading (resets everything).
  mutating func record(identity: String?, bytes: Int64, at now: Date) {
    guard let identity else {
      self = Self()
      return
    }
    if identity != self.identity {
      self = Self()
      self.identity = identity
    }
    samples.append((now, bytes))
    // Keep the newest sample at or before the window start as the anchor, so uneven polling
    // never leaves the window short of 10 s (plan M54).
    if let anchor = samples.lastIndex(where: { now.timeIntervalSince($0.at) >= Self.window }) {
      samples.removeFirst(anchor)
    }
    guard let first = samples.first, now.timeIntervalSince(first.at) >= Self.window else {
      return  // Not a full window yet: no verdict either way.
    }
    let span = now.timeIntervalSince(first.at)
    let rate = Double(bytes - first.bytes) / span
    if rate < Self.slowBytesPerSecond {
      // Slow since the window began, so the notice shows 20 s after slowness started.
      let since = slowSince ?? first.at
      slowSince = since
      isSlow = now.timeIntervalSince(since) >= Self.slowFor
    } else {
      slowSince = nil
      isSlow = false
    }
  }
}

/// The Downloads screen's auto-advance (plan §3.4): 1.6 s after the required current downloads
/// finish WHILE the screen is visible. A screen that opens already finished never bounces
/// forward; Back, close, a changed pick, reset and quit cancel a pending advance.
struct OnboardingAutoAdvance: Equatable {
  static let delay: TimeInterval = 1.6

  private var finishedWhileVisibleAt: Date?
  private var wasFinished = false
  private var wasVisible = false
  private var context: OnboardingChoices?

  /// Feeds the latest facts; true exactly when the flow should advance now.
  mutating func shouldAdvance(
    onDownloads: Bool, visible: Bool, finished: Bool, choices: OnboardingChoices, at now: Date
  ) -> Bool {
    defer {
      wasFinished = finished
      wasVisible = onDownloads && visible
      context = choices
    }
    let showing = onDownloads && visible
    guard showing, finished, context == nil || context == choices else {
      finishedWhileVisibleAt = nil
      return false
    }
    // Start the countdown only on a not-finished → finished change seen while showing.
    if finishedWhileVisibleAt == nil {
      if wasVisible, !wasFinished { finishedWhileVisibleAt = now } else { return false }
    }
    guard let started = finishedWhileVisibleAt, now.timeIntervalSince(started) >= Self.delay else {
      return false
    }
    finishedWhileVisibleAt = nil
    return true
  }

  /// A countdown is running (the runtime schedules one precise wake for it).
  var isCounting: Bool { finishedWhileVisibleAt != nil }

  mutating func cancel() { self = Self() }
}

/// #4845 D-A: one poll's view of the current picks' downloads. Built by the live mapping from
/// the owners' in-memory phases and cached manifest sizes; tests supply it directly.
struct OnboardingDownloadSnapshot: Equatable, Sendable {
  struct Pick: Equatable, Sendable {
    /// Which model, e.g. "speech:parakeet" or "polish:eg1.mini".
    var id: String
    var phase: OnboardingDownloadPhase
    /// Bytes already on the Mac for a running download; nil when the owner publishes no fraction.
    var downloadedBytes: Int64?
    /// The model's manifest size; nil when unknown.
    var totalBytes: Int64?
  }

  var speech: Pick?
  var polish: Pick?
  /// The polish pick waiting behind the speech download (the coordinator's queue), if any.
  var queuedPolishID: String?

  /// The polish pick is waiting in the coordinator's queue rather than transferring.
  var polishIsQueued: Bool {
    guard let polish, let queued = queuedPolishID else { return false }
    return polish.id == "polish:\(queued)"
  }
}

/// #4845 D-A: the time left for the current picks' downloads, from the measured byte rate.
/// Pure: the caller supplies snapshots and a monotonic time (seconds since an arbitrary origin).
/// The only carried rate is the last valid speech rate into the already selected queued polish
/// download, because that transfer starts right after on the same connection.
struct OnboardingDownloadEstimator: Equatable {
  static let window: TimeInterval = 10
  /// A running download with no new bytes for this long has no usable rate.
  static let stallAfter: TimeInterval = 30

  private var speechID: String?
  private var polishID: String?
  private var contributing: Set<String> = []
  private var samples: [Sample] = []
  private var lastValidRate: Double?
  private var lastValidRateWasSpeech = false
  private var carriedRate: Double?
  /// The current polish pick was seen waiting in the coordinator's queue during this pick.
  private var polishWasQueued = false
  private var lastProgressAt: TimeInterval?
  private(set) var secondsLeft: Double?

  private struct Sample: Equatable {
    var at: TimeInterval
    var bytes: Int64
  }

  /// A new Setup visit (window reopened): nothing measured before it carries over.
  mutating func newVisit() { self = Self() }

  /// Records one poll. `snapshot` nil means no current pick has a download (resets everything).
  mutating func record(_ snapshot: OnboardingDownloadSnapshot?, at now: TimeInterval) {
    guard let snapshot else {
      self = Self()
      return
    }
    // A changed speech or polish pick drops everything measured for the old picks.
    let newSpeech = snapshot.speech?.id
    let newPolish = snapshot.polish?.id
    if (speechID != nil && newSpeech != nil && newSpeech != speechID)
      || (polishID != nil && newPolish != nil && newPolish != polishID)
    {
      self = Self()
    }
    speechID = newSpeech ?? speechID
    polishID = newPolish ?? polishID
    if snapshot.polishIsQueued { polishWasQueued = true }

    let running = [snapshot.speech, snapshot.polish].compactMap { $0 }.filter {
      if case .downloading = $0.phase, $0.downloadedBytes != nil { return true }
      return false
    }
    let ids = Set(running.map(\.id))
    if ids != contributing {
      // Serial carry: the speech download finished (or is finishing) and the queued polish
      // download is next or now running. Anything else starts measuring from nothing.
      let speechOnly = Set([speechID].compactMap { $0 })
      let polishOnly = Set([polishID].compactMap { $0 })
      let speechWasAlone = !contributing.isEmpty && contributing == speechOnly
      let polishIsNext = ids.isEmpty ? snapshot.polishIsQueued : (!ids.isEmpty && ids == polishOnly)
      // The gap between them: the carried rate waits for the queued polish download to start.
      let gapIntoPolish =
        contributing.isEmpty && carriedRate != nil
        && (ids.isEmpty ? snapshot.polishIsQueued : ids == polishOnly)
      if speechWasAlone, polishIsNext, polishWasQueued, lastValidRateWasSpeech,
        let rate = lastValidRate
      {
        carriedRate = rate
      } else if !gapIntoPolish {
        carriedRate = nil
      }
      contributing = ids
      samples = []
      lastProgressAt = ids.isEmpty ? nil : now
    }

    var measured: Double?
    if !running.isEmpty {
      let bytes = running.reduce(Int64(0)) { $0 + ($1.downloadedBytes ?? 0) }
      if let last = samples.last, bytes > last.bytes { lastProgressAt = now }
      samples.append(Sample(at: now, bytes: bytes))
      // Keep the newest sample at or before the window start as the anchor (the monitor's rule).
      if let anchor = samples.lastIndex(where: { now - $0.at >= Self.window }) {
        samples.removeFirst(anchor)
      }
      if let first = samples.first, now - first.at >= Self.window {
        let rate = Double(bytes - first.bytes) / (now - first.at)
        if rate > 0 {
          measured = rate
          lastValidRate = rate
          lastValidRateWasSpeech = ids == Set([speechID].compactMap { $0 })
          if !lastValidRateWasSpeech { carriedRate = nil }
        }
      }
      if let progressed = lastProgressAt, now - progressed >= Self.stallAfter {
        measured = nil
        carriedRate = nil
        lastValidRate = nil
      }
    }

    guard let rate = measured ?? carriedRate, rate > 0,
      let remaining = Self.remainingBytes(snapshot)
    else {
      secondsLeft = nil
      return
    }
    secondsLeft = Double(remaining) / rate
  }

  /// Bytes still to come for the current picks, or nil when any part is unknown.
  static func remainingBytes(_ snapshot: OnboardingDownloadSnapshot) -> Int64? {
    var total: Int64 = 0
    for pick in [snapshot.speech, snapshot.polish].compactMap({ $0 }) {
      switch pick.phase {
      case .installed, .verifying:
        continue
      case .downloading:
        guard let size = pick.totalBytes, let done = pick.downloadedBytes else { return nil }
        total += max(0, size - done)
      case .notStarted where pick.id == snapshot.polish?.id && snapshot.polishIsQueued:
        guard let size = pick.totalBytes else { return nil }
        total += size
      case .unknown, .notStarted, .paused, .failed, .unavailable:
        return nil
      }
    }
    return total
  }
}

/// #4845 D-B: when Getting ready offers Skip ahead, and in which form. Pure: the caller supplies
/// the facts and a monotonic time. The first-entry time belongs to the visit; the card or line
/// belongs to the polish pick it was shown for, so a replacement pick starts fresh.
struct OnboardingSkipOffer: Equatable {
  enum Form: Equatable, Sendable {
    case hidden
    case card
    /// After Keep waiting: one "Rather not wait? Skip ahead" line.
    case line
  }

  struct Facts: Equatable, Sendable {
    var onGettingReady: Bool
    /// The speech model is installed and warm and both permissions are granted.
    var speechReady: Bool
    var polishPick: String?
    var polishPhase: OnboardingDownloadPhase?
    var polishQueued: Bool
    /// When this visit first reached Getting ready (monotonic), recorded by the coordinator at the
    /// transition itself; nil before it did.
    var gettingReadyEnteredAt: TimeInterval? = nil
  }

  /// A known estimate must be strictly above this; an elapsed wait must reach it.
  static let threshold: TimeInterval = 60

  private var firstEntryAt: TimeInterval?
  private var pick: String?
  private var shownForm: Form?
  private(set) var form: Form = .hidden

  /// A new Setup visit (window reopened).
  mutating func newVisit() { self = Self() }

  /// Seconds since this visit first reached Getting ready; 0 before it did.
  func waitedSeconds(at now: TimeInterval) -> Double {
    firstEntryAt.map { max(0, now - $0) } ?? 0
  }

  /// The polish pick the current card or line was earned for; nil while hidden.
  var shownPick: String? { form == .hidden ? nil : pick }

  mutating func update(_ facts: Facts, secondsLeft: Double?, at now: TimeInterval) {
    if let entered = facts.gettingReadyEnteredAt {
      firstEntryAt = min(firstEntryAt ?? entered, entered)
    } else if facts.onGettingReady, firstEntryAt == nil {
      firstEntryAt = now
    }
    if facts.polishPick != pick {
      pick = facts.polishPick
      shownForm = nil
    }
    guard Self.isEligible(facts) else {
      form = .hidden
      return
    }
    if shownForm == nil {
      let estimated = (secondsLeft ?? 0) > Self.threshold
      let waited = firstEntryAt.map { now - $0 >= Self.threshold } ?? false
      if estimated || waited { shownForm = .card }
    }
    form = shownForm ?? .hidden
  }

  /// Keep waiting: the card becomes the line once.
  mutating func keepWaiting() {
    guard shownForm == .card else { return }
    shownForm = .line
    if form == .card { form = .line }
  }

  static func isEligible(_ facts: Facts) -> Bool {
    guard facts.onGettingReady, facts.speechReady, let pick = facts.polishPick,
      OnboardingChoices.isRuntimeDownloadedPolish(pick)
    else { return false }
    // The phase decides first: a paused, failed, verifying or installed model is owned by its
    // existing recovery or readiness, even if a retry waits in the queue.
    switch facts.polishPhase {
    case .downloading: return true
    case .notStarted, .none: return facts.polishQueued
    case .unknown, .verifying, .installed, .paused, .failed, .unavailable: return false
    }
  }
}

/// Facts the readiness closures read that come from an off-main sample (Apple Intelligence's
/// live availability), shared by the production dependencies and the runtime that samples them.
@MainActor
final class OnboardingLiveFacts {
  var appleIntelligenceLive: AppleIntelligenceLiveAvailability?
}

/// Binds a coordinator to the running app (#4528 chunk C2c.1): observes the owners' tracked
/// state, polls the facts without a signal (live permissions, engine readiness between pokes),
/// samples download speed and drives the Downloads auto-advance. One owner of its task and
/// observation; `start()`/`stop()` are idempotent. It owns no flow state.
/// Observable (plan M83) for the presentation facts only: the slow-network notice and the
/// Downloads countdown.
@MainActor
@Observable
final class OnboardingRuntime {
  struct Inputs {
    /// Reads every tracked owner fact readiness depends on (inside observation tracking) and
    /// returns a summary of the readiness-relevant ones; progress-only changes must not change it.
    var readObservedFacts: () -> AnyHashable
    /// #4845: one typed view of the current picks' downloads per poll, or nil when none.
    var downloadSnapshot: () -> OnboardingDownloadSnapshot?
    /// Whether every required current download is installed.
    var downloadsFinished: () -> Bool
    /// Samples Apple Intelligence's live availability off the main thread.
    var sampleAppleIntelligence: () async -> AppleIntelligenceLiveAvailability
    /// Asks the availability owner for its approved recheck.
    var recheckAppleIntelligence: () -> Void
    var now: () -> Date
    /// #4845: a monotonic clock (seconds) for the estimate and the offer; calendar time stays
    /// with `now`.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Waits out a duration (production: `Task.sleep`); tests inject their own.
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The onboarding permission cadence (2 s).
    var pollInterval: Duration = .seconds(2)
    /// Telemetry's read at this tick (download ends, blockers; F2b). Read-only; no new timer.
    var observeTelemetry: () -> Void = {}
  }

  private let coordinator: OnboardingCoordinator
  private let facts: OnboardingLiveFacts
  private let inputs: Inputs
  @ObservationIgnored private(set) var isRunning = false
  @ObservationIgnored private var observationGeneration: UInt64 = 0
  /// Bumped only by start and stop: an Apple Intelligence sample survives an observation re-arm.
  @ObservationIgnored private var runGeneration: UInt64 = 0
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var sampleTask: Task<Void, Never>?
  @ObservationIgnored private var advanceTask: Task<Void, Never>?
  @ObservationIgnored private var advanceScheduled = false
  @ObservationIgnored private var lastSnapshot: AnyHashable?
  @ObservationIgnored private var speed = OnboardingSlowNetworkMonitor()
  private var advance = OnboardingAutoAdvance()
  @ObservationIgnored private var downloadsVisible = false
  @ObservationIgnored private var lastStep: OnboardingStep?
  /// The picks the current observation subscribed for; a change re-arms it (plan M54).
  @ObservationIgnored private var observedChoices: OnboardingChoices?
  /// The slow-network notice for the Downloads screen.
  private(set) var isNetworkSlow = false
  /// Downloads' 1.6 s countdown is running ("Taking you to the next step").
  var isCountingDown: Bool { advance.isCounting }
  @ObservationIgnored private var estimator = OnboardingDownloadEstimator()
  @ObservationIgnored private var offer = OnboardingSkipOffer()
  /// #4845: Getting ready's Skip ahead offer form and the time left, for the screen.
  private(set) var skipOffer: OnboardingSkipOffer.Form = .hidden
  private(set) var secondsLeft: Double?
  /// #4845: bumped at every window visit; a button press from an earlier visit is refused.
  private(set) var offerVisit = 0
  /// #4845: the Setup window is open for the current visit. Polling and downloads go on while it
  /// is closed, but the Skip ahead offer and its buttons exist only inside an open visit.
  private(set) var offerVisitOpen = false

  init(coordinator: OnboardingCoordinator, facts: OnboardingLiveFacts, inputs: Inputs) {
    self.coordinator = coordinator
    self.facts = facts
    self.inputs = inputs
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    runGeneration &+= 1
    observationGeneration &+= 1
    observe(generation: observationGeneration)
    sampleAppleIntelligence()
    let interval = inputs.pollInterval
    let sleep = inputs.sleep
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        // deadline-fallback: a cadence for facts with no change signal (live permission reads,
        // engine readiness between pokes, progress samples); never a completion wait.
        await sleep(interval)
        guard let self, self.isRunning else { return }
        self.tick()
      }
    }
  }

  /// Ends observation, polling and pending timing. Reset, quit, completion and teardown call it.
  func stop() {
    guard isRunning else { return }
    isRunning = false
    runGeneration &+= 1
    observationGeneration &+= 1
    pollTask?.cancel()
    pollTask = nil
    sampleTask?.cancel()
    sampleTask = nil
    observedChoices = nil
    advanceTask?.cancel()
    advanceTask = nil
    advanceScheduled = false
    lastSnapshot = nil
    speed = OnboardingSlowNetworkMonitor()
    advance.cancel()
    isNetworkSlow = false
    downloadsVisible = false
    estimator = OnboardingDownloadEstimator()
    offer = OnboardingSkipOffer()
    skipOffer = .hidden
    secondsLeft = nil
  }

  /// #4845: a new window visit. The offer's timer and form and the measured speed start over,
  /// even when the runtime kept running while the window was closed.
  func beginOfferVisit() {
    estimator.newVisit()
    offer.newVisit()
    skipOffer = .hidden
    secondsLeft = nil
    offerVisit &+= 1
    offerVisitOpen = true
    coordinator.beginSkipAheadVisit()
  }

  /// #4845: the window closed. The offer and its timer end with the visit; a press from it is
  /// refused (the next open starts a new visit).
  func endOfferVisit() {
    estimator.newVisit()
    offer.newVisit()
    skipOffer = .hidden
    secondsLeft = nil
    offerVisit &+= 1
    offerVisitOpen = false
  }

  /// #4845 D-B: Getting ready's Skip ahead button. `visit` and `pick` are what the screen showed;
  /// the coordinator re-reads every fact before anything changes.
  @discardableResult
  func skipAhead(visit: Int, pick: String) -> Bool {
    guard isRunning, offerVisitOpen, visit == offerVisit, offer.shownPick == pick,
      coordinator.state.choices.polish == pick
    else { return false }
    let accepted = coordinator.acceptSkipAhead(
      pick: pick, secondsLeft: estimator.secondsLeft,
      waitedSeconds: offer.waitedSeconds(at: inputs.uptime()))
    if accepted {
      skipOffer = .hidden
    }
    return accepted
  }

  /// #4845 D-B: Keep waiting. Collapses the card to the one-line form once.
  @discardableResult
  func keepWaiting(visit: Int, pick: String) -> Bool {
    guard isRunning, offerVisitOpen, visit == offerVisit, offer.form == .card, offer.shownPick == pick,
      coordinator.state.choices.polish == pick,
      OnboardingSkipOffer.isEligible(coordinator.skipAheadFacts())
    else { return false }
    offer.keepWaiting()
    skipOffer = offer.form
    coordinator.noteSkipAheadKeptWaiting(
      polish: pick, secondsLeft: estimator.secondsLeft,
      waitedSeconds: offer.waitedSeconds(at: inputs.uptime()))
    return true
  }

  /// Restart Onboarding through the runtime: pending timing and results end first.
  func reset() {
    stop()
    coordinator.reset()
    start()
  }

  /// App quit: the runtime stops, then the coordinator ends its own work.
  func quit() {
    stop()
    coordinator.quit()
  }

  /// The Downloads screen's visibility (window wiring and the screen set it). Closing the window
  /// hides it, so a hidden screen never advances.
  func setDownloadsScreenVisible(_ visible: Bool) {
    downloadsVisible = visible
    if !visible {
      advance.cancel()
      advanceTask?.cancel()
      advanceTask = nil
      advanceScheduled = false
    }
  }

  /// "Check again" on AI polish (D3a): the availability owner's approved recheck plus a fresh
  /// live sample; the coordinator re-forms the cards if the answer changed (plan M77).
  func recheckAppleIntelligence() {
    guard isRunning else { return }
    inputs.recheckAppleIntelligence()
    sampleAppleIntelligence()
  }

  /// The app came back to the front while Setup is open.
  func appDidBecomeActive() {
    guard isRunning else { return }
    sampleAppleIntelligence()
    if coordinator.state.step == .polishPick || coordinator.state.step == .polishSeeAll {
      inputs.recheckAppleIntelligence()
    }
    tick()
  }

  /// One pass over the facts without a signal; the poll loop calls it, and tests drive it with
  /// an injected clock.
  func tick() {
    guard isRunning else { return }
    guard coordinator.isActive else {
      stop()  // Completed: observation and timing end with the flow.
      return
    }
    if coordinator.state.choices != observedChoices {
      // The reader subscribes to the picked runtime and provider: follow a changed pick.
      observationGeneration &+= 1
      lastSnapshot = nil
      observe(generation: observationGeneration)
    }
    let now = inputs.now()
    let step = coordinator.state.step
    if step != lastStep {
      if step == .polishPick, lastStep != .polishSeeAll {
        // Entering the polish screen: the approved availability recheck.
        inputs.recheckAppleIntelligence()
        sampleAppleIntelligence()
      }
      if lastStep == .downloads { advance.cancel() }
      lastStep = step
    }
    let snapshot = inputs.downloadSnapshot()
    let running = Self.runningBytes(snapshot)
    speed.record(identity: running?.identity, bytes: running?.bytes ?? 0, at: now)
    isNetworkSlow = step == .downloads && speed.isSlow
    updateSkipOffer(snapshot)
    inputs.observeTelemetry()
    if advance.shouldAdvance(
      onDownloads: step == .downloads, visible: downloadsVisible,
      finished: inputs.downloadsFinished(), choices: coordinator.state.choices, at: now)
    {
      advanceTask?.cancel()
      advanceTask = nil
      advanceScheduled = false
      coordinator.send(.next)
    } else if advance.isCounting, !advanceScheduled {
      // One precise wake per countdown; `tick` re-checks every condition when it fires.
      advanceScheduled = true
      let sleep = inputs.sleep
      advanceTask = Task { [weak self] in
        await sleep(.milliseconds(Int(OnboardingAutoAdvance.delay * 1000)))
        guard let self, !Task.isCancelled else { return }
        self.tick()
      }
    } else if !advance.isCounting {
      advanceTask?.cancel()
      advanceTask = nil
      advanceScheduled = false
    }
    coordinator.refreshReadiness()
  }

  // MARK: Private

  /// The running downloads' identity and summed bytes, the slow-network notice's input (the same
  /// picks and bytes it read before #4845).
  static func runningBytes(_ snapshot: OnboardingDownloadSnapshot?) -> (
    identity: String, bytes: Int64
  )? {
    let running = [snapshot?.speech, snapshot?.polish].compactMap { $0 }.filter {
      if case .downloading = $0.phase, $0.downloadedBytes != nil { return true }
      return false
    }
    guard !running.isEmpty else { return nil }
    return (
      running.map(\.id).joined(separator: "|"),
      running.reduce(Int64(0)) { $0 + ($1.downloadedBytes ?? 0) }
    )
  }

  private func updateSkipOffer(_ snapshot: OnboardingDownloadSnapshot?) {
    // A closed window has no offer: the next visit starts its own estimate and minute.
    guard offerVisitOpen else { return }
    let at = inputs.uptime()
    estimator.record(snapshot, at: at)
    // The poll decides on the same sample as the estimate; fresh owner reads are for presses.
    let facts = coordinator.skipAheadFacts(sampled: snapshot)
    offer.update(facts, secondsLeft: estimator.secondsLeft, at: at)
    if offer.form == .card, let pick = facts.polishPick {
      coordinator.noteSkipAheadOffered(
        polish: pick, secondsLeft: estimator.secondsLeft, waitedSeconds: offer.waitedSeconds(at: at))
    }
    if skipOffer != offer.form { skipOffer = offer.form }
    let left = estimator.secondsLeft.map { $0.rounded() }
    if secondsLeft != left { secondsLeft = left }
  }

  /// Re-arming observation over the owners' tracked facts (the PolishSetupMonitor pattern). A
  /// change first clears readiness, so a fact that just became false (a replaced key, a revoked
  /// grant, an unloaded model) can never stand while the re-measure is pending.
  private func observe(generation: UInt64) {
    observedChoices = coordinator.state.choices
    let snapshot = withObservationTracking {
      inputs.readObservedFacts()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.isRunning, self.observationGeneration == generation else { return }
        self.observe(generation: generation)
      }
    }
    // Observation coalesces and fires on any tracked write: compare the summary so only a
    // readiness-relevant change invalidates (swift-concurrency observation-not-lossless-queue).
    if let last = lastSnapshot, last != snapshot {
      coordinator.invalidateReadiness()
      // A changed availability report is the authoritative Apple Intelligence change: re-sample
      // the live answer (off-main, one at a time) so Getting ready never waits on an old one.
      sampleAppleIntelligence()
      tick()
    }
    lastSnapshot = snapshot
  }

  private func sampleAppleIntelligence() {
    sampleTask?.cancel()
    let generation = runGeneration
    sampleTask = Task { [weak self] in
      guard let self else { return }
      let live = await self.inputs.sampleAppleIntelligence()
      guard !Task.isCancelled, self.isRunning, self.runGeneration == generation else {
        return
      }
      self.facts.appleIntelligenceLive = live
      self.coordinator.refreshReadiness()
    }
  }
}
