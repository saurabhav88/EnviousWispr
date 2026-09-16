import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprDesktopEffects

// #1413 — the live media adapter with its OS touches faked: which events it
// issues, in what order, and what a cancelled or late pause does. This target may
// construct live drivers; the fake environment is what keeps the developer's
// Spotify untouched.

/// A scriptable "player" that answers `player state` and accepts `pause`/`play`.
private final class FakePlayers: @unchecked Sendable {
  private let lock = NSLock()
  private var states: [String: String]  // bundle id -> "playing" | "paused"
  private(set) var events: [String] = []
  var consent: LiveMediaPlaybackEffects.ConsentState = .granted
  var prompts: [String] = []
  /// A gate the pause item blocks on inside its first event, to stage a race;
  /// `entered` is signalled once it is inside, so the test waits on a real signal.
  let gate = DispatchSemaphore(value: 0)
  let entered = DispatchSemaphore(value: 0)
  var blockOnFirstRun = false
  /// Block inside the PAUSE command of this target (an already-issued event).
  var blockInsidePauseOf: String?
  /// Targets whose `pause` / `play` commands fail.
  var failCommandsFor: Set<String> = []
  /// Targets whose `player state` cannot be read.
  var unreadableState: Set<String> = []

  init(_ states: [String: String]) { self.states = states }

  func environment(now: @escaping @Sendable () -> Date = { Date() })
    -> LiveMediaPlaybackEffects.Environment
  {
    LiveMediaPlaybackEffects.Environment(
      isRunning: { [self] id in lock.withLock { states[id] != nil } },
      consent: { [self] _ in consent },
      raiseConsentPrompt: { [self] id in lock.withLock { prompts.append(id) } },
      run: { [self] source in
        let target = source.components(separatedBy: "\"")[1]
        if blockOnFirstRun {
          blockOnFirstRun = false
          entered.signal()
          gate.wait()
        }
        if source.hasSuffix("to pause"), blockInsidePauseOf == target {
          blockInsidePauseOf = nil
          entered.signal()
          gate.wait()
        }
        return lock.withLock {
          events.append(source)
          if source.hasSuffix("player state") {
            if unreadableState.contains(target) { return nil }
            return Self.stateDescriptor(states[target] ?? "stopped")
          }
          if failCommandsFor.contains(target) { return nil }
          if source.hasSuffix("to pause") { states[target] = "paused" }
          if source.hasSuffix("to play") { states[target] = "playing" }
          return NSAppleEventDescriptor.null()
        }
      },
      now: now)
  }

  func state(of id: String) -> String? { lock.withLock { states[id] } }

  private static func stateDescriptor(_ s: String) -> NSAppleEventDescriptor {
    let code: OSType =
      switch s {
      case "playing": 0x6B50_5350
      case "paused": 0x6B50_5370
      default: 0x6B50_5353
      }
    return NSAppleEventDescriptor(enumCode: code)
  }
}

@MainActor
@Suite("Live media playback effects", .tags(.productOutcome))
struct LiveMediaPlaybackEffectsTests {

  /// Awaits the effect's OWN completion callback (a real signal), with a
  /// deadline only as a fallback; nil means the deadline hit.
  private func pause(_ effects: LiveMediaPlaybackEffects, _ holdID: UUID) async -> MediaPauseOutcome? {
    await MediaResultWaiter<MediaPauseOutcome>().wait { effects.pause(holdID: holdID, completion: $0) }
  }

  private func resume(_ effects: LiveMediaPlaybackEffects, _ holdID: UUID) async -> MediaResumeOutcome? {
    await MediaResultWaiter<MediaResumeOutcome>().wait { effects.resume(holdID: holdID, completion: $0) }
  }

