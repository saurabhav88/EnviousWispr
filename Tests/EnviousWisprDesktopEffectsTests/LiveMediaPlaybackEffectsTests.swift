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
    let entered = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      DispatchQueue.global().async {
        // Deadline fallback for the fake's actual entry signal. (settle: bounded wait)
        let result = players.entered.wait(timeout: .now() + 2)
        c.resume(returning: result == .success)
      }
    }
    #expect(entered, "The player never entered the blocked event")
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
    #expect(outcome == MediaPauseOutcome(.nothingPlaying, route: .none))
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
// MARK: - v1.1: the adapter route in front of the scripted one

/// A scriptable Now Playing source: what `get` reports, whether `send` is
/// accepted, and every adapter invocation in order. Answers as the real perl
/// process would (stdout JSON or `null`, stderr, exit status), so the parser is
/// exercised on every row, not bypassed.
private final class FakeAdapter: @unchecked Sendable {
  private let lock = NSLock()
  /// nil = nothing registered (`null`); otherwise the source and its playing flag.
  var source: (bundle: String, identity: String?, playing: Bool)?
  /// Overrides the whole `get` answer (a broken adapter).
  var getOverride: MediaRemoteAdapter.RunResult?
  var rejectSend = false
  /// The refusal that still paused: `send 1` exits non-zero AND the source pauses.
  var rejectSendButPause = false
  /// Block inside the first `get` (a read in flight when the take ends) to stage a race.
  let gate = DispatchSemaphore(value: 0)
  let entered = DispatchSemaphore(value: 0)
  var blockInsideGet = false
  private(set) var calls: [[String]] = []

  init(_ source: (bundle: String, identity: String?, playing: Bool)?) { self.source = source }

  var run: @Sendable ([String]) -> MediaRemoteAdapter.RunResult {
    { [self] arguments in
      let command = Array(arguments.dropFirst(2))
      if command.first == "get", blockInsideGet {
        blockInsideGet = false
        entered.signal()
        gate.wait()
      }
      return lock.withLock {
        calls.append(command)
        if command.first == "get" {
          if let getOverride { return getOverride }
          guard let source else { return .init(status: 0, stdout: "null\n", stderr: "") }
          var dict: [String: Any] = ["bundleIdentifier": source.bundle, "playing": source.playing,
            "processIdentifier": 42]
          if let identity = source.identity { dict["title"] = identity }
          let data = try! JSONSerialization.data(withJSONObject: dict)
          return .init(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
        }
        if rejectSendButPause, command.dropFirst().first == MediaRemoteAdapter.pauseCommand {
          source?.playing = false
          return .init(status: 1, stdout: "", stderr: "Failed to send command")
        }
        if rejectSend { return .init(status: 1, stdout: "", stderr: "Failed to send command") }
        if command.dropFirst().first == MediaRemoteAdapter.pauseCommand { source?.playing = false }
        if command.dropFirst().first == MediaRemoteAdapter.playCommand { source?.playing = true }
        return .init(status: 0, stdout: "", stderr: "")
      }
    }
  }

  func commands() -> [String] { lock.withLock { calls.map { $0.joined(separator: " ") } } }
  func isPlaying() -> Bool? { lock.withLock { source?.playing } }
}

@MainActor
@Suite("Live media playback effects: adapter route", .tags(.productOutcome))
struct LiveMediaPlaybackAdapterRouteTests {
  private func make(_ players: FakePlayers, _ adapter: FakeAdapter?) -> LiveMediaPlaybackEffects {
    var env = players.environment()
    env.adapter = adapter?.run
    return LiveMediaPlaybackEffects(environment: env, queue: DispatchQueue(label: "test.media"))
  }

  private func pause(_ effects: LiveMediaPlaybackEffects, _ holdID: UUID) async -> MediaPauseOutcome? {
    await MediaResultWaiter<MediaPauseOutcome>().wait { effects.pause(holdID: holdID, completion: $0) }
  }

  private func resume(_ effects: LiveMediaPlaybackEffects, _ holdID: UUID) async -> MediaResumeOutcome? {
    await MediaResultWaiter<MediaResumeOutcome>().wait { effects.resume(holdID: holdID, completion: $0) }
  }

