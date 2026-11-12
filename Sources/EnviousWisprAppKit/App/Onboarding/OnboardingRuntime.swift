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
@MainActor
final class OnboardingRuntime {
  struct Inputs {
    /// Reads every tracked owner fact readiness depends on (inside observation tracking) and
    /// returns a summary of the readiness-relevant ones; progress-only changes must not change it.
    var readObservedFacts: () -> AnyHashable
    /// Downloaded bytes and an identity for the current picks' running downloads, or nil.
    var downloadProgress: () -> (identity: String, bytes: Int64)?
    /// Whether every required current download is installed.
    var downloadsFinished: () -> Bool
    /// Samples Apple Intelligence's live availability off the main thread.
    var sampleAppleIntelligence: () async -> AppleIntelligenceLiveAvailability
    /// Asks the availability owner for its approved recheck.
    var recheckAppleIntelligence: () -> Void
    var now: () -> Date
    /// Waits out a duration (production: `Task.sleep`); tests inject their own.
    var sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The existing onboarding permission cadence (OnboardingV2View.pollPermissions, 2 s).
    var pollInterval: Duration = .seconds(2)
  }

  private let coordinator: OnboardingCoordinator
  private let facts: OnboardingLiveFacts
  private let inputs: Inputs
  private(set) var isRunning = false
  private var observationGeneration: UInt64 = 0
  /// Bumped only by start and stop: an Apple Intelligence sample survives an observation re-arm.
  private var runGeneration: UInt64 = 0
  private var pollTask: Task<Void, Never>?
  private var sampleTask: Task<Void, Never>?
  private var advanceTask: Task<Void, Never>?
  private var advanceScheduled = false
  private var lastSnapshot: AnyHashable?
  private var speed = OnboardingSlowNetworkMonitor()
  private var advance = OnboardingAutoAdvance()
  private var downloadsVisible = false
  private var lastStep: OnboardingStep?
  /// The picks the current observation subscribed for; a change re-arms it (plan M54).
  private var observedChoices: OnboardingChoices?
  /// The slow-network notice for the Downloads screen.
  private(set) var isNetworkSlow = false

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
    let progress = inputs.downloadProgress()
    speed.record(identity: progress?.identity, bytes: progress?.bytes ?? 0, at: now)
    isNetworkSlow = step == .downloads && speed.isSlow
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