  @Test("Pauses only a playing player, then resumes only what it paused")
  func pauseThenResume() async {
    let players = FakePlayers(["com.spotify.client": "playing", "com.apple.Music": "paused"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    let pauseOutcome = await pause(effects, holdID)
    #expect(pauseOutcome == .paused(targets: ["com.spotify.client"]))
    #expect(players.state(of: "com.spotify.client") == "paused")
    #expect(players.state(of: "com.apple.Music") == "paused", "never touched")

    let resumeOutcome = await resume(effects, holdID)
    #expect(resumeOutcome == .resumed)
    #expect(players.state(of: "com.spotify.client") == "playing")
    #expect(players.state(of: "com.apple.Music") == "paused", "the user's own pause stays")
  }

  @Test("A player the user resumed mid-take is not sent play again")
  func userResumedIsLeftAlone() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    _ = await pause(effects, holdID)
    // The user hits play.
    _ = players.environment().run("tell application id \"com.spotify.client\" to play")
    let outcome = await resume(effects, holdID)
    #expect(outcome == .resumed, "M3: a target the user already resumed is cleanup done")
    #expect(players.state(of: "com.spotify.client") == "playing")
    #expect(players.events.filter { $0.hasSuffix("to play") }.count == 1, "only the user's")
  }

  @Test("A resume that lands before the queued pause starts cancels it: no events at all")
  func endedBeforePauseStarted() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let queue = DispatchQueue(label: "test.media")
    // Block the queue so the pause item cannot start before the resume is marked.
    let blocker = DispatchSemaphore(value: 0)
    queue.async { blocker.wait() }
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    // Direct calls, in this order, BEFORE the queue is released: `resume` marks
    // the hold ended synchronously, so the queued pause must find the mark.
    let pauseDone = Signal<MediaPauseOutcome>()
    effects.pause(holdID: holdID) { pauseDone.finish($0) }
    let resumeDone = Signal<MediaResumeOutcome>()
    effects.resume(holdID: holdID) { resumeDone.finish($0) }
    blocker.signal()
    let p = await pauseDone.wait()
    let r = await resumeDone.wait()
    #expect(players.events.isEmpty)
    #expect(p == .nothingPlaying)
    #expect(r == .nothingToResume)
    #expect(players.state(of: "com.spotify.client") == "playing")
  }

  /// Waits until the fake is blocked inside an event (a real signal from the
  /// queue thread, bridged off the main actor).
  private func awaitEntered(_ players: FakePlayers) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        players.entered.wait()
        c.resume()
      }
    }
  }

  @Test("A take that ends while the state QUERY is executing issues no pause afterwards")
  func endDuringStateQueryIssuesNoPause() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.blockOnFirstRun = true
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    let pauseDone = Signal<MediaPauseOutcome>()
    effects.pause(holdID: holdID) { pauseDone.finish($0) }
    await awaitEntered(players)
    let resumeDone = Signal<MediaResumeOutcome>()
    effects.resume(holdID: holdID) { resumeDone.finish($0) }  // marks ended NOW
    players.gate.signal()
    let p = await pauseDone.wait()
    let r = await resumeDone.wait()
    // The query was already executing; a pause AFTER the take ended would be a
    // new effect, not a late completion, so none is issued.
    #expect(p == .nothingPlaying)
    #expect(r == .nothingToResume)
    #expect(players.state(of: "com.spotify.client") == "playing")
    #expect(!players.events.contains { $0.hasSuffix("to pause") })
  }

  @Test("A pause COMMAND already executing when the take ends is recorded, and the resume undoes it")
  func latePauseIsUndone() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.blockInsidePauseOf = "com.spotify.client"
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    let pauseDone = Signal<MediaPauseOutcome>()
    effects.pause(holdID: holdID) { pauseDone.finish($0) }
    await awaitEntered(players)
    let resumeDone = Signal<MediaResumeOutcome>()
    effects.resume(holdID: holdID) { resumeDone.finish($0) }
    players.gate.signal()
    let p = await pauseDone.wait()
    let r = await resumeDone.wait()
    #expect(p == .paused(targets: ["com.spotify.client"]))
    #expect(r == .resumed)
    #expect(players.state(of: "com.spotify.client") == "playing")
  }

  @Test("First target paused, second target's command fails: the first is still recorded and resumed")
  func firstSuccessSecondFailure() async {
    let players = FakePlayers(["com.apple.Music": "playing", "com.spotify.client": "playing"])
    players.failCommandsFor = ["com.spotify.client"]
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    let p = await pause(effects, holdID)
    #expect(p == .paused(targets: ["com.apple.Music"]))
    #expect(players.state(of: "com.apple.Music") == "paused")
    #expect(players.state(of: "com.spotify.client") == "playing")
    let r = await resume(effects, holdID)
    #expect(r == .resumed)
    #expect(players.state(of: "com.apple.Music") == "playing")
  }

  @Test("Mixed cleanup: one target resumes, another cannot be read: the outcome is failed")
  func mixedResumeOutcome() async {
    let players = FakePlayers(["com.apple.Music": "playing", "com.spotify.client": "playing"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    let p = await pause(effects, holdID)
    #expect(p == .paused(targets: ["com.apple.Music", "com.spotify.client"]))
    players.unreadableState = ["com.spotify.client"]
    let r = await resume(effects, holdID)
    #expect(r == .failed)
    #expect(players.state(of: "com.apple.Music") == "playing", "the readable one still resumed")
  }

  @Test("Consent needed: no events, prompt raised exactly once per launch")
  func consentNeededPromptsOnce() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.consent = .needed
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let first = await pause(effects, UUID())
    let second = await pause(effects, UUID())
    #expect(first == .consentNeeded && second == .consentNeeded)
    #expect(players.events.isEmpty)
    #expect(players.prompts == ["com.spotify.client"])
  }

  @Test("Consent denied: no events, no prompt")
  func consentDenied() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.consent = .denied
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let outcome = await pause(effects, UUID())
    #expect(outcome == .consentDenied)
    #expect(players.events.isEmpty && players.prompts.isEmpty)
  }

  @Test("No target running: nothing is sent and the completion is immediate")
  func nothingRunning() async {
    let players = FakePlayers([:])
    let effects = LiveMediaPlaybackEffects(
      environment: players.environment(), queue: DispatchQueue(label: "t"))
    var outcome: MediaPauseOutcome?
    effects.pause(holdID: UUID()) { outcome = $0 }
    #expect(outcome == .nothingPlaying)
  }

  @Test("The issue budget stops new events; a first success is still recorded")
  func budgetBoundsIssuance() async {
    let players = FakePlayers(["com.apple.Music": "playing", "com.spotify.client": "playing"])
    let queue = DispatchQueue(label: "test.media")
    let start = Date()
    let calls = OSAllocatedUnfairLockBox(0)
    let env = players.environment(now: {
      let n = calls.increment()
      // Reads 1-4 (start, then the three checks of the first target) are inside
      // the budget; the second target's first check is past it.
      return n <= 4 ? start : start.addingTimeInterval(LiveMediaPlaybackEffects.issueBudget + 1)
    })
    let effects = LiveMediaPlaybackEffects(environment: env, queue: queue)
    let outcome = await pause(effects, UUID())
    #expect(outcome == .paused(targets: ["com.apple.Music"]))
    #expect(players.state(of: "com.spotify.client") == "playing", "never reached")
  }

  @Test("Orphan resume touches only the recorded targets that are still paused")
  func orphanResume() async {
    let players = FakePlayers(["com.spotify.client": "paused", "com.apple.Music": "paused"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let outcome = await MediaResultWaiter<MediaResumeOutcome>().wait {
      effects.resumeOrphan(holdID: UUID(), targets: ["com.spotify.client", "com.example.other"], completion: $0)
    }
    #expect(outcome == .resumed)
    #expect(players.state(of: "com.spotify.client") == "playing")
    #expect(players.state(of: "com.apple.Music") == "paused")
  }

  @Test("The player-state enum codes map as documented")
  func playerStateCodes() {
    typealias State = LiveMediaPlaybackEffects.PlayerState
    #expect(State(descriptor: NSAppleEventDescriptor(enumCode: 0x6B50_5350)) == .playing)
    #expect(State(descriptor: NSAppleEventDescriptor(enumCode: 0x6B50_5370)) == .paused)
    #expect(State(descriptor: NSAppleEventDescriptor(enumCode: 0x6B50_5353)) == .stopped)
    #expect(State(descriptor: nil) == .unknown)
  }
}

/// A Sendable counter for the fake clock.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Int
  init(_ value: Int) { self.value = value }
  func increment() -> Int {
    lock.withLock {
      value += 1
      return value
    }
  }
}