  @Test("A browser tab playing: paused through the adapter, no Apple event, resumed at the end")
  func browserTabPausedAndResumed() async {
    let players = FakePlayers(["com.spotify.client": "paused"])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    let effects = make(players, adapter)
    let holdID = UUID()
    let outcome = await pause(effects, holdID)
    #expect(outcome == .paused(targets: ["adapter:com.google.Chrome|yt-1"], route: .adapter))
    #expect(adapter.isPlaying() == false)
    #expect(adapter.commands() == ["get --no-artwork --allow-missing-title", "send 1"])
    #expect(players.events.isEmpty, "the adapter answered: no Apple event, no consent check")

    let resumed = await resume(effects, holdID)
    #expect(resumed == .resumed)
    #expect(adapter.isPlaying() == true)
    #expect(adapter.commands().suffix(2) == ["get --no-artwork --allow-missing-title", "send 0"])
  }

  @Test("Adapter says nothing is playing: no event, no prompt, even with Spotify running")
  func adapterNothingIsTrusted() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    players.consent = .needed
    let adapter = FakeAdapter(nil)
    let effects = make(players, adapter)
    let outcome = await pause(effects, UUID())
    #expect(outcome == MediaPauseOutcome(.nothingPlaying, route: .adapter))
    #expect(players.events.isEmpty && players.prompts.isEmpty)
  }

