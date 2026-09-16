import AppKit
import EnviousWisprAppKit
import Foundation
import os

/// #1413 — the live Apple-events half of `Pause music`, behind
/// `MediaPlaybackControlling`. Music and Spotify only: the two scriptable players
/// whose playing state can be READ, so nothing is ever started by mistake (there
/// is no public "is media playing" API on macOS 15.4+, so a blind media-key
/// toggle was rejected in the plan).
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

    package init(
      isRunning: @escaping @Sendable (String) -> Bool,
      consent: @escaping @Sendable (String) -> ConsentState,
      raiseConsentPrompt: @escaping @Sendable (String) -> Void,
      run: @escaping @Sendable (String) -> NSAppleEventDescriptor?,
      now: @escaping @Sendable () -> Date = { Date() }
    ) {
      self.isRunning = isRunning
      self.consent = consent
      self.raiseConsentPrompt = raiseConsentPrompt
      self.run = run
      self.now = now
    }

    package static let live = Environment(
      isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
      consent: LiveMediaPlaybackEffects.liveConsent,
      raiseConsentPrompt: LiveMediaPlaybackEffects.liveRaiseConsentPrompt,
      run: LiveMediaPlaybackEffects.liveRun)
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
    guard !running.isEmpty else {
      completion(.nothingPlaying)
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
      Task { @MainActor in completion(outcome) }
    }
  }

  package func resumeOrphan(
    holdID: UUID, targets: [String],
    completion: @escaping @MainActor (MediaResumeOutcome) -> Void
  ) {
    queue.async { [self] in
      let outcome = resumeOnQueue(targets.filter { Self.targets.contains($0) })
      Task { @MainActor in completion(outcome) }
    }
  }

  package func preflightConsent() {
    let running = Self.targets.filter { env.isRunning($0) }
    guard !running.isEmpty else { return }
    queue.async { [env] in running.forEach(env.raiseConsentPrompt) }
  }

  // MARK: - Queue side (never on the main actor)

  private nonisolated func pauseOnQueue(holdID: UUID, running: [String]) -> MediaPauseOutcome {
    let started = env.now()
    var paused: [String] = []
    var consentNeeded = false
    var consentDenied = false
    var failed = false
    for target in running {
      if state.withLock({ $0.ended.contains(holdID) }) { break }
      if env.now().timeIntervalSince(started) > Self.issueBudget { break }
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
      guard playerState(target) == .playing else { continue }
      if env.run("tell application id \"\(target)\" to pause") != nil {
        paused.append(target)
      } else {
        failed = true
      }
    }
    if !paused.isEmpty {
      let recorded = paused
      state.withLock { $0.pausedByHold[holdID] = recorded }
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

  private nonisolated func resumeOnQueue(_ targets: [String]) -> MediaResumeOutcome {
    guard !targets.isEmpty else { return .nothingToResume }
    var resumed = false
    var failed = false
    for target in targets where env.isRunning(target) {
      guard env.consent(target) == .granted else { continue }
      guard playerState(target) == .paused else { continue }
      if env.run("tell application id \"\(target)\" to play") != nil {
        resumed = true
      } else {
        failed = true
      }
    }
    if resumed { return .resumed }
    return failed ? .failed : .nothingToResume
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
