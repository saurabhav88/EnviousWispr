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

  init(_ states: [String: String]) { self.states = states }

  func environment(now: @escaping @Sendable () -> Date = { Date() })
    -> LiveMediaPlaybackEffects.Environment
  {
    LiveMediaPlaybackEffects.Environment(
      isRunning: { [self] id in lock.withLock { states[id] != nil } },
      consent: { [self] _ in consent },
      raiseConsentPrompt: { [self] id in lock.withLock { prompts.append(id) } },
      run: { [self] source in
        if blockOnFirstRun {
          blockOnFirstRun = false
          entered.signal()
          gate.wait()
        }
        return lock.withLock {
          events.append(source)
          let target = source.components(separatedBy: "\"")[1]
          if source.hasSuffix("player state") {
            return Self.stateDescriptor(states[target] ?? "stopped")
          }
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

  /// Waits for every item already on the serial queue, then for the main-actor
  /// completions those items posted.
  private func drain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      queue.async { c.resume() }
    }
    await Task.yield()
    await Task.yield()
  }

  @Test("Pauses only a playing player, then resumes only what it paused")
  func pauseThenResume() async {
    let players = FakePlayers(["com.spotify.client": "playing", "com.apple.Music": "paused"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    var pauseOutcome: MediaPauseOutcome?
    effects.pause(holdID: holdID) { pauseOutcome = $0 }
    await drain(queue)
    #expect(pauseOutcome == .paused(targets: ["com.spotify.client"]))
    #expect(players.state(of: "com.spotify.client") == "paused")
    #expect(players.state(of: "com.apple.Music") == "paused", "never touched")

    var resumeOutcome: MediaResumeOutcome?
    effects.resume(holdID: holdID) { resumeOutcome = $0 }
    await drain(queue)
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
    effects.pause(holdID: holdID) { _ in }
    await drain(queue)
    // The user hits play.
    _ = players.environment().run("tell application id \"com.spotify.client\" to play")
    var outcome: MediaResumeOutcome?
    effects.resume(holdID: holdID) { outcome = $0 }
    await drain(queue)
    #expect(outcome == .nothingToResume)
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
    var pauseOutcome: MediaPauseOutcome?
    effects.pause(holdID: holdID) { pauseOutcome = $0 }
    var resumeOutcome: MediaResumeOutcome?
    effects.resume(holdID: holdID) { resumeOutcome = $0 }
    blocker.signal()
    await drain(queue)
    #expect(players.events.isEmpty)
    #expect(pauseOutcome == .nothingPlaying)
    #expect(resumeOutcome == .nothingToResume)
    #expect(players.state(of: "com.spotify.client") == "playing")
  }

  @Test(
    "A pause already executing when the take ends still records what it paused, and the resume undoes it"
  )
  func latePauseIsUndone() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.blockOnFirstRun = true
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    let holdID = UUID()
    var pauseOutcome: MediaPauseOutcome?
    effects.pause(holdID: holdID) { pauseOutcome = $0 }
    // Wait until the pause item is inside its first event, blocked on the gate:
    // a real signal from the queue thread, bridged off the main actor.
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        players.entered.wait()
        c.resume()
      }
    }
    var resumeOutcome: MediaResumeOutcome?
    effects.resume(holdID: holdID) { resumeOutcome = $0 }
    players.gate.signal()
    await drain(queue)
    // `ended` is checked before each TARGET, not between the state query and
    // the pause of the same target: the executing target completes. The resume
    // queued behind it then undoes exactly what it recorded.
    #expect(pauseOutcome == .paused(targets: ["com.spotify.client"]))
    #expect(resumeOutcome == .resumed)
    #expect(players.state(of: "com.spotify.client") == "playing")
  }

  @Test("Consent needed: no events, prompt raised exactly once per launch")
  func consentNeededPromptsOnce() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.consent = .needed
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    var first: MediaPauseOutcome?
    effects.pause(holdID: UUID()) { first = $0 }
    await drain(queue)
    var second: MediaPauseOutcome?
    effects.pause(holdID: UUID()) { second = $0 }
    await drain(queue)
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
    var outcome: MediaPauseOutcome?
    effects.pause(holdID: UUID()) { outcome = $0 }
    await drain(queue)
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
      // Reads 1-2 (start, first target) are inside the budget; later ones are past it.
      return n <= 2 ? start : start.addingTimeInterval(LiveMediaPlaybackEffects.issueBudget + 1)
    })
    let effects = LiveMediaPlaybackEffects(environment: env, queue: queue)
    var outcome: MediaPauseOutcome?
    effects.pause(holdID: UUID()) { outcome = $0 }
    await drain(queue)
    #expect(outcome == .paused(targets: ["com.apple.Music"]))
    #expect(players.state(of: "com.spotify.client") == "playing", "never reached")
  }

  @Test("Orphan resume touches only the recorded targets that are still paused")
  func orphanResume() async {
    let players = FakePlayers(["com.spotify.client": "paused", "com.apple.Music": "paused"])
    let queue = DispatchQueue(label: "test.media")
    let effects = LiveMediaPlaybackEffects(environment: players.environment(), queue: queue)
    var outcome: MediaResumeOutcome?
    effects.resumeOrphan(holdID: UUID(), targets: ["com.spotify.client", "com.example.other"]) {
      outcome = $0
    }
    await drain(queue)
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