  @Test("Adapter says the source is already paused: left alone, nothing recorded")
  func alreadyPausedIsLeftAlone() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.spotify.client", identity: "t", playing: false))
    let effects = make(players, adapter)
    let holdID = UUID()
    #expect(await pause(effects, holdID) == MediaPauseOutcome(.nothingPlaying, route: .adapter))
    #expect(await resume(effects, holdID) == .nothingToResume)
    #expect(adapter.commands() == ["get --no-artwork --allow-missing-title"])
  }

  @Test("User pressed play mid-take: nothing is sent at the end")
  func userResumedIsLeftAlone() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    let effects = make(players, adapter)
    let holdID = UUID()
    _ = await pause(effects, holdID)
    adapter.source?.playing = true
    #expect(await resume(effects, holdID) == .resumed)
    #expect(!adapter.commands().contains("send 0"))
  }

  @Test("Another item paused in the same app at the end: not ours, nothing is started")
  func sameAppDifferentItemIsNotResumed() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    let effects = make(players, adapter)
    let holdID = UUID()
    _ = await pause(effects, holdID)
    // The user opened another tab, played it, and paused it themselves.
    adapter.source = (bundle: "com.google.Chrome", identity: "yt-2", playing: false)
    #expect(await resume(effects, holdID) == .sourceChanged)
    #expect(!adapter.commands().contains("send 0"))
    #expect(adapter.isPlaying() == false)
  }

  @Test("Recorded an item, the read at the end has none: not provably ours, nothing is started")
  func missingIdentityAtResumeIsNotOurs() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    let effects = make(players, adapter)
    let holdID = UUID()
    _ = await pause(effects, holdID)
    adapter.source = (bundle: "com.google.Chrome", identity: nil, playing: false)
    #expect(await resume(effects, holdID) == .sourceChanged)
    #expect(!adapter.commands().contains("send 0"))
    // A different item PLAYING in the same app is not "the user resumed ours" either.
    let holdB = UUID()
    adapter.source = (bundle: "com.google.Chrome", identity: "yt-1", playing: true)
    _ = await pause(effects, holdB)
    adapter.source = (bundle: "com.google.Chrome", identity: "yt-3", playing: true)
    #expect(await resume(effects, holdB) == .sourceChanged)
  }

  @Test("A different app is the source at the end: reported as source changed, nothing sent")
  func differentAppAtResume() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    let effects = make(players, adapter)
    let holdID = UUID()
    _ = await pause(effects, holdID)
    adapter.source = (bundle: "com.apple.Podcasts", identity: "ep", playing: false)
    #expect(await resume(effects, holdID) == .sourceChanged)
    #expect(!adapter.commands().contains("send 0"))
  }

  @Test("Adapter unavailable (exit 1, load failure): the scripted route runs with a fresh budget")
  func unavailableFallsBackToScripted() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let adapter = FakeAdapter(nil)
    adapter.getOverride = .init(status: 1, stdout: "", stderr: "Failed to load framework: x")
    let effects = make(players, adapter)
    let holdID = UUID()
    let outcome = await pause(effects, holdID)
    #expect(outcome?.result == .paused(targets: ["com.spotify.client"]))
    #expect(outcome?.route == .scripted)
    #expect(outcome?.adapterFailure == "load")
    #expect(players.state(of: "com.spotify.client") == "paused")
    #expect(await resume(effects, holdID) == .resumed)
    #expect(players.state(of: "com.spotify.client") == "playing")
  }

  @Test("Adapter internal timeout (null on stdout, timed out on stderr) is a failure, not nothing playing")
  func timeoutIsUnavailable() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let adapter = FakeAdapter(nil)
    adapter.getOverride = .init(
      status: 0, stdout: "null\n",
      stderr: "Reading now playing information timed out after 2000 milliseconds\n")
    let effects = make(players, adapter)
    let outcome = await pause(effects, UUID())
    #expect(outcome?.route == .scripted)
    #expect(outcome?.adapterFailure == "timeout")
    #expect(players.state(of: "com.spotify.client") == "paused")
  }

  @Test("Adapter unavailable and no scripted player running: nothing playing, route none, failure kept")
  func unavailableWithNothingScripted() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter(nil)
    adapter.getOverride = .init(status: nil, stdout: "", stderr: "")
    let effects = make(players, adapter)
    let outcome = await pause(effects, UUID())
    #expect(outcome == MediaPauseOutcome(.nothingPlaying, route: .none, adapterFailure: "timeout"))
  }

  @Test("Pause send refused and the source did not pause: failed on the adapter route, no scripted fallback")
  func refusedSendIsFailedNotFallback() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    adapter.rejectSend = true
    let effects = make(players, adapter)
    let outcome = await pause(effects, UUID())
    #expect(outcome == MediaPauseOutcome(.failed, route: .adapter, adapterFailure: "send"))
    #expect(players.events.isEmpty, "the adapter answered, so Spotify is not touched")
  }

  @Test("Pause send refused but the source reads paused afterwards: owned and resumed")
  func refusedSendThatPausedIsOwned() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    adapter.rejectSendButPause = true
    let effects = make(players, adapter)
    let holdID = UUID()
    let outcome = await pause(effects, holdID)
    #expect(outcome == .paused(targets: ["adapter:com.google.Chrome|yt-1"], route: .adapter))
    #expect(adapter.commands() == [
      "get --no-artwork --allow-missing-title", "send 1", "get --no-artwork --allow-missing-title",
    ])
    #expect(await resume(effects, holdID) == .resumed)
    #expect(adapter.isPlaying() == true)
  }

  @Test("Take ends while the adapter read is in flight: nothing is sent afterwards")
  func endedDuringReadSendsNothing() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: true))
    adapter.blockInsideGet = true
    let effects = make(players, adapter)
    let holdID = UUID()
    let paused = Signal<MediaPauseOutcome>()
    effects.pause(holdID: holdID) { paused.finish($0) }
    // The read is in flight; the take ends; then the read returns "playing".
    await awaitEntered(adapter)
    let resumed = Signal<MediaResumeOutcome>()
    effects.resume(holdID: holdID) { resumed.finish($0) }
    adapter.gate.signal()
    #expect(await paused.wait() == MediaPauseOutcome(.nothingPlaying, route: .adapter))
    #expect(!adapter.commands().contains("send 1"))
    #expect(await resumed.wait() == .nothingToResume)
    #expect(adapter.isPlaying() == true, "the user's playback was never touched")
  }

  /// Bounded wait on the fake's `entered` signal, off the main actor.
  private func awaitEntered(_ adapter: FakeAdapter) async {
    _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      DispatchQueue.global().async {
        c.resume(returning: adapter.entered.wait(timeout: .now() + 2) == .success)
      }
    }
  }

  @Test("Orphan resume of an adapter target has the same gate: same app and item, still paused")
  func orphanAdapterResume() async {
    let players = FakePlayers([:])
    let adapter = FakeAdapter((bundle: "com.google.Chrome", identity: "yt-1", playing: false))
    let effects = make(players, adapter)
    let outcome = await MediaResultWaiter<MediaResumeOutcome>().wait {
      effects.resumeOrphan(holdID: UUID(), targets: ["adapter:com.google.Chrome|yt-1"], completion: $0)
    }
    #expect(outcome == .resumed)
    #expect(adapter.isPlaying() == true)
  }

  @Test("Preflight: a healthy adapter raises no consent prompt; a broken one does")
  func preflightRaisesOnlyWithoutAdapter() async {
    let players = FakePlayers(["com.spotify.client": "playing"])
    let healthy = make(players, FakeAdapter(nil))
    let answered = await MediaResultWaiter<Bool>().wait { healthy.preflightConsent(completion: $0) }
    #expect(answered == true)
    #expect(players.prompts.isEmpty)

    let broken = FakeAdapter(nil)
    broken.getOverride = .init(status: 1, stdout: "", stderr: "Failed to load framework")
    let fallback = make(players, broken)
    let answered2 = await MediaResultWaiter<Bool>().wait { fallback.preflightConsent(completion: $0) }
    #expect(answered2 == false)
    #expect(players.prompts == ["com.spotify.client"])
  }
}