/// Awaits an effect's own completion callback; a deadline only as a fallback so
/// a lost callback fails the row instead of hanging the lane.
@MainActor
private final class MediaResultWaiter<Value: Sendable> {
  private var continuation: CheckedContinuation<Value?, Never>?
  private var deadline: Task<Void, Never>?

  func wait(start: (@escaping @MainActor (Value) -> Void) -> Void) async -> Value? {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      deadline = Task { @MainActor [weak self] in
        // Deadline fallback only; the completion decides success. (settle: bounded wait)
        try? await Task.sleep(for: .seconds(2))
        self?.finish(nil)
      }
      start { [weak self] value in self?.finish(value) }
    }
  }

  private func finish(_ value: Value?) {
    guard let continuation else { return }
    self.continuation = nil
    deadline?.cancel()
    deadline = nil
    continuation.resume(returning: value)
  }
}

/// A one-shot completion the test can register BEFORE releasing a gate and
/// await afterwards; deadline only as a fallback.
@MainActor
private final class Signal<Value: Sendable> {
  private var value: Value?
  private var continuation: CheckedContinuation<Value?, Never>?

  func finish(_ v: Value) {
    value = v
    continuation?.resume(returning: v)
    continuation = nil
  }

  func wait() async -> Value? {
    if let value { return value }
    return await withCheckedContinuation { c in
      continuation = c
      Task { @MainActor [weak self] in
        // Deadline fallback only; the completion decides success. (settle: bounded wait)
        try? await Task.sleep(for: .seconds(2))
        guard let self, let pending = self.continuation else { return }
        self.continuation = nil
        pending.resume(returning: nil)
      }
    }
  }
}
