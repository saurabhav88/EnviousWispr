import AppKit
import EnviousWisprAppKit
import Foundation
import os

/// #1413 — the live half of `Pause music`, behind `MediaPlaybackControlling`.
/// Two routes, tried in this order for every take:
/// 1. `adapter`: `MediaRemoteAdapter` reads the system Now Playing source (any
///    app, a browser tab included) and pauses it. FRAGILE (see that file); when
///    it answers, it is trusted: Music and Spotify register with Now Playing, so
///    no Apple event is sent and no consent prompt is raised.
/// 2. `scripted`: Music and Spotify by Apple events, the two scriptable players
///    whose playing state can be READ. Runs only when the adapter is not
///    bundled or fails (there is no public "is media playing" API on macOS
///    15.4+, so a blind media-key toggle was rejected in the plan).
/// Nothing is ever started by mistake on either route: `play` is sent only to a
/// source WE paused that a fresh read still reports paused.
///
/// Every Apple event runs on ONE serial background queue, never on the main
/// actor: a TCC Automation prompt blocks the thread it is raised on. A pause and
/// its resume are keyed by hold id; `resume` marks the hold ended UNDER A LOCK
/// before enqueueing, and the pause work item checks that mark at its start and
/// before each target event, so a take that ended while consent or a slow player
/// blocked the queue issues no further events. Cancellation cannot interrupt an
/// event already executing, so a pause that completes late still records what it
/// paused, and the resume queued behind it undoes exactly that.
@MainActor
package final class LiveMediaPlaybackEffects: MediaPlaybackControlling {
  package nonisolated static let targets = ["com.apple.Music", "com.spotify.client"]
  /// Bounds ISSUANCE of new events for one pause, never completion.
  package nonisolated static let issueBudget: TimeInterval = 1.5

  package enum ConsentState: Sendable { case granted, needed, denied, notRunning }

  package enum PlayerState: Equatable, Sendable {
    case playing, paused, stopped, unknown

    /// The `player state` enum both players expose: `kPSP` playing, `kPSp`
    /// paused, `kPSS` stopped.
    package init(descriptor: NSAppleEventDescriptor?) {
      switch descriptor?.enumCodeValue {
      case 0x6B50_5350: self = .playing  // 'kPSP'
      case 0x6B50_5370: self = .paused  // 'kPSp'
      case 0x6B50_5353: self = .stopped  // 'kPSS'
      default: self = .unknown
      }
    }
  }

  /// The OS touches, injectable so `EnviousWisprDesktopEffectsTests` can drive
  /// the queue, the `ended` set and the budget without a real player.
  package struct Environment: Sendable {
    /// `NSRunningApplication` sends no Apple event, so this never launches anything.
    package var isRunning: @Sendable (String) -> Bool
    /// `askUserIfNeeded: false`: never blocks.
    package var consent: @Sendable (String) -> ConsentState
    /// `askUserIfNeeded: true`: BLOCKS the calling thread until the user answers.
    package var raiseConsentPrompt: @Sendable (String) -> Void
    /// Runs one AppleScript source; nil on error.
    package var run: @Sendable (String) -> NSAppleEventDescriptor?
    package var now: @Sendable () -> Date
    /// Runs one adapter process (arguments after `perl`). Live: always set; a
    /// missing file is a `load` failure inside the run. nil only in tests that
    /// exercise the scripted route alone.
    package var adapter: (@Sendable ([String]) -> MediaRemoteAdapter.RunResult)?
    /// The adapter's script and framework paths handed to every run.
    package var adapterLocation: MediaRemoteAdapter

    package init(
      isRunning: @escaping @Sendable (String) -> Bool,
      consent: @escaping @Sendable (String) -> ConsentState,
      raiseConsentPrompt: @escaping @Sendable (String) -> Void,
      run: @escaping @Sendable (String) -> NSAppleEventDescriptor?,
      now: @escaping @Sendable () -> Date = { Date() },
      adapter: (@Sendable ([String]) -> MediaRemoteAdapter.RunResult)? = nil,
      adapterLocation: MediaRemoteAdapter = .bundled
    ) {
      self.isRunning = isRunning
      self.consent = consent
      self.raiseConsentPrompt = raiseConsentPrompt
      self.run = run
      self.now = now
      self.adapter = adapter
      self.adapterLocation = adapterLocation
    }

    package static let live = Environment(
      isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
      consent: LiveMediaPlaybackEffects.liveConsent,
      raiseConsentPrompt: LiveMediaPlaybackEffects.liveRaiseConsentPrompt,
      run: LiveMediaPlaybackEffects.liveRun,
      adapter: MediaRemoteAdapter.liveRun,
      adapterLocation: .bundled)
  }

  private struct State {
    var ended: Set<UUID> = []
    var pausedByHold: [UUID: [String]] = [:]
    var consentPromptRaised = false
  }

  private let env: Environment
  private let queue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: State())

  package init(environment: Environment = .live, queue: DispatchQueue? = nil) {
    self.env = environment
    self.queue =
      queue ?? DispatchQueue(label: "com.enviouswispr.other-audio.media", qos: .userInitiated)
  }

  package func pause(holdID: UUID, completion: @escaping @MainActor (MediaPauseOutcome) -> Void) {
    let running = Self.targets.filter { env.isRunning($0) }
    // With no adapter, a browser-only playback has nothing to reach it; with
    // one, the adapter decides on the queue (Codex r1 Q4).
    guard !running.isEmpty || env.adapter != nil else {
      completion(MediaPauseOutcome(.nothingPlaying, route: .none))
      return
    }
    queue.async { [self] in
      let outcome = pauseOnQueue(holdID: holdID, running: running)
      Task { @MainActor in completion(outcome) }
    }
  }

  package func resume(holdID: UUID, completion: @escaping @MainActor (MediaResumeOutcome) -> Void) {
    // Under the lock FIRST, so a pause item that has not yet checked sees it.
    state.withLock { _ = $0.ended.insert(holdID) }
    queue.async { [self] in
      let targets = state.withLock { $0.pausedByHold.removeValue(forKey: holdID) } ?? []
      let outcome = resumeOnQueue(targets)
      // The serial queue has now passed this hold's pause and cleanup; the mark
      // has done its job and must not accumulate across takes.
      state.withLock { _ = $0.ended.remove(holdID) }
      Task { @MainActor in completion(outcome) }
    }
  }

  package func resumeOrphan(
    holdID: UUID, targets: [String],
    completion: @escaping @MainActor (MediaResumeOutcome) -> Void
  ) {
    queue.async { [self] in
      let outcome = resumeOnQueue(
        targets.filter {
          Self.targets.contains($0) || $0.hasPrefix(MediaRemoteAdapter.targetPrefix)
        })
      Task { @MainActor in completion(outcome) }
    }
  }

  package func preflightConsent(completion: @escaping @MainActor (Bool) -> Void) {
    let running = Self.targets.filter { env.isRunning($0) }
    queue.async { [self] in
      // A healthy adapter answers (playing, paused or nothing) without any
      // Apple event, so the scripted consent prompts are never raised for it.
      let adapterAnswers: Bool
      switch adapterGet() {
      case .playing, .paused, .nothing: adapterAnswers = true
      case .unavailable, .none: adapterAnswers = false
      }
      if !adapterAnswers { running.forEach(env.raiseConsentPrompt) }
      Task { @MainActor in completion(adapterAnswers) }
    }
  }

  // MARK: - Queue side (never on the main actor)

  private nonisolated func pauseOnQueue(holdID: UUID, running: [String]) -> MediaPauseOutcome {
    var adapterFailure: String?
    // Route 1: the adapter. It runs before any consent check so a Mac where it
    // answers never sees an Automation prompt for Music or Spotify.
    if env.adapter != nil {
      let started = env.now()
      guard mayIssue(holdID: holdID, started: started) else {
        return MediaPauseOutcome(.nothingPlaying, route: .adapter)
      }
      switch adapterGet() {
      case .playing(let source):
        guard mayIssue(holdID: holdID, started: started) else {
          return MediaPauseOutcome(.nothingPlaying, route: .adapter)
        }
        var paused = adapterSend(MediaRemoteAdapter.pauseCommand)
        if !paused {
          // A refused acknowledgement can still have paused the source (Codex
          // r1 Q4): re-read once, and own it only if it now reports paused.
          if case .paused(let now) = adapterGet() ?? .nothing, Self.matches(now, source) {
            paused = true
          }
        }
        guard paused else {
          // The adapter answered; the source may be a browser tab, so the
          // scripted route (and its consent prompts) is not a fallback here.
          return MediaPauseOutcome(.failed, route: .adapter, adapterFailure: "send")
        }
        let target = MediaRemoteAdapter.target(for: source)
        state.withLock { $0.pausedByHold[holdID] = [target] }
        return MediaPauseOutcome(.paused(targets: [target]), route: .adapter)
      case .paused, .nothing:
        // Trusted: Music and Spotify register with Now Playing, so no event
        // is sent and no prompt is raised for a take with nothing playing.
        return MediaPauseOutcome(.nothingPlaying, route: .adapter)
      case .unavailable(let failure):
        adapterFailure = failure.rawValue
      case .none:
        break
      }
    }
    // Route 2: scripted Music/Spotify. Its issuance budget starts NOW, after
    // the adapter's own wait, or a 2 s adapter timeout would exhaust it.
    guard !running.isEmpty else {
      return MediaPauseOutcome(.nothingPlaying, route: .none, adapterFailure: adapterFailure)
    }
    var outcome = scriptedPauseOnQueue(holdID: holdID, running: running, started: env.now())
    outcome.adapterFailure = adapterFailure
    return outcome
  }

  private nonisolated func adapterGet() -> MediaRemoteAdapter.NowPlayingRead? {
    guard let adapter = env.adapter else { return nil }
    return MediaRemoteAdapter.parseGet(adapter(env.adapterLocation.getArguments))
  }

  private nonisolated func adapterSend(_ command: String) -> Bool {
    guard let adapter = env.adapter else { return false }
    return MediaRemoteAdapter.sendSucceeded(adapter(env.adapterLocation.sendArguments(command)))
  }

  private nonisolated func scriptedPauseOnQueue(
    holdID: UUID, running: [String], started: Date
  ) -> MediaPauseOutcome {
    var paused: [String] = []
    var consentNeeded = false
    var consentDenied = false
    var failed = false
    for target in running {
      guard mayIssue(holdID: holdID, started: started) else { break }
      switch env.consent(target) {
      case .granted: break
      case .needed:
        consentNeeded = true
        continue
      case .denied:
        consentDenied = true
        continue
      case .notRunning: continue
      }
      guard env.isRunning(target) else { continue }
      // Re-checked before EACH event, not once per target: a `player state`
      // query on a slow player can outlive the take, and a pause issued after
      // the take ended would be a new effect, not a late completion.
      guard mayIssue(holdID: holdID, started: started) else { break }
      guard playerState(target) == .playing else { continue }
      guard mayIssue(holdID: holdID, started: started) else { break }
      if env.run("tell application id \"\(target)\" to pause") != nil {
        paused.append(target)
        // Recorded per target, immediately: a later target's failure never
        // erases an earlier success, and a resume queued behind reads this.
        let recorded = paused
        state.withLock { $0.pausedByHold[holdID] = recorded }
      } else {
        failed = true
      }
    }
    if consentNeeded {
      // Once per launch, raise the prompt on this queue so the NEXT take works.
      let raise = state.withLock { s -> Bool in
        if s.consentPromptRaised { return false }
        s.consentPromptRaised = true
        return true
      }
      if raise { running.forEach(env.raiseConsentPrompt) }
    }
    if !paused.isEmpty { return .paused(targets: paused) }
    if consentNeeded { return .consentNeeded }
    if consentDenied { return .consentDenied }
    if failed { return .failed }
    return .nothingPlaying
  }

  /// Adapter cleanup for one recorded source. Never gated on the pause's
  /// `ended` mark or budget: cleanup has its own bound, the adapter's process
  /// budget. `play` is sent only when a fresh read shows the SAME app and the
  /// SAME item still paused, so nothing the user did not have playing starts.
  /// THE one comparison between a fresh read and what a pause recorded (three
  /// call sites, one definition): same app, and when the pause recorded an
  /// item, the same item. A read that now lacks an item we recorded does not
  /// match: it may be another tab or an ad, and a miss can only leave something
  /// paused, never start it.
  private nonisolated static func matches(
    _ now: MediaRemoteAdapter.Source, _ recorded: MediaRemoteAdapter.Source
  ) -> Bool {
    now.bundleID == recorded.bundleID
      && (recorded.identity == nil || now.identity == recorded.identity)
  }

  private nonisolated func adapterResume(_ source: MediaRemoteAdapter.Source) -> MediaResumeOutcome {
    switch adapterGet() {
    case .paused(let now):
      guard Self.matches(now, source) else { return .sourceChanged }
      return adapterSend(MediaRemoteAdapter.playCommand) ? .resumed : .failed
    case .playing(let now):
      // The user already resumed our item (M3); a different playing app or
      // item means ours is no longer reachable.
      return Self.matches(now, source) ? .resumed : .sourceChanged
    case .nothing:
      return .sourceChanged
    case .unavailable, .none:
      return .failed
    }
  }

  /// M3/M4: cleanup for the targets a pause recorded. A target the user already
  /// resumed or stopped counts as cleanup done (M3); a target whose state cannot
  /// be read, or whose `play` fails, or whose consent is gone, is M4.
  private nonisolated func resumeOnQueue(_ targets: [String]) -> MediaResumeOutcome {
    guard !targets.isEmpty else { return .nothingToResume }
    var failed = false
    var sourceChanged = false
    for target in targets {
      if let source = MediaRemoteAdapter.source(fromTarget: target) {
        switch adapterResume(source) {
        case .resumed, .nothingToResume: break
        case .sourceChanged: sourceChanged = true
        case .failed: failed = true
        }
        continue
      }
      guard env.isRunning(target) else { continue }
      switch env.consent(target) {
      case .granted: break
      case .notRunning: continue
      case .needed, .denied:
        failed = true
        continue
      }
      switch playerState(target) {
      case .playing, .stopped:
        continue  // the user already resumed or stopped it
      case .unknown:
        failed = true
        continue
      case .paused:
        guard env.isRunning(target) else { continue }
        if env.run("tell application id \"\(target)\" to play") == nil {
          failed = true
        }
      }
    }
    if failed { return .failed }
    return sourceChanged ? .sourceChanged : .resumed
  }

  private nonisolated func mayIssue(holdID: UUID, started: Date) -> Bool {
    !state.withLock { $0.ended.contains(holdID) }
      && env.now().timeIntervalSince(started) <= Self.issueBudget
  }

  /// Sent only after the running check, so it never launches the target; the
  /// check-then-query pair is not atomic and that window is accepted.
  private nonisolated func playerState(_ target: String) -> PlayerState {
    PlayerState(descriptor: env.run("tell application id \"\(target)\" to player state"))
  }

  // MARK: - Live OS touches

  private nonisolated static func liveRun(_ source: String) -> NSAppleEventDescriptor? {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return error == nil ? result : nil
  }

  private nonisolated static func liveConsent(_ bundleID: String) -> ConsentState {
    guard let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else {
      return .notRunning
    }
    let status = AEDeterminePermissionToAutomateTarget(
      descriptor, typeWildCard, typeWildCard, false)
    switch status {
    case noErr: return .granted
    case OSStatus(errAEEventWouldRequireUserConsent): return .needed
    case OSStatus(errAEEventNotPermitted): return .denied
    case OSStatus(procNotFound): return .notRunning
    default: return .denied
    }
  }

  private nonisolated static func liveRaiseConsentPrompt(_ bundleID: String) {
    guard let descriptor = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return }
    _ = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, true)
  }
}