@Suite("MediaRemote adapter parser", .tags(.productOutcome))
struct MediaRemoteAdapterParserTests {
  typealias R = MediaRemoteAdapter.RunResult

  @Test("The stdout/stderr/status matrix maps to the four reads")
  func matrix() {
    let playing = #"{"bundleIdentifier":"com.spotify.client","processIdentifier":1,"playing":true,"title":"Fault","contentItemIdentifier":"9AD6"}"#
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: playing, stderr: ""))
      == .playing(.init(bundleID: "com.spotify.client", identity: "Fault")), "title, not the item id")
    let pausedNoItem = #"{"bundleIdentifier":"com.google.Chrome","processIdentifier":1,"playing":false,"title":"A video"}"#
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: pausedNoItem, stderr: ""))
      == .paused(.init(bundleID: "com.google.Chrome", identity: "A video")))
    let untitled = #"{"bundleIdentifier":"org.telegram.desktop","processIdentifier":1,"playing":true}"#
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: untitled, stderr: ""))
      == .playing(.init(bundleID: "org.telegram.desktop", identity: nil)))
    let untitledWithID = #"{"bundleIdentifier":"org.telegram.desktop","processIdentifier":1,"playing":true,"contentItemIdentifier":"ABCD"}"#
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: untitledWithID, stderr: ""))
      == .playing(.init(bundleID: "org.telegram.desktop", identity: "ABCD")), "the id is the fallback")
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: "null\n", stderr: "")) == .nothing)
    // A live stream: a warning on stderr beside a full payload (live UAT 2026-09-15).
    let live = #"{"bundleIdentifier":"com.google.Chrome","processIdentifier":1,"playing":true,"title":"lofi","contentItemIdentifier":"C738"}"#
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: live, stderr: "Invalid JSON value type in dictionary for key 'duration': inf (__NSCFNumber)\n"))
      == .playing(.init(bundleID: "com.google.Chrome", identity: "lofi")))
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: #"{"processIdentifier":1,"playing":true}"#, stderr: "")) == .nothing, "no bundle id: cannot be re-identified")
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: "null", stderr: "Reading now playing information timed out after 2000 milliseconds")) == .unavailable(.timeout))
    #expect(MediaRemoteAdapter.parseGet(R(status: nil, stdout: "", stderr: "")) == .unavailable(.timeout))
    #expect(MediaRemoteAdapter.parseGet(R(status: 1, stdout: "", stderr: "Failed to load framework: x")) == .unavailable(.load))
    #expect(MediaRemoteAdapter.parseGet(R(status: 2, stdout: "", stderr: "boom")) == .unavailable(.exit))
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: "not json", stderr: "")) == .unavailable(.parse))
    #expect(MediaRemoteAdapter.parseGet(R(status: 0, stdout: "{}", stderr: "")) == .unavailable(.parse))
  }

  @Test("A recorded target round-trips, and an identity may contain the separator")
  func targetRoundTrip() {
    let source = MediaRemoteAdapter.Source(bundleID: "com.google.Chrome", identity: "A | B")
    let target = MediaRemoteAdapter.target(for: source)
    #expect(target == "adapter:com.google.Chrome|A | B")
    #expect(MediaRemoteAdapter.source(fromTarget: target) == source)
    #expect(MediaRemoteAdapter.source(fromTarget: "adapter:com.x") == .init(bundleID: "com.x", identity: nil))
    #expect(MediaRemoteAdapter.source(fromTarget: "com.spotify.client") == nil)
    #expect(MediaRemoteAdapter.source(fromTarget: "adapter:") == nil)
  }

  @Test("The bundled paths name the script in Resources and the framework in Frameworks")
  func bundledPaths() {
    let a = MediaRemoteAdapter.bundled
    #expect(a.scriptURL.lastPathComponent == "mediaremote-adapter.pl")
    #expect(a.frameworkURL.lastPathComponent == "MediaRemoteAdapter.framework")
    #expect(a.getArguments.suffix(3) == ["get", "--no-artwork", "--allow-missing-title"])
    #expect(a.sendArguments("1").suffix(2) == ["send", "1"])
  }
}

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
