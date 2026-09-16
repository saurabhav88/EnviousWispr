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
/// Ordering lives on ONE serial background queue; the script itself does not.
/// `NSAppleScript` is a main-thread-only class (Apple's Thread Safety Summary;
/// cloud review, PR #3000), so `liveRun` hops each script to the main thread,
/// wrapped in an AppleScript `with timeout` so a hung player bounds the stall,
/// and returns to the queue. A consent prompt would block the thread it is
/// raised on, so the prompt is never a script: it is raised through the C
/// permission API on its own `consentQueue`, and a script is sent only to a
/// player whose consent already reads granted. A pause and its resume are keyed
/// by hold id; `resume` marks the hold ended UNDER A LOCK before enqueueing, and
/// the pause work item checks that mark at its start and before each target
/// event, so a take that ended while a slow player blocked the queue issues no
/// further events. Cancellation cannot interrupt an event already executing, so
/// a pause that completes late still records what it paused, and the resume
/// queued behind it undoes exactly that.
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
    /// Players whose Automation prompt this launch already raised, per player:
    /// a prompt for Music must not suppress a later one for Spotify.
    var consentPrompted: Set<String> = []
  }

  private let env: Environment
  private let queue: DispatchQueue
  /// The prompt BLOCKS its thread until answered, so it never runs on `queue`:
  /// a resume queued behind it would wait on the dialog, leaving what we paused
  /// paused until the user answers (second pass, 2026-09-16).
  private let consentQueue: DispatchQueue
  private let state = OSAllocatedUnfairLock(initialState: State())

  package init(
    environment: Environment = .live, queue: DispatchQueue? = nil,
    consentQueue: DispatchQueue? = nil
  ) {
    self.env = environment
    self.queue =
      queue ?? DispatchQueue(label: "com.enviouswispr.other-audio.media", qos: .userInitiated)
    self.consentQueue =
      consentQueue
      ?? DispatchQueue(label: "com.enviouswispr.other-audio.consent", qos: .userInitiated)
  }

  /// Raises the prompt once per launch PER PLAYER, off both the main actor and
  /// the media queue.
  private nonisolated func raiseConsentPrompts(_ targets: [String]) {
    let fresh = state.withLock { s -> [String] in
      targets.filter { s.consentPrompted.insert($0).inserted }
    }
    guard !fresh.isEmpty else { return }
    consentQueue.async { [env] in fresh.forEach(env.raiseConsentPrompt) }
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
          Self.targets.contains(Self.scriptedParts(of: $0).bundleID)
            || $0.hasPrefix(MediaRemoteAdapter.targetPrefix)
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
      if !adapterAnswers {
        raiseConsentPrompts(running.filter { env.consent($0) == .needed })
      }
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
        // One re-read after the send, whatever it answered. A refused
        // acknowledgement can still have paused the source (Codex r1 Q4), so
        // it is owned only if it now reports paused; and the position the
        // resume gate compares is the FROZEN one, read after the pause landed,
        // not the moving one sampled before the send (cloud review r5: a slow
        // send could drift past the tolerance and leave the item paused).
        var recorded = source
        if case .paused(let now) = adapterGet() ?? .nothing, Self.matches(now, source) {
          paused = true
          recorded = now
        }
        guard paused else {
          // The adapter answered; the source may be a browser tab, so the
          // scripted route (and its consent prompts) is not a fallback here.
          return MediaPauseOutcome(.failed, route: .adapter, adapterFailure: "send")
        }
        let target = MediaRemoteAdapter.target(for: recorded)
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
    var needingConsent: [String] = []
    var consentDenied = false
    var failed = false
    for target in running {
      guard mayIssue(holdID: holdID, started: started) else { break }
      switch env.consent(target) {
      case .granted: break
      case .needed:
        consentNeeded = true
        needingConsent.append(target)
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
      // The TRACK, not just the player: a resume must not start a different
      // track the user paused mid-take (cloud review, PR #3000).
      guard mayIssue(holdID: holdID, started: started) else { break }
      let trackID = trackID(target)
      guard mayIssue(holdID: holdID, started: started) else { break }
      if env.run("tell application id \"\(target)\" to pause") != nil {
        paused.append(Self.scriptedTarget(bundleID: target, trackID: trackID))
        // Recorded per target, immediately: a later target's failure never
        // erases an earlier success, and a resume queued behind reads this.
        let recorded = paused
        state.withLock { $0.pausedByHold[holdID] = recorded }
      } else {
        failed = true
      }
    }
    if !needingConsent.isEmpty {
      // Raised for the NEXT take; this one is reported as consent needed.
      raiseConsentPrompts(needingConsent)
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
  /// call sites, one definition): same app AND the same item, where "item" is
  /// the title, or "untitled" for both. A recorded untitled item never matches
  /// a titled one (second pass: an untitled voice note must not resume a song
  /// the user paused in the same app), and a titled item never matches a read
  /// that lost its title. A miss can only leave something paused, never start it.
  private nonisolated static func matches(
    _ now: MediaRemoteAdapter.Source, _ recorded: MediaRemoteAdapter.Source
  ) -> Bool {
    now.bundleID == recorded.bundleID && now.identity == recorded.identity
  }

  private nonisolated func adapterResume(_ source: MediaRemoteAdapter.Source) -> MediaResumeOutcome {
    switch adapterGet() {
    case .paused(let now):
      guard Self.matches(now, source) else { return .sourceChanged }
      // Same item, but the user played and re-paused it (or a same-title tab
      // sits elsewhere in its timeline): the frozen position moved. Their
      // pause, not ours (cloud review, PR #3000). Unknown on either side skips
      // the check.
      if let then = source.elapsed, let now = now.elapsed,
        abs(now - then) > MediaRemoteAdapter.elapsedTolerance
      {
        return .sourceChanged
      }
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
      let (bundle, recordedTrack) = Self.scriptedParts(of: target)
      guard env.isRunning(bundle) else { continue }
      switch env.consent(bundle) {
      case .granted: break
      case .notRunning: continue
      case .needed, .denied:
        failed = true
        continue
      }
      switch playerState(bundle) {
      case .playing, .stopped:
        continue  // the user already resumed or stopped it
      case .unknown:
        failed = true
        continue
      case .paused:
        // Same track as the one we paused, or nothing is sent: the user paused
        // a different one themselves. Two unreadable ids compare equal (v1).
        guard trackID(bundle) == recordedTrack else {
          sourceChanged = true
          continue
        }
        guard env.isRunning(bundle) else { continue }
        if env.run("tell application id \"\(bundle)\" to play") == nil {
          failed = true
        }
      }
    }
    if failed { return .failed }
    return sourceChanged ? .sourceChanged : .resumed
  }

  /// A scripted target string: the bundle id, and when the pause could read it,
  /// the track id after `MediaRemoteAdapter.fieldSeparator` (never in an id).
  package nonisolated static func scriptedTarget(bundleID: String, trackID: String?) -> String {
    guard let trackID, !trackID.isEmpty else { return bundleID }
    return bundleID + MediaRemoteAdapter.fieldSeparator + trackID
  }

  package nonisolated static func scriptedParts(of target: String) -> (bundleID: String, trackID: String?) {
    let parts = target.components(separatedBy: MediaRemoteAdapter.fieldSeparator)
    guard parts.count >= 2, !parts[1].isEmpty else { return (parts[0], nil) }
    return (parts[0], parts[1])
  }

  /// Each player's stable track identity in its own dictionary: Spotify's `id`
  /// (`spotify:track:…`), Music's `persistent ID`. nil when there is no current
  /// track or the read fails.
  private nonisolated func trackID(_ bundleID: String) -> String? {
    let property = bundleID == "com.apple.Music" ? "persistent ID" : "id"
    let value = env.run("tell application id \"\(bundleID)\" to \(property) of current track")?
      .stringValue
    return (value?.isEmpty == false) ? value : nil
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

  /// A player that never answers would otherwise hold the main thread for
  /// AppleScript's default two minutes. Not measured against a hung player;
  /// the wrapper is AppleScript's own reply timeout.
  package nonisolated static let scriptTimeoutSeconds = 2

  /// Main thread only (`NSAppleScript`). Called from the serial queue, which
  /// nothing on the main actor ever waits on, so the synchronous hop cannot
  /// deadlock; a main-thread caller runs it in place.
  private nonisolated static func liveRun(_ source: String) -> NSAppleEventDescriptor? {
    let wrapped = "with timeout of \(scriptTimeoutSeconds) seconds\n\(source)\nend timeout"
    let body: () -> NSAppleEventDescriptor? = {
      var error: NSDictionary?
      let result = NSAppleScript(source: wrapped)?.executeAndReturnError(&error)
      return error == nil ? result : nil
    }
    return Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
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
